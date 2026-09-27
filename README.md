# Virtual Raumfeld Connector

Run the Raumfeld **Connector** firmware (userspace) in a chroot on a Raspberry Pi, so the Pi — with
its **own DAC** — shows up as a full Raumfeld renderer/room in the Raumfeld app and compatible with Raumfeld multiroom.

## Install (Raspberry Pi OS 32-bit Lite)
```bash
wget -qO- https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main/install.sh | sudo bash
```
The installer asks for: **audio device** (autodetect or pick your DAC), **device name** (e.g. `Virtual
Connector`), **room name**, and your **Raumfeld system-id**. After that everything runs and **starts
automatically on reboot**.

> **system-id** is the UUID of your Raumfeld system. It is generated once on your host and only lives
> on the Raumfeld devices themselves (`/var/raumfeld-1.0/system-id`); it is not shown in the app. See
> [Getting your system-id](#getting-your-system-id).

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
  + the built-in `SimulatedCalloutServer`).
- An **IP watcher** restarts the stack if the IP changes (self-healing); a **static IP** (DHCP reservation)
  is recommended.

## Getting your system-id
There is no clean way to read it over the network (the app doesn't show it and the config service is
public-key protected). Ways to obtain it:
- If you already run a Virtual Connector (or any device you can SSH into): `cat /var/raumfeld-1.0/system-id`.
- Ask in the project issues / use the value you were given if you set one up before.
- (Planned) auto-join so the installer no longer needs it — see Roadmap.

## Components
`install.sh` · `vc-up.sh` / `vc-down.sh` · `vc-master.sh` · `connman-stub.py` · `vc-volume-bridge.py` ·
`vc-ip-watch.sh` · `vc-setup.sh` · `vc-connector.service` · `vc-ip-watch.service` · `extract-connector-rootfs.sh`

## Managing it
- Start/stop: `sudo systemctl start|stop vc-connector`
- Volume: via the app (the bridge adjusts the DAC mixer; curve tunable via `VC_SPANDB`)
- Logs: `/tmp/vc-master.log`, `/tmp/connman-stub.log`, `/tmp/vc-volume-bridge.log`
- Force a specific audio card: `ALSADEV=hw:N sudo bash /opt/virtualtools/vc-up.sh`

## Roadmap
- Auto-discover / auto-join the system-id (drop the manual system-id step).
- Optional per-DAC volume-control autodetection.

## ⚠️ Notes
- **Do not run a firmware update** from the Raumfeld app on this device — there is no real flash; it can
  break the virtual setup. The installer blocks the update check inside the chroot.
- Reverse-engineering / interoperability for personal use; not affiliated with Teufel/Raumfeld.
