#!/usr/bin/env python3
# ConnMan D-Bus stub for the Virtual Raumfeld Connector.
# Provides net.connman on the chroot's system bus for master-process, backed by the Pi's real network
# (NetworkManager), so the Raumfeld app can set the device up like a real one:
#   - an ethernet service when a cable is plugged in, wifi services from a real scan
#   - Tethering on the wifi technology starts a real "Raumfeld Setup" access point (and stops it again,
#     restoring the previous wifi connection); a safety timeout ends it if the setup never completes
#   - Connect on a wifi service asks master-process' agent for the passphrase and connects with nmcli
# Ethernet is never touched; wifi is only touched during a setup started by the firmware.
#
# Runs on the host, pointed at the chroot's system bus (vc-up.sh does this):
#   sudo python3 connman-stub.py unix:path=/opt/rfconnector/run/dbus/system_bus_socket
#
# Requires: python3-dbus + python3-gi, NetworkManager (nmcli) for the wifi part.
import os, re, subprocess, sys, threading, time
import dbus, dbus.bus, dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

ROOT = os.environ.get("ROOT", "/opt/rfconnector")
ETH  = os.environ.get("VC_ETH", "eth0")
WLAN = os.environ.get("VC_WLAN", "wlan0")
AP_CON = "vc-setup-ap"
AP_ADDR = os.environ.get("VC_AP_ADDR", "192.168.0.1/24")          # as ConnMan's tethering would use
SETUP_TIMEOUT = int(os.environ.get("VC_SETUP_TIMEOUT", "900"))     # s of access point before giving up
TECH_ETH, TECH_WIFI = "/net/connman/technology/ethernet", "/net/connman/technology/wifi"

def log(*a): print("connman-stub:", *a, flush=True)

def sh(*cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except Exception as e:
        return 1, str(e)

def has_nm(): return sh("nmcli", "-v", timeout=5)[0] == 0

def read(path, default=""):
    try: return open(path).read().strip()
    except OSError: return default

def mac(iface): return read("/sys/class/net/%s/address" % iface, "02:00:00:00:00:01")

def ipv4(iface):
    _, out = sh("ip", "-4", "-o", "addr", "show", iface, timeout=5)
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/(\d+)", out)
    if not m: return None
    bits = int(m.group(2)); mask = (0xffffffff << (32 - bits)) & 0xffffffff
    _, rt = sh("ip", "-4", "route", "show", "default", "dev", iface, timeout=5)
    g = re.search(r"via (\d+\.\d+\.\d+\.\d+)", rt)
    return {"Address": m.group(1), "Netmask": ".".join(str(mask >> s & 255) for s in (24, 16, 8, 0)),
            "Gateway": g.group(1) if g else ""}

def nameservers():
    ns = re.findall(r"^nameserver\s+(\S+)", read("/etc/resolv.conf"), re.M)
    return ns or ["8.8.8.8"]

def ssid_hex(ssid): return ssid.encode().hex()

# ---------------- network model (only touched from the GLib main thread) ----------------
class Net:
    def __init__(self):
        self.scan = []            # [{ssid, strength, security}] from the last scan
        self.tethering = False    # what the firmware asked for
        self.ap_up = False        # whether our access point is really up
        self.prev_wifi = None     # NetworkManager connection active on wlan0 before the AP
        self.failed = {}          # service path -> error after a failed connect
        self.setup_seen = False   # a setup started (first scan): report the real networks from now on

    def eth_present(self):
        return os.path.isdir("/sys/class/net/" + ETH) and read("/sys/class/net/%s/carrier" % ETH) == "1"

    def wifi_present(self): return os.path.isdir("/sys/class/net/" + WLAN)

    def legacy_wired(self):
        """Without a cable the Pi's own connection is reported as a wired service, except during a setup.
        The virtualised master-process never reads its stored target network (target-network.json): on
        start-up it only restores a wired connection ('using actual wired network'); a WiFi service would
        be disconnected as 'not the target'. During a setup the real WiFi networks are reported instead,
        so the app can offer them."""
        return not self.eth_present() and not self.setup_seen

    def current_ssid(self):
        if self.ap_up or not self.wifi_present() or not has_nm() or self.legacy_wired(): return None
        _, out = sh("nmcli", "-t", "-f", "GENERAL.STATE,GENERAL.CONNECTION", "device", "show", WLAN, timeout=5)
        if "(connected)" not in out: return None
        _, s = sh("iw", "dev", WLAN, "link", timeout=5)
        m = re.search(r"SSID: (.*)", s)
        return m.group(1).strip() if m else None

    def eth_path(self): return "/net/connman/service/ethernet_%s_cable" % mac(ETH).replace(":", "")

    def wifi_path(self, ssid, sec):
        return "/net/connman/service/wifi_%s_%s_managed_%s" % (mac(WLAN).replace(":", ""), ssid_hex(ssid), sec)

    def services(self):
        """[(path, props)] like ConnMan: connected first, ethernet before wifi."""
        out = []
        if self.eth_present():
            ip = ipv4(ETH)
            out.append((self.eth_path(), self.props("ethernet", "Wired", ETH, ip, "online" if ip else "ready")))
        cur = self.current_ssid()
        seen = set()
        nets = sorted(self.scan, key=lambda n: -n["strength"])
        if cur and not any(n["ssid"] == cur for n in nets):
            _, s = sh("iw", "dev", WLAN, "link", timeout=5)
            b = re.search(r"Connected to ([0-9a-f:]{17})", s); fr = re.search(r"freq: (\d+)", s)
            nets.insert(0, {"ssid": cur, "bssid": b.group(1) if b else mac(WLAN), "strength": 70,
                            "freq": int(fr.group(1)) if fr else 2412, "security": "psk"})
        for n in nets:
            if n["ssid"] in seen: continue
            seen.add(n["ssid"])
            path = self.wifi_path(n["ssid"], n["security"])
            if n["ssid"] == cur:
                ip = ipv4(WLAN)
                state = "online" if ip else "ready"
            else:
                ip, state = None, ("failure" if path in self.failed else "idle")
            p = self.props("wifi", n["ssid"], WLAN, ip, state)
            p["Security"] = dbus.Array([n["security"]], signature="s")
            p["Strength"] = dbus.Byte(max(1, min(100, n["strength"])))
            p["BSSID"] = dbus.String(n["bssid"])                      # required by Raumfeld's ConnMan client
            p["Frequency"] = dbus.UInt16(n["freq"])
            if path in self.failed: p["Error"] = dbus.String(self.failed[path])
            out.append((path, p))
        out.sort(key=lambda s: 0 if str(s[1]["State"]) in ("online", "ready") else 1)
        if not any(str(p["State"]) == "online" for _, p in out):
            # fallback (no NetworkManager, or detection failed): report the interface with the default
            # route as an online wired service, as the stub always did — master-process needs one
            _, rt = sh("ip", "-4", "route", "show", "default", timeout=5)
            m = re.search(r"dev (\S+)", rt)
            if m and ipv4(m.group(1)):
                dev = m.group(1)
                out.insert(0, ("/net/connman/service/ethernet_%s_cable" % mac(dev).replace(":", ""),
                               self.props("ethernet", "Wired", dev, ipv4(dev), "online")))
        return out

    def props(self, typ, name, iface, ip, state):
        p = {"State": dbus.String(state), "Type": dbus.String(typ), "Name": dbus.String(name),
             "AutoConnect": dbus.Boolean(True), "Favorite": dbus.Boolean(state in ("online", "ready")),
             "Immutable": dbus.Boolean(False),
             "Ethernet": dbus.Dictionary({"Method": dbus.String("auto"), "Interface": dbus.String(iface),
                                          "Address": dbus.String(mac(iface)), "MTU": dbus.UInt16(1500)},
                                         signature="sv"),
             "Nameservers": dbus.Array([dbus.String(n) for n in (nameservers() if ip else [])], signature="s")}
        p["IPv4"] = dbus.Dictionary({"Method": dbus.String("dhcp"), **{k: dbus.String(v) for k, v in ip.items()}}
                                    if ip else {}, signature="sv")
        return dbus.Dictionary(p, signature="sv")

    def find(self, path):
        for p, props in self.services():
            if p == path: return props
        return None

    def online(self): return any(str(p["State"]) == "online" for _, p in self.services())

NET = Net()

# ---------------- slow actions, run in a thread; results go back via GLib.idle_add ----------------
def in_thread(fn, done):
    def run():
        try: res = fn()
        except Exception as e: res = e
        GLib.idle_add(lambda: (done(res), False)[1])
    threading.Thread(target=run, daemon=True).start()

def do_scan():
    if not NET.wifi_present() or not has_nm() or NET.ap_up: return None
    rc, out = sh("nmcli", "-t", "-e", "yes", "-f", "SSID,BSSID,FREQ,SIGNAL,SECURITY", "device", "wifi", "list",
                 "ifname", WLAN, "--rescan", "yes", timeout=40)
    if rc != 0: return None
    nets = []
    for line in out.splitlines():
        f = [x.replace("\\:", ":").replace("\\\\", "\\") for x in re.split(r"(?<!\\):", line)]
        if len(f) < 5 or not f[0]: continue                           # hidden networks are skipped
        sec = f[4].upper()
        security = "none" if not sec or sec == "--" else ("ieee8021x" if "802.1X" in sec else "psk")
        freq = re.match(r"\d+", f[2])
        nets.append({"ssid": f[0], "bssid": f[1].lower(), "freq": int(freq.group(0)) if freq else 2412,
                     "strength": int(f[3] or 0), "security": security})
    return nets

def ap_start(ssid, passphrase, freq):
    if not NET.wifi_present() or not has_nm(): return "no wifi / NetworkManager"
    _, out = sh("nmcli", "-t", "-f", "GENERAL.CONNECTION", "device", "show", WLAN, timeout=5)
    prev = out.split(":", 1)[1].strip() if ":" in out else ""
    NET.prev_wifi = prev if prev and prev != AP_CON else NET.prev_wifi
    ch = {2412: 1, 2417: 2, 2422: 3, 2427: 4, 2432: 5, 2437: 6, 2442: 7, 2447: 8, 2452: 9, 2457: 10,
          2462: 11}.get(int(freq or 2412), 1)
    sh("nmcli", "con", "delete", AP_CON, timeout=15)
    cmd = ["nmcli", "con", "add", "type", "wifi", "ifname", WLAN, "con-name", AP_CON, "autoconnect", "no",
           "ssid", ssid, "802-11-wireless.mode", "ap", "802-11-wireless.band", "bg",
           "802-11-wireless.channel", str(ch), "ipv4.method", "shared", "ipv4.addresses", AP_ADDR,
           "ipv6.method", "disabled"]
    if passphrase: cmd += ["wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", passphrase]
    rc, out = sh(*cmd, timeout=20)
    if rc != 0: return "add failed: " + out.strip()
    rc, out = sh("nmcli", "--wait", "30", "con", "up", AP_CON, timeout=40)
    return None if rc == 0 else "up failed: " + out.strip()

def ap_stop():
    sh("nmcli", "con", "down", AP_CON, timeout=20)
    sh("nmcli", "con", "delete", AP_CON, timeout=15)
    if NET.prev_wifi:
        sh("nmcli", "--wait", "30", "con", "up", NET.prev_wifi, timeout=40)   # else NM autoconnects
    return None

def wifi_connect(ssid, passphrase):
    cmd = ["nmcli", "--wait", "45", "device", "wifi", "connect", ssid, "ifname", WLAN]
    if passphrase: cmd += ["password", passphrase]
    rc, out = sh(*cmd, timeout=60)
    if rc != 0: return "invalid-key" if re.search(r"secret|password|key", out, re.I) else "connect-failed"
    for _ in range(20):                                               # wait for DHCP
        if ipv4(WLAN): return None
        time.sleep(1)
    return "dhcp-failed"

# ---------------- D-Bus objects ----------------
class Manager(dbus.service.Object):
    def __init__(self, bus):
        dbus.service.Object.__init__(self, bus, "/"); self.bus = bus; self.agent = None
    @dbus.service.method("net.connman.Manager", out_signature="a{sv}")
    def GetProperties(self):
        return dbus.Dictionary({"State": dbus.String("online" if NET.online() else "idle"),
                                "OfflineMode": dbus.Boolean(False), "SessionMode": dbus.Boolean(False)},
                               signature="sv")
    @dbus.service.method("net.connman.Manager", out_signature="a(oa{sv})")
    def GetServices(self):
        return dbus.Array([(dbus.ObjectPath(p), props) for p, props in self.sync_services()], signature="(oa{sv})")
    @dbus.service.method("net.connman.Manager", out_signature="a(oa{sv})")
    def GetTechnologies(self):
        # the wired technology only with a cable plugged in: as soon as it exists the firmware restores a
        # wired connection, even when its target network is WiFi (and then switches the WiFi off)
        techs = [TECH_ETH] if NET.eth_present() or NET.legacy_wired() else []
        return dbus.Array([(dbus.ObjectPath(p), TECHS[p].props()) for p in techs + [TECH_WIFI]],
                          signature="(oa{sv})")
    @dbus.service.method("net.connman.Manager", in_signature="sv")
    def SetProperty(self, name, value): pass
    @dbus.service.method("net.connman.Manager", in_signature="o", sender_keyword="sender")
    def RegisterAgent(self, path, sender=None):
        self.agent = (sender, str(path)); log("agent registered", self.agent)
    @dbus.service.method("net.connman.Manager", in_signature="o")
    def UnregisterAgent(self, path): self.agent = None
    @dbus.service.method("net.connman.Manager", in_signature="oss")
    def RegisterCounter(self, path, a, b): pass
    @dbus.service.signal("net.connman.Manager", signature="sv")
    def PropertyChanged(self, name, value): pass
    @dbus.service.signal("net.connman.Manager", signature="a(oa{sv})ao")
    def ServicesChanged(self, changed, removed): pass

    def sync_services(self):
        """Current services; makes sure every one has a D-Bus object."""
        svcs = NET.services()
        for path, _ in svcs:
            if path not in SERVICES: SERVICES[path] = Service(self.bus, path)
        return svcs

    def announce(self):
        svcs = self.sync_services()
        paths = {p for p, _ in svcs}
        removed = [p for p in list(SERVICES) if p not in paths]
        for p in removed:
            SERVICES.pop(p).remove_from_connection()
        self.ServicesChanged(dbus.Array([(dbus.ObjectPath(p), props) for p, props in svcs], signature="(oa{sv})"),
                             dbus.Array([dbus.ObjectPath(p) for p in removed], signature="o"))
        self.PropertyChanged("State", dbus.String("online" if NET.online() else "idle"))

class Service(dbus.service.Object):
    def __init__(self, bus, path):
        dbus.service.Object.__init__(self, bus, path); self.path = path
    @dbus.service.method("net.connman.Service", out_signature="a{sv}")
    def GetProperties(self):
        return NET.find(self.path) or dbus.Dictionary({"State": dbus.String("idle")}, signature="sv")
    @dbus.service.method("net.connman.Service", in_signature="", async_callbacks=("ok", "err"))
    def Connect(self, ok, err):
        props = NET.find(self.path)
        if props is None:
            return err(dbus.DBusException("service gone", name="net.connman.Error.NotFound"))
        if str(props["State"]) in ("online", "ready"):
            return err(dbus.DBusException("already connected", name="net.connman.Error.AlreadyConnected"))
        if str(props["Type"]) != "wifi":
            return ok()
        ssid, secure = str(props["Name"]), list(props.get("Security", ["none"]))[0] != "none"
        log("connect requested:", ssid)
        self.set_state("association")

        def go(passphrase):
            def done(res):
                if res:                                              # error string
                    NET.failed[self.path] = res; log("connect to %s failed: %s" % (ssid, res))
                    self.set_state("failure")
                    err(dbus.DBusException(res, name="net.connman.Error.Failed"))
                else:
                    NET.failed.pop(self.path, None); log("connected to", ssid)
                    ok()
                MGR.announce()
            in_thread(lambda: wifi_connect(ssid, passphrase), done)

        if not secure: return go(None)
        if not MGR.agent:
            return err(dbus.DBusException("no agent", name="net.connman.Error.Failed"))
        sender, apath = MGR.agent
        fields = dbus.Dictionary({"Passphrase": dbus.Dictionary({"Type": dbus.String("psk"),
                                  "Requirement": dbus.String("mandatory")}, signature="sv")}, signature="sv")
        agent = dbus.Interface(BUS.get_object(sender, apath), "net.connman.Agent")
        agent.RequestInput(dbus.ObjectPath(self.path), fields, timeout=120,
                           reply_handler=lambda ans: go(str(ans.get("Passphrase", ""))),
                           error_handler=lambda e: (self.set_state("failure"), err(e)))
    @dbus.service.method("net.connman.Service", in_signature="")
    def Disconnect(self): pass                        # we never drop the Pi's network on request
    @dbus.service.method("net.connman.Service", in_signature="")
    def Remove(self): NET.failed.pop(self.path, None)
    @dbus.service.method("net.connman.Service", in_signature="sv")
    def SetProperty(self, name, value): pass
    @dbus.service.method("net.connman.Service", in_signature="s")
    def ClearProperty(self, name): pass
    @dbus.service.signal("net.connman.Service", signature="sv")
    def PropertyChanged(self, name, value): pass
    def set_state(self, state): self.PropertyChanged("State", dbus.String(state))

class Technology(dbus.service.Object):
    def __init__(self, bus, path, typ, name, extra):
        dbus.service.Object.__init__(self, bus, path); self.typ = typ; self.state = dict(extra, Name=name, Type=typ)
    def props(self):
        p = dict(self.state)
        if self.typ == "ethernet": p["Connected"] = NET.eth_present()
        else: p["Connected"] = bool(p.get("Tethering")) or NET.current_ssid() is not None
        out = {}
        for k, v in p.items():
            out[k] = dbus.Boolean(v) if isinstance(v, bool) else (dbus.UInt32(v) if isinstance(v, int) else dbus.String(str(v)))
        return dbus.Dictionary(out, signature="sv")
    @dbus.service.method("net.connman.Technology", out_signature="a{sv}")
    def GetProperties(self): return self.props()
    @dbus.service.method("net.connman.Technology", in_signature="sv", async_callbacks=("ok", "err"))
    def SetProperty(self, name, value, ok, err):
        n = str(name)
        v = bool(value) if isinstance(value, dbus.Boolean) else (int(value) if isinstance(value, (dbus.UInt32, dbus.Int32)) else str(value))
        self.state[n] = v
        if self.typ == "wifi" and n == "Tethering":
            return self.tether(bool(v), ok)
        self.PropertyChanged(n, self.props()[n]); ok()
    @dbus.service.method("net.connman.Technology", in_signature="", async_callbacks=("ok", "err"))
    def Scan(self, ok, err):
        if self.typ != "wifi": return ok()
        if not NET.setup_seen:                     # the firmware only scans during a setup
            NET.setup_seen = True; log("setup started: reporting the real networks")
        def done(nets):
            if isinstance(nets, list): NET.scan = nets; log("scan: %d networks" % len(nets))
            MGR.announce(); ok()
        in_thread(do_scan, done)
    @dbus.service.signal("net.connman.Technology", signature="sv")
    def PropertyChanged(self, name, value): pass

    def tether(self, on, ok):
        NET.tethering = on
        if on: NET.setup_seen = True
        def report(res):
            if isinstance(res, str): log("access point:", res)
            p = self.props()
            self.PropertyChanged("Tethering", p["Tethering"]); self.PropertyChanged("Connected", p["Connected"])
            MGR.announce(); ok()
        if on:
            ssid = str(self.state.get("TetheringIdentifier", "Raumfeld Setup"))
            pw = str(self.state.get("TetheringPassphrase", ""))
            def start():
                e = ap_start(ssid, pw, self.state.get("TetheringFrequency", 2412))
                if not e: NET.ap_up = True; log("access point '%s' up" % ssid)
                return e
            in_thread(start, report)
            GLib.timeout_add_seconds(SETUP_TIMEOUT, self.timeout)
        else:
            def stop():
                if NET.ap_up: ap_stop(); log("access point down, wifi restored")
                NET.ap_up = False
            in_thread(stop, report)
    def timeout(self):
        if NET.ap_up and NET.tethering:
            # setup not finished: give the Pi its network back (the firmware keeps believing the AP is up)
            log("setup not completed within %d s - access point off" % SETUP_TIMEOUT)
            def stop(): ap_stop(); NET.ap_up = False
            in_thread(stop, lambda r: MGR.announce())
        return False

if __name__ == "__main__":
    DBusGMainLoop(set_as_default=True)
    addr = sys.argv[1] if len(sys.argv) > 1 else None
    BUS = dbus.bus.BusConnection(addr) if addr else dbus.SystemBus()
    # KEEP the references — otherwise dbus-python garbage-collects the name/objects right away.
    NAME = dbus.service.BusName("net.connman", BUS, do_not_queue=True)
    SERVICES = {}
    TECHS = {TECH_ETH: Technology(BUS, TECH_ETH, "ethernet", "Wired", {"Powered": True}),
             TECH_WIFI: Technology(BUS, TECH_WIFI, "wifi", "WiFi",
                                   {"Powered": True, "Tethering": False, "TetheringIdentifier": "Raumfeld Setup"})}
    MGR = Manager(BUS)
    if has_nm() and sh("nmcli", "-t", "-f", "NAME", "con", "show", timeout=10)[1].splitlines().count(AP_CON):
        sh("nmcli", "con", "delete", AP_CON, timeout=20)    # left over from an interrupted setup
        log("removed a leftover setup access point")
    MGR.sync_services()
    def watch():                                     # cable/wifi changes -> tell the firmware
        sig = [(p, str(props["State"])) for p, props in NET.services()]
        if sig != getattr(watch, "last", None):
            if hasattr(watch, "last"): MGR.announce()
            watch.last = sig
        return True
    GLib.timeout_add_seconds(5, watch)
    log("net.connman registered on %s (ethernet: %s, wifi: %s)" % (addr or "system-bus",
        "yes" if NET.eth_present() else "no", WLAN if NET.wifi_present() and has_nm() else "no"))
    GLib.MainLoop().run()
