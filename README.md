# PaulaUploader

CLI bridge tool for flashing Daffodil/Wally firmware in the field from a Raspberry Pi ("Paula"),
plus the script that provisions a fresh Pi to run it. Pulls pending deployments and firmware from
the office NUC while on the office network, flashes in the field with no network at all, then
pushes results back once reconnected.

## Provisioning a fresh Pi

Run on the Pi itself, from its local keyboard/monitor - not over SSH, and not run remotely by
Claude either. The script reconfigures the network and reboots at the end; over SSH that can drop
the very connection you're using, and there's no way to recover the Pi remotely if that happens
mid-run.

First, set the hostname (`raspi-config` -> System Options -> Hostname, e.g. `paula2` - the field
hotspot's SSID defaults to it, so each Pi in the field is easy to tell apart) and join the
office/factory WiFi (`raspi-config` -> System Options -> Wireless LAN) for internet access during
setup. Then:

```bash
git clone https://github.com/arifainchtein/PaulaUploader.git
cd PaulaUploader
chmod +x provision-pi.sh
./provision-pi.sh
```

The factory-network WiFi a USB dongle joins for `sync-pull`/`sync-push` defaults to whatever
network you just joined above (auto-detected via `nmcli` while it's still active) - no need to
type the SSID again. Only override it if you want the dongle on a *different* network than the
one you're currently on, or if it's secured (the password is never auto-detected):

```bash
FACTORY_WIFI_SSID='OfficeWifi' FACTORY_WIFI_PASSWORD='...' ./provision-pi.sh
```

See the comment block at the top of `provision-pi.sh` for every other option (field hotspot
password, WiFi country, console font size, NUC connection details).

The script reboots itself at the end. After it comes back up (30-45s), join its field hotspot from
a phone/laptop and `ssh <user>@192.168.50.1`.

This also clones, builds, and deploys **[PaulaDeployer](https://github.com/arifainchtein/PaulaDeployer)**
(the phone-friendly field webapp) straight into the Pi's own Tomcat - the Pi is fully ready to go
as soon as it reboots, no separate manual webapp deploy step needed. Just open
`http://192.168.50.1/` in a phone's browser.

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
