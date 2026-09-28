# Virtual Raumfeld Connector

Run the Raumfeld **Connector** firmware (userspace) in a chroot on a Raspberry Pi, so the Pi — with
its **own DAC** — shows up as a full Raumfeld renderer/room in the Raumfeld app and compatible with Raumfeld multiroom.

## Install (Raspberry Pi OS 32-bit Lite)
```bash
wget -qO- https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main/install.sh | sudo bash
```
The installer asks only two things:
- **audio output** — an external/USB DAC, the onboard 3.5 mm jack, HDMI, or enable a DAC HAT overlay
  (then it reboots once and continues by itself). With a DAC the onboard jack is switched off; set
  `VC_KEEP_ONBOARD=1` to keep it. The choice is stored by card *name*, so it survives card renumbering.
- **room name** (default `Virtual Connector`) — renameable later in the app.

Before anything is changed, the installer looks for your **Raumfeld host** on the network (SSDP) and shows
it, e.g. `Raumfeld host found: Raumfeld Soundbar (192.168.1.41)`. If none is found it asks for the host's
IP address to diagnose the problem: a host that is reachable but not discoverable means broadcast/multicast
is blocked between the Pi and your Raumfeld devices (different subnet/VLAN, guest WiFi / client isolation,
IGMP snooping or "multicast enhancement" on the router/access point). Raumfeld itself only finds the host
via broadcast/multicast, so that has to be fixed — entering an IP cannot replace it. Press Enter to install
without registering and register later with `vc-setup.sh` (see below).

It then registers the Pi as a room in the Raumfeld system on your network. **No system-id is needed**:
the Pi adopts the system-id from your Raumfeld host automatically during registration. After that
everything runs and **starts automatically on reboot**.

In the app the device shows up with model **Virtual Connector**; its player follows the standard Raumfeld
naming, `Connector <room name>` (like `Speaker Bar` or `Connector Kitchen`).

Headless/non-interactive: `VC_CARD=<card name>` or `VC_OVERLAY=<overlay>`, `VC_ROOM="<name>"`,
`VC_HOST=<ip>|none` (only used when auto-discovery fails; `VC_DEBUG=1` for a trace).

## Firmware & copyright
This repo contains **only our own tooling** — no Teufel firmware. On install, the Connector firmware is
fetched **directly from Teufel's official update server** (`updates.raumfeld.com`, hardware id 9) and
the rootfs is extracted locally. We don't redistribute protected firmware; every user obtains it themselves.

## How it works
- Universal AM33xx rootfs (armhf) in a chroot at `/opt/rfconnector`.
- `hardwared`/`master-process` run **virtualised** (`RAUMFELD_VIRTUALISED_HARDWARE_ID=9`, no MCU/STA350).
- A **ConnMan D-Bus stub** provides an "online" network on the chroot bus; the real `connmand` is
  neutralised → wlan0 is left untouched.
- The **renderer** runs *non*-virtualised via a wrapper → it opens a real ALSA device (your DAC) instead
  of the network stream server.
- A **bridge** maps the app volume (`hardwared.Volume`) to your DAC's ALSA mixer, and the app's LED
  switch to the Pi's own ACT/PWR LEDs (`VC_LEDS=0` in `vc.conf` leaves them alone). LEDs on a DAC HAT
  are usually wired to the power supply and can't be switched.
- **Connector 2 mode** (automatic when your card has an input, e.g. a HiFiBerry DAC+ ADC): the renderer
  identifies as a real Connector 2, so the app's **EQ** and **LED** settings reach the Pi (see
  [Settings in the app](#settings-in-the-app)). This uses private, patched copies of two firmware
  libraries for the renderer only (`vc-renderer-libs.py`). Without an input, or with `VC_MODE=basic` in
  `vc.conf`, the renderer runs in basic mode.
- Registration as a room uses the AP-less path (`PreconfiguredSetupController` + a simulated setup-button
  + the built-in `SimulatedCalloutServer`); the system-id is then taken over from your host.
- Chroot processes are only ever stopped by their `/proc/<pid>/root`: the firmware's own init scripts use
  `killall`, which would also hit the Pi's own dbus and take WiFi down.
- An **IP watcher** restarts the stack if the IP changes (self-healing); a **static IP** (DHCP reservation)
  is recommended.

## Settings in the app
In Connector 2 mode the app shows all settings of a real Connector 2. They are shown by device type and
can't be hidden individually; the ones that need Connector hardware simply do nothing on the Pi.

| Setting | On the Pi |
|---|---|
| Volume / mute | ✅ Works — the card's volume control (or a software volume) |
| EQ (bass / mid / treble) | ✅ Works — in the renderer's DSP chain, ±6 dB |
| LED | ✅ Works — the Pi's own ACT (green) / PWR (red) LEDs. LEDs on a DAC HAT are usually wired to the power supply and can't be switched |
| Eco mode / standby timer | ✅ Works — the device goes into standby and wakes up when you play something. It saves no power on the Pi: the DAC stays on |
| Fixed clock | ⚪ Accepted by the firmware (it briefly reopens the sound card), but it is meant for the Connector's optical output — no audible effect on a DAC |
| Maximum sample rate | ⚪ No effect — the source rate is played unchanged (e.g. 44.1 or 192 kHz). A DAC that can't handle a rate still works: ALSA converts it automatically |
| Line-in / line-in boost | ⚪ No effect — line-in is not supported |
| Power button behaviour | ⚪ No effect — the Pi has no power button |

In basic mode only volume/mute works; the EQ and LED settings don't reach the Pi.

To see what is playing: `cat /proc/asound/card0/pcm0p/sub0/hw_params` shows the rate sent to the DAC
(the format is always 32-bit, the renderer's output format).

## Components
`install.sh` · `vc-up.sh` / `vc-down.sh` · `vc-master.sh` · `connman-stub.py` · `vc-volume-bridge.py` · `vc-renderer-libs.py` ·
`vc-ip-watch.sh` · `vc-setup.sh` · `vc-connector.service` · `vc-ip-watch.service` · `extract-connector-rootfs.sh`

## Managing it
- Start/stop: `sudo systemctl start|stop vc-connector`
- Volume: via the app. The bridge picks the card's own volume control (e.g. `Digital` on a HiFiBerry,
  `PCM` on the onboard jack) or adds a software volume when there is none (HDMI); curve tunable via `VC_SPANDB`.
- Logs: `/tmp/vc-master.log`, `/tmp/connman-stub.log`, `/tmp/vc-volume-bridge.log`
- Re-register (e.g. after deleting the room in the app): `sudo bash /opt/virtualtools/vc-setup.sh "Room name"`
- Change the audio output: set `VC_CARD` in `/opt/virtualtools/vc.conf` to a card name from `aplay -l`
  (e.g. `sndrpihifiberry`, `Headphones`) and run `sudo systemctl restart vc-connector`.

## ⚠️ Notes
- The installer fetches the newest Connector firmware, so the app reports it as up to date. **Do not run a
  firmware update** on this device if one is ever offered — there is no real flash; reinstall instead.
- Reverse-engineering / interoperability for personal use; not affiliated with Teufel/Raumfeld.
