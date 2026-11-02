# Virtual Raumfeld Connector

Run the Raumfeld **Connector** firmware (userspace) in a chroot on a Raspberry Pi, so the Pi — with
its **own DAC** — shows up as a full Raumfeld renderer/room in the Raumfeld app and compatible with Raumfeld multiroom.

## Install (Raspberry Pi OS 32-bit Lite)
```bash
wget -qO- https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main/install.sh | sudo bash
```
The installer asks only one thing, the **audio output**: an external/USB DAC, the onboard 3.5 mm jack,
HDMI, or enable a DAC HAT overlay (then it reboots once and continues by itself). With a DAC the onboard
jack is switched off; set `VC_KEEP_ONBOARD=1` to keep it. The choice is stored by card *name*, so it
survives card renumbering.

Before anything is changed, the installer looks for your **Raumfeld host** on the network (SSDP) and shows
it, e.g. `Raumfeld host found: Raumfeld Soundbar (192.168.1.41)`. If none is found it asks for the host's
IP address to diagnose the problem: a host that is reachable but not discoverable means broadcast/multicast
is blocked between the Pi and your Raumfeld devices (different subnet/VLAN, guest WiFi / client isolation,
IGMP snooping or "multicast enhancement" on the router/access point). Raumfeld itself only finds the host
via broadcast/multicast, so that has to be fixed — entering an IP cannot replace it. Press Enter to install
without setting it up and do that later (see below).

### Setting it up with the Raumfeld app
At the end of the installation the Pi goes into setup mode, **like a real Raumfeld device**: it opens the
WiFi **"Raumfeld Setup"**. In the Raumfeld app you add a device, connect to "Raumfeld Setup" when asked,
choose **LAN or WiFi** (the app shows the WiFi networks the Pi can see) and pick a **room — new or
existing**, so two devices can share a room. The system-id is taken over from your Raumfeld host.
After that everything runs and **starts automatically on reboot**.

- A Pi that only has WiFi is off the network during the setup (its WiFi is the access point), just like a
  real device, and SSH drops. If the setup is not finished within 15 minutes, its own WiFi connection
  comes back.
- To set it up again later (another room, another network): `sudo bash /opt/virtualtools/vc-setup.sh --app`
  — the equivalent of the setup button.
- Without the app: install with `VC_SETUP=auto` (and optionally `VC_ROOM="<name>"`); the installer then
  asks for a room name and registers the Pi as a new room by itself, as earlier versions did.

In the app the device shows up with model **Virtual Connector**; its player follows the standard Raumfeld
naming, `Connector <room name>` (like `Speaker Bar` or `Connector Kitchen`).

Headless/non-interactive: `VC_CARD=<card name>` or `VC_OVERLAY=<overlay>`, `VC_SETUP=app|auto`,
`VC_ROOM="<name>"` (with `auto`), `VC_HOST=<ip>|none` (only used when auto-discovery fails; `VC_DEBUG=1`
for a trace).

## Firmware & copyright
This repo contains **only our own tooling** — no Teufel firmware. On install, the Connector firmware is
fetched **directly from Teufel's official update server** (`updates.raumfeld.com`, hardware id 9) and
the rootfs is extracted locally. We don't redistribute protected firmware; every user obtains it themselves.

## How it works
- Universal AM33xx rootfs (armhf) in a chroot at `/opt/rfconnector`.
- `hardwared`/`master-process` run **virtualised** (`RAUMFELD_VIRTUALISED_HARDWARE_ID=9`, no MCU/STA350).
- A **ConnMan D-Bus stub** (`connman-stub.py`) replaces the firmware's own `connmand` and translates to
  the Pi's NetworkManager: it reports the real cable and WiFi networks, starts the "Raumfeld Setup" access
  point when the firmware asks for it, and connects to the WiFi network chosen in the app. Outside a
  setup it never changes the Pi's network. Installs from before the app setup keep working: their
  connection is still reported the way it was then.
- The **renderer** runs as a real Connector 2 (hardware id 9) but plays to a normal ALSA device (your
  DAC) instead of the virtual network sound card. For that it loads private, patched copies of two
  firmware libraries (`vc-renderer-libs.py`); the other firmware processes keep the originals.
- Audio goes through the firmware's own **DSP plugin** (`pcm.raumfeld`, as on a real device) with your DAC
  as its output. That is where the EQ runs, right in front of the sound card.
- A **bridge** maps the app volume (`hardwared.Volume`) to your DAC's ALSA mixer, and the app's LED
  switch to the Pi's own ACT/PWR LEDs (`VC_LEDS=0` in `vc.conf` leaves them alone). A LED on a DAC HAT
  has no switch of its own (see the table below).
- Because the renderer identifies as a Connector 2, the app's **EQ** and **LED** settings reach the Pi
  (see [Settings in the app](#settings-in-the-app)). This works with any sound card. A real Connector 2
  always has a line-in, and the renderer's timing relies on it: with an input (e.g. a HiFiBerry DAC+ ADC)
  the renderer opens it; without one it gets a silent input from the ALSA loopback (`snd-aloop`),
  clocked by the DAC itself so it cannot drift. `VC_MODE=basic` in `vc.conf` switches all this off: the
  renderer then runs as a plain device and only volume/mute work.
- The setup is the firmware's own: a simulated setup button starts its setup state machine (access point,
  network choice, room). `VC_SETUP=auto` uses the AP-less path instead (`PreconfiguredSetupController` +
  the built-in `SimulatedCalloutServer`).
- Chroot processes are only ever stopped by their `/proc/<pid>/root`: the firmware's own init scripts use
  `killall`, which would also hit the Pi's own dbus and take WiFi down.
- An **IP watcher** restarts the stack if the IP changes (self-healing); a **static IP** (DHCP reservation)
  is recommended.
- The installer switches **WiFi power save off** (NetworkManager, `wifi.powersave = 2`) so the Pi stays
  reachable; install with `VC_KEEP_WIFI_POWERSAVE=1` to leave it alone.

## Settings in the app
The app shows all settings of a real Connector 2. They are shown by device type and can't be hidden
individually; the ones that need Connector hardware simply do nothing on the Pi.

| Setting | On the Pi |
|---|---|
| Volume / mute | ✅ Works — the card's volume control (or a software volume) |
| EQ (bass / mid / treble) | ✅ Works — in the firmware's DSP plugin in front of the DAC, ±6 dB, audible immediately. The firmware's gain correction (lowering the overall level when a band is boosted) is off, so a large boost at full volume can clip |
| LED | ✅ Works — the Pi's own ACT (green) / PWR (red) LEDs, also off in standby (eco mode). A LED on a DAC HAT has no switch of its own: on a HiFiBerry DAC+ ADC it stays on while the DAC is in use and goes off in standby |
| Eco mode / standby timer | ✅ Works — the device goes into standby and wakes up when you play something. It saves no power on the Pi: the DAC stays on |
| Fixed clock | ⚪ Accepted by the firmware (it briefly reopens the sound card), but it is meant for the Connector's optical output — no audible effect on a DAC |
| Maximum sample rate | ⚪ No effect — the source rate is played unchanged (e.g. 44.1 or 192 kHz). A DAC that can't handle a rate still works: ALSA converts it automatically |
| Line-in / line-in boost | ⚪ No effect — line-in is not supported |
| Power button behaviour | ⚪ No effect — the Pi has no power button |

With `VC_MODE=basic` only volume/mute works; the EQ and LED settings don't reach the Pi.

To see what is playing: `cat /proc/asound/card0/pcm0p/sub0/hw_params` shows the rate sent to the DAC
(the format is always 32-bit, the renderer's output format).

## Components
`install.sh` · `vc-up.sh` / `vc-down.sh` · `vc-master.sh` · `connman-stub.py` · `vc-volume-bridge.py` · `vc-renderer-libs.py` ·
`vc-ip-watch.sh` · `vc-setup.sh` · `vc-connector.service` · `vc-ip-watch.service` · `extract-connector-rootfs.sh`

## Managing it
- Start/stop: `sudo systemctl start|stop vc-connector`
- Volume: via the app. The bridge picks the card's own volume control (e.g. `Digital` on a HiFiBerry,
  `PCM` on the onboard jack) or adds a software volume when there is none (HDMI). App volume 1–100 is
  mapped linearly in dB: 100 = `VC_MAXDB`, spanning `VC_SPANDB` (default 50 dB) down to 1. The installer
  sets `VC_MAXDB=-6`, which matched other Raumfeld rooms on a HiFiBerry DAC+ ADC. Louder or quieter than
  your other rooms? Change it in `/opt/virtualtools/vc.conf` (0 = the DAC's full level) and restart
  `vc-connector`.
- Logs: `/tmp/vc-master.log`, `/tmp/connman-stub.log`, `/tmp/vc-volume-bridge.log`
- Set up again (another room or network, or after deleting it in the app):
  `sudo bash /opt/virtualtools/vc-setup.sh --app`, then add it in the Raumfeld app.
  Without the app: `sudo bash /opt/virtualtools/vc-setup.sh "Room name"` (always a new room).
- Plays behind the other devices in its room? Set `VC_DELAY_MS=<ms>` in `/opt/virtualtools/vc.conf` and
  restart `vc-connector`: the renderer then allows that much extra output latency and plays earlier. Tune
  it by ear (one Pi 4 with a HiFiBerry DAC+ HD needed 1850).
- Change the audio output: set `VC_CARD` in `/opt/virtualtools/vc.conf` to a card name from `aplay -l`
  (e.g. `sndrpihifiberry`, `Headphones`) and run `sudo systemctl restart vc-connector`.

## ⚠️ Notes
- The installer fetches the newest Connector firmware, so the app reports it as up to date. **Do not run a
  firmware update** on this device if one is ever offered — there is no real flash; reinstall instead.
- Reverse-engineering / interoperability for personal use; not affiliated with Teufel/Raumfeld.
