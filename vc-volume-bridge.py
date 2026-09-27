#!/usr/bin/env python3
# Volume-brug: volgt com.raumfeld.hardwared 'Volume'/'Mute' (wat de app zet) en stelt
# de HiFiBerry ALSA-mixer ('Digital', card 1) bij. Nodig omdat de renderer het volume aan
# hardwared delegeert (op echte hardware = STA350), die wij virtueel draaien.
#
#   sudo python3 vc-volume-bridge.py            # draait als achtergrond-loop
import os, sys, time, subprocess, dbus, dbus.bus

# Kaart + mixer-control via argv/env, zodat dit op elke Pi/DAC werkt.
#   vc-volume-bridge.py [card] [control]
SOCK = os.environ.get("VC_SOCK", "unix:path=/opt/rfconnector/run/dbus/system_bus_socket")
CARD = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("VC_CARD", "1")
CTL  = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("VC_CTL", "Digital")
IFACE = "com.raumfeld.hardwared"

RAWMAX = int(os.environ.get("VC_RAWMAX", "207"))   # PCM512x 'Digital' max (0 dB)
SPANDB = int(os.environ.get("VC_SPANDB", "50"))     # app 0-100 -> -SPANDB..0 dB (dB-lineair = 0.5 dB/stap)

def amixer(*a):
    subprocess.run(["amixer", "-c", CARD, "-q", *a], check=False)

def vol_to_raw(vol):
    # vol 100 -> RAWMAX (0 dB); vol 1 -> RAWMAX - SPANDB*2 (-SPANDB dB). Bruikbare curve i.p.v.
    # lineair over de volle -103 dB..0 dB (waar 50% al -52 dB is).
    floor = RAWMAX - SPANDB * 2
    raw = floor + round((RAWMAX - floor) * vol / 100.0)
    return max(0, min(RAWMAX, int(raw)))

def connect():
    bus = dbus.bus.BusConnection(SOCK)
    obj = bus.get_object(IFACE, "/com/raumfeld/hardwared")
    return dbus.Interface(obj, "org.freedesktop.DBus.Properties")

def main():
    props, last = None, None
    print("vc-volume-bridge: hardwared.Volume -> HiFiBerry Digital", flush=True)
    while True:
        try:
            if props is None:
                props = connect()
            vol = int(props.Get(IFACE, "Volume"))
            try:
                mute = int(props.Get(IFACE, "Mute"))
            except Exception:
                mute = 0
            if mute or vol <= 0:
                key = "mute"
                if key != last:
                    amixer("set", CTL, "mute")
                    last = key
            else:
                raw = vol_to_raw(max(0, min(100, vol)))
                if raw != last:
                    amixer("set", CTL, str(raw), "unmute")
                    last = raw
        except Exception:
            props, last = None, None
            time.sleep(1)
        time.sleep(0.3)

if __name__ == "__main__":
    main()
