# Virtual Raumfeld Connector

Draai de Raumfeld **Connector**-firmware (userspace) in een chroot op een Raspberry Pi, zodat de Pi
met z'n **eigen DAC** als volwaardige Raumfeld-renderer/kamer in de Raumfeld-app, multiroom,
Home Assistant en Music Assistant verschijnt — zonder de kleine-driver/DSP-beperkingen van een One S,
en **zonder de netwerk-interface van de Pi aan te raken**.

## Installatie (Raspberry Pi OS 32-bit Lite)
```bash
wget -qO- https://raw.githubusercontent.com/Simanias/virtual-raumfeld-connector/main/install.sh | sudo bash
```
De installer vraagt om: **audio-device** (autodetect of kies je DAC), **device-naam** (bv. `Virtual Connector`),
**kamernaam**, en je **Raumfeld system-id**. Daarna draait alles en **start het automatisch na een reboot**.

> **system-id** vind je op een bestaand Raumfeld-toestel in `/var/raumfeld-1.0/system-id` (nodig om het
> toestel in *jouw* systeem te laten verschijnen).

## Firmware & copyright
Deze repo bevat **alleen eigen tooling** — géén Teufel-firmware. De installer haalt de Connector-firmware
bij de installatie **rechtstreeks van Teufel's officiele update-server** (`updates.raumfeld.com`, hardware-id 9)
en pakt daar lokaal de rootfs uit. Zo verspreiden we geen beschermde firmware; elke gebruiker haalt 'm zelf op.

## Hoe het werkt
- Universele AM33xx-rootfs (armhf) in een chroot op `/opt/rfconnector`.
- `hardwared`/`master-process` draaien **virtueel** (`RAUMFELD_VIRTUALISED_HARDWARE_ID=9`, geen MCU/STA350).
- **ConnMan dbus-stub** levert een "online" netwerk op de chroot-bus; de echte `connmand` is onschadelijk gemaakt → wlan0 blijft ongemoeid.
- De **renderer** draait via een wrapper *niet*-virtueel → opent een echt ALSA-device (je DAC) i.p.v. de netwerk-stream-server.
- **Volume-brug** vertaalt de app-volume (`hardwared.Volume`) naar de ALSA-mixer van je DAC.
- Registratie als kamer via het AP-loze pad (`PreconfiguredSetupController` + gesimuleerde setup-knop + `SimulatedCalloutServer`).
- **IP-watcher** herstart de stack als het IP verandert (zelfherstellend); een **vast IP** (DHCP-reservering) wordt aangeraden.

## Onderdelen
`install.sh` · `vc-up.sh` / `vc-down.sh` · `vc-master.sh` · `connman-stub.py` · `vc-volume-bridge.py` ·
`vc-ip-watch.sh` · `vc-setup.sh` · `vc-connector.service` · `vc-ip-watch.service` · `extract-connector-rootfs.sh`

## Beheer
- Start/stop: `sudo systemctl start|stop vc-connector`
- Volume: via de app-knop (brug stelt de DAC-mixer bij; curve instelbaar via `VC_SPANDB`)
- Logs: `/tmp/vc-master.log`, `/tmp/connman-stub.log`, `/tmp/vc-volume-bridge.log`
- Kies je audio-device forceren: `ALSADEV=hw:N sudo bash /opt/virtualtools/vc-up.sh`

## ⚠️ Let op
- **Doe geen firmware-update** vanuit de Raumfeld-app op dit toestel — er is geen echte flash; dat kan de
  virtuele opstelling breken. De installer blokkeert de update-check daarom in de chroot.
- Reverse-engineering/interoperabiliteit voor eigen gebruik; geen affiliatie met Teufel/Raumfeld.
