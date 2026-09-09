# PaulaUploader

CLI bridge tool for flashing Daffodil/Wally firmware in the field from a Raspberry Pi ("Paula"),
plus the script that provisions a fresh Pi to run it. Pulls pending deployments and firmware from
the office NUC while on the office network, flashes in the field with no network at all, then
pushes results back once reconnected.

## Provisioning a fresh Pi

The complete process, start to finish, for turning a bare SD card into a working Paula. Run
everything below on the Pi itself, from its own local keyboard/monitor - not over SSH, and not run
remotely by Claude either. The provisioning script reconfigures the network and reboots at the
end; over SSH that can drop the very connection you're using, and there's no way to recover the Pi
remotely if that happens mid-run.

### 1. Flash the SD card

Raspberry Pi OS **Trixie** (64-bit; Lite is fine, no desktop needed), via Raspberry Pi Imager. No
advanced customization needed beyond enabling SSH and a username/password if you want - hostname
and WiFi are set in the next step instead, that's more reliable in practice than the Imager's own
fields for those two. Boot it with a keyboard and monitor connected directly to it.

### 2. First boot - `sudo raspi-config`, in order

- **Localisation Options -> WLAN Country** - set it first. The radio won't transmit at all without
  a country set, so do this before joining any WiFi network below.
- **System Options -> Hostname** - set it (e.g. `paula2`). The field hotspot's SSID defaults to
  this, so each Pi in the field is easy to tell apart.
- **System Options -> Wireless LAN** - join the office/factory WiFi, for internet access during
  setup and so the provisioning script can auto-detect it later (see below).
- Finish, reboot if prompted. Confirm it worked: `ip a show wlan0` should show an IP address.

### 3. Clone and run the provisioning script

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/arifainchtein/PaulaUploader.git
cd PaulaUploader
chmod +x provision-pi.sh
./provision-pi.sh
```

The factory-network WiFi a USB dongle joins for `sync-pull`/`sync-push` defaults to whatever
network you just joined in step 2 (auto-detected via `nmcli` while it's still active) - no need to
type the SSID again. Only override it if you want the dongle on a *different* network than the one
you're currently on, or if it's secured (the password is never auto-detected):

```bash
FACTORY_WIFI_SSID='OfficeWifi' FACTORY_WIFI_PASSWORD='...' ./provision-pi.sh
```

See the comment block at the top of `provision-pi.sh` for every other option (field hotspot
password, console font size, NUC connection details). The script prints the commit it's running
from as its very first line - confirm that matches the latest on GitHub before trusting the rest
of the output, especially if this checkout has sat around a while.

This also clones, builds, and deploys **[PaulaDeployer](https://github.com/arifainchtein/PaulaDeployer)**
(the phone-friendly field webapp) straight into the Pi's own Tomcat - fully working as soon as it
reboots, no separate manual webapp deploy step needed.

The script reboots itself at the end (30-45s to come back up).

### 4. Trust this Pi on the NUC (needed once per Pi, for the esptool/bootloader fetch)

The script generates its own SSH key for talking to the office NUC if one doesn't already exist -
which, on a fresh Pi, it never does. That means **the very first run always skips the esptool/
bootloader fetch** (non-fatal - everything else still installs and works) and prints exactly what
to do next. After the reboot in step 3, from the Pi's own console:

```bash
ssh-copy-id -i ~/.ssh/chilhuacle.pub ari@192.168.1.138
```

(one-time password prompt for the NUC's `ari` user, then never again for this Pi). Then re-run the
script once more - everything else it does is safe to repeat (Postgres/Tomcat/PaulaDeployer all
check for an existing, valid install first), so this second pass only actually needs to do the
esptool fetch:

```bash
./provision-pi.sh
```

### 5. Verify

From a phone/laptop, join the field hotspot (SSID = the hostname you set in step 2) and:

```bash
ssh <user>@192.168.50.1
```

- `java -jar ~/paulauploader/target/paulauploader.jar diagnose-ports` runs without a Java error.
- `http://192.168.50.1/` (or `:8080`) loads PaulaDeployer in a phone's browser.
- `ls ~/.arduino15/packages/esp32/tools/esptool_py/3.0.0/esptool.py` exists (confirms step 4 worked).
- On the factory webapp's Products page, "Send Deploy Package" shows this Paula in the dropdown as
  reachable within a few minutes (it self-registers automatically - no manual database row needed).

## Troubleshooting a provisioning run

Failure modes actually hit during development, and what they mean. `provision-pi.sh` already
handles all of these itself as of the commit documented here - this table is for recognizing them
if an older checkout is used, or if something new shows the same symptoms.

| Symptom | Cause | Fix |
|---|---|---|
| Field hotspot's WiFi comes up, then drops a few seconds later | An unrelated later failure in `rc.local` (e.g. a missing `iptables` binary) makes the whole `rc.local` script exit nonzero; systemd then kills every process in `rc-local.service`'s cgroup, including the `wpa_supplicant` that had just brought the interface up moments earlier | Every command in `rc.local` needs to be guarded (`|| true`) or genuinely safe to fail; `iptables` needs to actually be installed, not just referenced |
| USB WiFi dongle never comes up, `ifup`/`ifdown` hang or fight each other in the boot log | `udev`'s own `allow-hotplug`-triggered `ifup` races `rc.local`'s explicit `ifdown`/`ifup` for the same interface, deadlocking on ifupdown's lock file | Do not set `allow-hotplug` for the USB dongle's interface - only `wlan0`/`eth0` come up fast enough to not race |
| `RTNETLINK answers: Operation not possible due to RF-kill` on every DHCP attempt | NetworkManager normally auto-clears rfkill soft-blocks for wireless devices it manages; disabling it removes that auto-clearing | `rfkill unblock all` right after disabling NetworkManager, and again at the top of `rc.local` on every boot |
| Built-in and USB WiFi swap which is `wlan0` vs `wlan1` across reboots | Kernel enumeration order for wireless interfaces isn't guaranteed | A udev rule pins the builtin radio (`brcmfmac` driver) to a fixed name unconditionally - not "whatever it's currently detected as" |
| Provisioning hangs for 30+ minutes on a clone/build/download step, SSH session also dies | Disabling NetworkManager tears down the *current* connection immediately, not just at the eventual reboot - anything network-dependent that runs after that line has zero connectivity | All network-dependent work (git clones, Maven builds, Tomcat/esptool downloads) must run *before* NetworkManager is touched, not after |
| Fresh Pi's NUC-reachability check fails, esptool/bootloader fetch skipped | The Pi generated its own SSH key for the NUC (no shared key pre-exists) and it was never trusted there | Expected on a first run - see step 4 above (`ssh-copy-id`, then re-run) |
| A Paula shows as "not reachable" in the factory dropdown despite being up | It self-registered with its bare OS hostname instead of the `.local` mDNS form the reachability check expects | Fixed in `WebAppContextListener`/`Main` - self-registration always appends `.local` if not already present |
| A flash reports success but the device visibly was not reflashed | The generated `upload.sh` had no `set -e`, so a failing `esptool` line still fell through to the trailing unconditional `touch firmwareUploadComplete` | Fixed - `set -e` is now the second line of every generated `upload.sh` |

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
