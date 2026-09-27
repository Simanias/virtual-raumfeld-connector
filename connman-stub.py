#!/usr/bin/env python3
# Minimale ConnMan dbus-stub voor de virtuele Raumfeld Connector.
# Levert net.connman op de system-bus zodat master-process' ConnmanManager tevreden is
# ("online" ethernet-service), ZONDER de echte netwerk-interface aan te raken.
#
# Draai op de host, gericht op de chroot-system-bus:
#   sudo DBUS_SYSTEM_BUS_ADDRESS=unix:path=/opt/rfconnector/run/dbus/system_bus_socket \
#        python3 connman-stub.py
#
# Vereist: python3-dbus + python3-gi  (sudo apt install -y python3-dbus python3-gi)
import os, sys, dbus, dbus.bus, dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

# Echte netwerkgegevens van de Pi (via env te overschrijven). De stub MOET een MAC opgeven,
# anders negeert master-process de service ("doesn't have a MAC-address - ignoring").
IFACE   = os.environ.get("VC_IFACE",   "wlan0")
IPADDR  = os.environ.get("VC_IP",      "192.168.1.218")
NETMASK = os.environ.get("VC_NETMASK", "255.255.255.0")
GATEWAY = os.environ.get("VC_GW",      "192.168.1.1")
MAC     = os.environ.get("VC_MAC",     "b8:27:eb:02:8f:ac")

_macflat = MAC.replace(":", "").lower()
SVC  = "/net/connman/service/ethernet_%s_cable" % _macflat
TECH = "/net/connman/technology/ethernet"
TECH_WIFI = "/net/connman/technology/wifi"

def props_manager():
    return dbus.Dictionary({
        "State":       dbus.String("online"),
        "OfflineMode": dbus.Boolean(False),
        "SessionMode": dbus.Boolean(False),
    }, signature="sv")

def props_service():
    return dbus.Dictionary({
        "State":       dbus.String("online"),
        "Type":        dbus.String("ethernet"),
        "Name":        dbus.String("Wired"),
        "AutoConnect": dbus.Boolean(True),
        "Favorite":    dbus.Boolean(True),
        "Immutable":   dbus.Boolean(False),
        "IPv4": dbus.Dictionary({
            "Method":  dbus.String("dhcp"),
            "Address": dbus.String(IPADDR),
            "Netmask": dbus.String(NETMASK),
            "Gateway": dbus.String(GATEWAY),
        }, signature="sv"),
        "Ethernet": dbus.Dictionary({
            "Method":    dbus.String("auto"),
            "Interface": dbus.String(IFACE),
            "Address":   dbus.String(MAC),
            "MTU":       dbus.UInt16(1500),
        }, signature="sv"),
        "Nameservers": dbus.Array([dbus.String(GATEWAY)], signature="s"),
    }, signature="sv")

def props_tech():
    return dbus.Dictionary({
        "Type":      dbus.String("ethernet"),
        "Name":      dbus.String("Wired"),
        "Powered":   dbus.Boolean(True),
        "Connected": dbus.Boolean(True),
    }, signature="sv")

# Stateful wifi-technology: master-process zet tijdens setup Tethering/Powered en
# WACHT tot de technology die staat terugmeldt ("correct power state"). We slaan
# SetProperty op en geven 't terug, zodat de nep-AP "up" komt.
_wifi = {"Type": "wifi", "Name": "WiFi", "Powered": True, "Connected": False,
         "Tethering": False, "TetheringIdentifier": "Raumfeld Setup"}

def _to_variant(v):
    if isinstance(v, bool):  return dbus.Boolean(v)
    if isinstance(v, int):   return dbus.UInt32(v)
    return dbus.String(str(v))

def props_tech_wifi():
    return dbus.Dictionary({k: _to_variant(v) for k, v in _wifi.items()}, signature="sv")

class Manager(dbus.service.Object):
    def __init__(self, bus): dbus.service.Object.__init__(self, bus, "/")
    @dbus.service.method("net.connman.Manager", out_signature="a{sv}")
    def GetProperties(self): return props_manager()
    @dbus.service.method("net.connman.Manager", out_signature="a(oa{sv})")
    def GetServices(self):  return dbus.Array([(dbus.ObjectPath(SVC), props_service())], signature="(oa{sv})")
    @dbus.service.method("net.connman.Manager", out_signature="a(oa{sv})")
    def GetTechnologies(self): return dbus.Array([
        (dbus.ObjectPath(TECH), props_tech()),
        (dbus.ObjectPath(TECH_WIFI), props_tech_wifi()),
    ], signature="(oa{sv})")
    @dbus.service.method("net.connman.Manager", in_signature="sv")
    def SetProperty(self, name, value): pass
    @dbus.service.method("net.connman.Manager", in_signature="o")
    def RegisterAgent(self, path): pass
    @dbus.service.method("net.connman.Manager", in_signature="o")
    def UnregisterAgent(self, path): pass
    @dbus.service.method("net.connman.Manager", in_signature="oss")
    def RegisterCounter(self, path, a, b): pass
    @dbus.service.signal("net.connman.Manager", signature="sv")
    def PropertyChanged(self, name, value): pass
    @dbus.service.signal("net.connman.Manager", signature="a(oa{sv})ao")
    def ServicesChanged(self, changed, removed): pass

class Service(dbus.service.Object):
    def __init__(self, bus): dbus.service.Object.__init__(self, bus, SVC)
    @dbus.service.method("net.connman.Service", out_signature="a{sv}")
    def GetProperties(self): return props_service()
    @dbus.service.method("net.connman.Service", in_signature="")
    def Connect(self): pass
    @dbus.service.method("net.connman.Service", in_signature="")
    def Disconnect(self): pass
    @dbus.service.method("net.connman.Service", in_signature="")
    def Remove(self): pass                       # 'vergeten' -> no-op (ethernet blijft)
    @dbus.service.method("net.connman.Service", in_signature="sv")
    def SetProperty(self, name, value): pass
    @dbus.service.method("net.connman.Service", in_signature="s")
    def ClearProperty(self, name): pass
    @dbus.service.signal("net.connman.Service", signature="sv")
    def PropertyChanged(self, name, value): pass

class Technology(dbus.service.Object):
    def __init__(self, bus): dbus.service.Object.__init__(self, bus, TECH)
    @dbus.service.method("net.connman.Technology", out_signature="a{sv}")
    def GetProperties(self): return props_tech()
    @dbus.service.method("net.connman.Technology", in_signature="sv")
    def SetProperty(self, name, value): pass
    @dbus.service.signal("net.connman.Technology", signature="sv")
    def PropertyChanged(self, name, value): pass

class TechnologyWifi(dbus.service.Object):
    def __init__(self, bus): dbus.service.Object.__init__(self, bus, TECH_WIFI)
    @dbus.service.method("net.connman.Technology", out_signature="a{sv}")
    def GetProperties(self): return props_tech_wifi()
    @dbus.service.method("net.connman.Technology", in_signature="sv")
    def SetProperty(self, name, value):
        n = str(name)
        v = bool(value) if isinstance(value, dbus.Boolean) else (str(value) if isinstance(value, dbus.String) else value)
        _wifi[n] = v
        if n == "Tethering":                 # AP aan -> ook 'verbonden' melden
            _wifi["Connected"] = bool(v)
        self.PropertyChanged(n, _to_variant(_wifi[n]))
        if n == "Tethering":
            self.PropertyChanged("Connected", _to_variant(_wifi["Connected"]))
    @dbus.service.method("net.connman.Technology", in_signature="")
    def Scan(self): pass                               # geen echte scan
    @dbus.service.signal("net.connman.Technology", signature="sv")
    def PropertyChanged(self, name, value): pass

if __name__ == "__main__":
    DBusGMainLoop(set_as_default=True)
    # Expliciet adres als argv[1] (bijv. unix:path=/opt/rfconnector/run/dbus/system_bus_socket),
    # anders de standaard system-bus. BusConnection doet zelf de Hello-handshake.
    addr = sys.argv[1] if len(sys.argv) > 1 else None
    bus = dbus.bus.BusConnection(addr) if addr else dbus.SystemBus()
    # Referenties VASTHOUDEN — anders GC't dbus-python de naam/objecten meteen weg.
    name = dbus.service.BusName("net.connman", bus, do_not_queue=True)
    mgr, svc, tech, techw = Manager(bus), Service(bus), Technology(bus), TechnologyWifi(bus)
    print("connman-stub: net.connman geregistreerd op %s (online ethernet)" % (addr or "system-bus"), flush=True)
    GLib.MainLoop().run()
