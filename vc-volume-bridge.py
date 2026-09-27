#!/usr/bin/env python3
# Volume bridge: follows com.raumfeld.hardwared 'Volume'/'Mute' (what the app sets) and adjusts the
# ALSA mixer of the chosen audio output. Needed because the renderer delegates the volume to hardwared
# (on real hardware = the STA350 amplifier), which we run virtualised.
#
#   vc-volume-bridge.py <card name> <mixer control>
#   e.g. vc-volume-bridge.py sndrpihifiberry Digital   |   Headphones PCM   |   vc4hdmi "VC Volume"
import os, sys, time, subprocess, dbus, dbus.bus

SOCK = os.environ.get("VC_SOCK", "unix:path=/opt/rfconnector/run/dbus/system_bus_socket")
CARD = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("VC_CARD", "0")
CTL  = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("VC_CTL", "Digital")
IFACE = "com.raumfeld.hardwared"
SPANDB = float(os.environ.get("VC_SPANDB", "50"))   # app 1..100 -> -SPANDB..0 dB (linear in dB)

def amixer(*a):
    return subprocess.run(["amixer", "-c", CARD, "-q", "sset", CTL, *a],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def set_volume(vol):
    db = (vol / 100.0 - 1.0) * SPANDB                 # 100 -> 0 dB, 50 -> -25 dB, 1 -> ~-50 dB
    ok = amixer("--", "%.1fdB" % db) or amixer("%d%%" % vol)   # dB where possible, otherwise percent
    amixer("unmute")                                   # silently fails on controls without a switch
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
                if ok:                                  # otherwise retry next round
                    last = target                       # (softvol only exists once audio plays)
        except Exception:
            props, last = None, None
            time.sleep(1)
        time.sleep(0.3)

if __name__ == "__main__":
    main()
