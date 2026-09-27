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

It then registers the Pi as a room in the Raumfeld system on your network. **No system-id is needed**:
the Pi adopts the system-id from your Raumfeld host automatically during registration. After that
everything runs and **starts automatically on reboot**.

Headless/non-interactive: `VC_CARD=<card name>` or `VC_OVERLAY=<overlay>`, `VC_ROOM="<name>"`
(`VC_DEBUG=1` for a trace).

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
- A **volume bridge** maps the app volume (`hardwared.Volume`) to your DAC's ALSA mixer.
- Registration as a room uses the AP-less path (`PreconfiguredSetupController` + a simulated setup-button
  + the built-in `SimulatedCalloutServer`); the system-id is then taken over from your host.
- Chroot processes are only ever stopped by their `/proc/<pid>/root`: the firmware's own init scripts use
  `killall`, which would also hit the Pi's own dbus and take WiFi down.
- An **IP watcher** restarts the stack if the IP changes (self-healing); a **static IP** (DHCP reservation)
  is recommended.

## Components
`install.sh` · `vc-up.sh` / `vc-down.sh` · `vc-master.sh` · `connman-stub.py` · `vc-volume-bridge.py` ·
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
