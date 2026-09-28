#!/usr/bin/env python3
# Hardware bridge: follows what the app sets on com.raumfeld.hardwared and applies it to the Pi.
# Needed because hardwared runs virtualised (on a real device it drives the amplifier and the LED).
#   Volume / Mute  -> ALSA mixer of the chosen audio output
#   LedBrightness  -> the Pi's own LEDs (ACT/PWR): off when the LED is switched off in the app
#                     (VC_LEDS=0 leaves the Pi's LEDs alone)
#
#   vc-volume-bridge.py <card name> <mixer control>
#   e.g. vc-volume-bridge.py sndrpihifiberry Digital   |   Headphones PCM   |   vc4hdmi "VC Volume"
import os, re, signal, sys, time, subprocess, dbus, dbus.bus

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

class Leds:
    """The Pi's ACT/PWR LEDs; their original triggers are restored when switched on again or on exit."""
    def __init__(self):
        self.saved = {}
        if os.environ.get("VC_LEDS", "1") == "0":
            return
        for names in (("ACT", "led0"), ("PWR", "led1")):
            for n in names:
                p = "/sys/class/leds/" + n
                if os.path.isfile(p + "/trigger"):
                    m = re.search(r"\[([^\]]+)\]", open(p + "/trigger").read())
                    self.saved[p] = (m.group(1) if m else "none", open(p + "/brightness").read().strip())
                    break

    def set(self, on):
        for p, (trigger, brightness) in self.saved.items():
            try:
                with open(p + "/trigger", "w") as f:
                    f.write(trigger if on else "none")
                if not on or trigger == "none":
                    with open(p + "/brightness", "w") as f:
                        f.write(brightness if on else "0")
            except OSError:
                pass

def connect():
    bus = dbus.bus.BusConnection(SOCK)
    obj = bus.get_object(IFACE, "/com/raumfeld/hardwared")
    return dbus.Interface(obj, "org.freedesktop.DBus.Properties")

def main():
    leds = Leds()
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    props, last, last_led = None, None, None
    print("vc-volume-bridge: hardwared.Volume -> %s / %s, LED -> %s" %
          (CARD, CTL, ", ".join(os.path.basename(p) for p in leds.saved) or "-"), flush=True)
    try:
        while True:
            try:
                if props is None:
                    props = connect()
                p = props.GetAll(IFACE)
                vol, mute = int(p.get("Volume", 0)), int(p.get("Mute", 0))
                target = "mute" if (mute or vol <= 0) else max(1, min(100, vol))
                if target != last:
                    ok = set_mute() if target == "mute" else set_volume(target)
                    if ok:                              # otherwise retry next round
                        last = target                   # (softvol only exists once audio plays)
                led = int(p.get("LedBrightness", 100)) > 0
                if led != last_led:
                    leds.set(led)
                    last_led = led
            except dbus.exceptions.DBusException:
                props, last, last_led = None, None, None
                time.sleep(1)
            time.sleep(0.3)
    finally:
        leds.set(True)

if __name__ == "__main__":
    main()
