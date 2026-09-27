# virtualtools — Virtuele Raumfeld Connector

Draait de Raumfeld **Connector**-firmware (userspace) in een chroot op een Raspberry Pi, zodat de Pi
met z'n eigen DAC als volwaardige Raumfeld-renderer/kamer in de app en multiroom verschijnt — zónder
de kleine-driver/DSP-lock van de One S, en zonder de echte netwerk-interface aan te raken.

## Aanpak (kort)
- Universele AM33xx-rootfs in een chroot op `/opt/rfconnector` (armhf, draait native op Pi 3+).
- `hardwared`/`master-process` draaien **virtueel** (`RAUMFELD_VIRTUALISED_HARDWARE_ID=9`, geen MCU/STA350).
- **ConnMan dbus-stub** (`connman-stub.py`) levert een "online" netwerk op de chroot-system-bus, zodat
  master-process tevreden is — de echte `connmand` is onschadelijk gemaakt, wlan0 blijft ongemoeid.
- De **renderer** draait via een wrapper juist **niet**-virtueel → opent een echt ALSA-device
  (`default` → je DAC) i.p.v. de virtuele stream-server.
- **Volume-brug** (`vc-volume-bridge.py`) vertaalt `hardwared.Volume` (wat de app zet) naar de
  ALSA-mixer van de DAC.
- Toestel registreert als kamer via het AP-loze pad (`PreconfiguredSetupController` + gesimuleerde
  setup-knop + ingebouwde `SimulatedCalloutServer`).

## Bestanden (in `/opt/virtualtools`)
| Bestand | Rol |
|---|---|
| `vc-up.sh` | Zet de hele stack op (mounts, ALSA→DAC, dbus/hardwared, stub, master-process, volume-brug). Detecteert de DAC (eerste niet-HDMI kaart). |
| `vc-down.sh` | Stopt alles netjes; laat wlan0 met rust. |
| `vc-master.sh` | Start losstaand master-process (session-bus + key-creator). |
| `connman-stub.py` | Minimale `net.connman` dbus-stub (online ethernet + nep-wifi-tethering voor setup). |
| `vc-volume-bridge.py` | `hardwared.Volume`/`Mute` → ALSA-mixer van de DAC. Arg: `[card] [control]`. |
| `vc-setup.sh` | **Eenmalige** provisioning: registreer als kamer in je systeem. |
| `raumfeld-setup.json` | Sjabloon voor de preconfigured setup. |

## Installatie op een nieuwe Pi
1. Raspberry Pi OS (32-bit/armhf), SSH aan, DAC (bv. HiFiBerry) geconfigureerd; `python3-dbus`+`python3-gi`.
2. Rootfs uitpakken naar `/opt/rfconnector` (zie `extract-connector-rootfs.sh`).
3. Deze tools naar `/opt/virtualtools` (root-owned), en de service installeren:
   ```
   sudo cp -r virtualtools/* /opt/virtualtools/ && sudo chmod +x /opt/virtualtools/*.sh
   sudo cp vc-connector.service /etc/systemd/system/ && sudo systemctl enable --now vc-connector
   ```

## Eenmalig registreren als kamer
```
sudo bash /opt/virtualtools/vc-setup.sh "Woonkamer" <system-id-van-je-systeem>
```
`system-id` staat op elk bestaand Raumfeld-toestel in `/var/raumfeld-1.0/system-id`.
Daarna verschijnt de kamer in de Raumfeld-app (en in Home Assistant/Music Assistant); hernoemen kan in de app.

## Dagelijks gebruik
- Start/stop: `sudo systemctl start|stop vc-connector` (start automatisch bij boot).
- Volume: via de app-knop (de brug stelt de DAC-mixer bij).
- Logs: `/tmp/vc-master.log`, `/tmp/connman-stub.log`, `/tmp/vc-volume-bridge.log`.

## Overschrijfbare instellingen (env)
- `ALSADEV=hw:N` — forceer een specifieke kaart i.p.v. autodetectie.
- In `vc-volume-bridge.py`: `[card] [control]` als argumenten (standaard `Digital`); pas `control` aan
  voor niet-HiFiBerry DAC's (bv. `PCM`, `Master`).
