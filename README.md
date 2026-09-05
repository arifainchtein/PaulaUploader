# PaulaUploader

CLI bridge tool for flashing Daffodil/Wally firmware in the field from a Raspberry Pi ("Paula"),
plus the script that provisions a fresh Pi to run it. Pulls pending deployments and firmware from
the office NUC while on the office network, flashes in the field with no network at all, then
pushes results back once reconnected.

## Provisioning a fresh Pi

Run on the Pi itself, from its local keyboard/monitor (not over SSH - the script reconfigures
WiFi and reboots, which can kill a remote session riding on that same connection):

```bash
git clone git@github.com:arifainchtein/PaulaUploader.git
cd PaulaUploader
chmod +x provision-pi.sh
./provision-pi.sh
```

Set the Pi's hostname before running it (`raspi-config`, or Raspberry Pi Imager's own
customization step) - the field hotspot's SSID defaults to it, so each Pi in the field is easy to
tell apart (e.g. hostname `paula2` -> hotspot `paula2`).

To also join a factory/office WiFi network for `sync-pull`/`sync-push` (optional but recommended):

```bash
FACTORY_WIFI_SSID='OfficeWifi' FACTORY_WIFI_PASSWORD='...' ./provision-pi.sh
```

See the comment block at the top of `provision-pi.sh` for every other option (field hotspot
password, WiFi country, console font size, NUC connection details).

The script reboots itself at the end. After it comes back up (30-45s), join its field hotspot from
a phone/laptop and `ssh <user>@192.168.50.1`.

## Building and running the CLI

```bash
mvn package
java -jar target/paulauploader.jar <command> [arg]
```

Commands:

| Command | When | What it does |
|---|---|---|
| `sync-pull [nucBaseUrl]` | At the office | Pulls pending deployments and the latest firmware from the NUC. Default `nucBaseUrl` is `http://factoryserver.local`. |
| `watch-flash [timeoutMinutes]` | Before leaving the office | Runs in the background (`nohup`) and waits for Paula's physical switch to be flipped away from its start position and back again in the field, then flashes. Default timeout 240 minutes. |
| `flash` | Bench testing over SSH | Flashes immediately, no switch gesture wait. |
| `flash-direct` | Single-device field setup | Pi 3B + one USB cable straight into the one board being upgraded - no separate Paula controller, no OLED. |
| `diagnose-ports` | Bench verification | Lists every serial port, flags CP2104 candidates, and reports which one (if any) resolves as Paula/Wally. |
| `sync-push [nucBaseUrl]` | Back at the office | Pushes flash results back to the NUC. |

Run with no arguments for the same usage summary.
