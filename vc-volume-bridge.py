#!/usr/bin/env python3
# Volume-brug: volgt com.raumfeld.hardwared 'Volume'/'Mute' (wat de app zet) en stelt de
# ALSA-mixer van de gekozen audio-uitgang bij. Nodig omdat de renderer het volume aan hardwared
# delegeert (op echte hardware = STA350), die wij virtueel draaien.
#
#   vc-volume-bridge.py <kaartnaam> <mixer-regelaar>
#   bv. vc-volume-bridge.py sndrpihifiberry Digital   |   Headphones PCM   |   vc4hdmi "VC Volume"
import os, sys, time, subprocess, dbus, dbus.bus

SOCK = os.environ.get("VC_SOCK", "unix:path=/opt/rfconnector/run/dbus/system_bus_socket")
CARD = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("VC_CARD", "0")
CTL  = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("VC_CTL", "Digital")
IFACE = "com.raumfeld.hardwared"
SPANDB = float(os.environ.get("VC_SPANDB", "50"))   # app 1..100 -> -SPANDB..0 dB (dB-lineair)

def amixer(*a):
    return subprocess.run(["amixer", "-c", CARD, "-q", "sset", CTL, *a],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def set_volume(vol):
    db = (vol / 100.0 - 1.0) * SPANDB                 # 100 -> 0 dB, 50 -> -25 dB, 1 -> ~-50 dB
    ok = amixer("--", "%.1fdB" % db) or amixer("%d%%" % vol)   # dB waar mogelijk, anders procent
    amixer("unmute")                                   # faalt stil bij regelaars zonder schakelaar
    return ok

def set_mute():
    ok = amixer("0%")
    amixer("mute")
    return ok

def connect():
    bus = dbus.bus.BusConnection(SOCK)
    obj = bus.get_object(IFACE, "/com/raumfeld/hardwared")
    return dbus.Interface(obj, "org.freedesktop.DBus.Properties")

def main():
    props, last = None, None
    print("vc-volume-bridge: hardwared.Volume -> %s / %s" % (CARD, CTL), flush=True)
    while True:
        try:
            if props is None:
                props = connect()
            vol = int(props.Get(IFACE, "Volume"))
            try:
                mute = int(props.Get(IFACE, "Mute"))
            except Exception:
                mute = 0
            target = "mute" if (mute or vol <= 0) else max(1, min(100, vol))
            if target != last:
                ok = set_mute() if target == "mute" else set_volume(target)
                if ok:                                  # anders volgende ronde opnieuw proberen
                    last = target                       # (softvol bestaat pas als er audio speelt)
        except Exception:
            props, last = None, None
            time.sleep(1)
        time.sleep(0.3)

if __name__ == "__main__":
    main()
