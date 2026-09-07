#!/bin/bash
# Provisions a fresh Raspberry Pi OS (Trixie / Debian 13) install to run paulauploader.
# Run this ON THE PI itself, as the normal "pi" user (needs sudo):
#
#   chmod +x provision-pi.sh
#   ./provision-pi.sh
#
# IMPORTANT: run this from the Pi's own local keyboard/monitor if you can, not over SSH from
# another machine. This script disables NetworkManager partway through and reboots at the end -
# both can drop a remote SSH session riding on the WiFi connection being reconfigured, which kills
# this still-foreground script along with it before it finishes (confirmed in practice). If SSH is
# your only option, background it instead so a dropped connection can't take the script down:
#   nohup ./provision-pi.sh > provision.log 2>&1 &
#   disown
#
# Builds on the Pi itself from a git clone (JDK + Maven), rather than building elsewhere and
# copying a jar over - set REPO_URL below (or export it) to your GitHub repo once it exists.
# Also clones, builds, and deploys PaulaDeployer (the field-ops phone webapp, a separate GitHub
# repo - PAULADEPLOYER_REPO_URL below) straight into this Pi's own Tomcat, so it's answering
# requests as soon as the reboot at the end of this script completes - no separate manual "now go
# build and scp the webapp" step needed afterward.
#
# What this does NOT do: it doesn't touch the factory NUC's own configuration - it only reads a
# few files off it (over SSH, using the same key/user the factory webapp's own deploy step already
# uses, see pom.xml) to get an esptool/bootloader toolchain that's byte-identical to what the NUC
# uses today, rather than risking a version-mismatched one via a fresh arduino-cli install.
#
# Field WiFi (optional but recommended - lets you SSH in from a phone in the field with no other
# network available): the Pi's built-in radio hosts its own AP, a USB WiFi adapter joins the
# factory network. Built with the classic ifupdown + hostapd + dnsmasq + wpa_supplicant stack
# (/etc/network/interfaces, /etc/rc.local), NOT NetworkManager and NOT systemd-networkd - ported
# directly from ~/Data/Teleonome/digitalgeppettowebapp's CreateTeleonome.sh /
# network_with_internal_mode.sh, a dual-WiFi (AP + client) setup proven working in the field for
# years. Two earlier approaches both failed here in practice (2026-09-04): NetworkManager/nmcli's
# live reconfiguration of the interface you're actually SSH'd through kept killing the controlling
# session mid-change; a systemd-networkd + wpa_supplicant@.service + udev-renaming approach fixed
# that but hit a *different* problem - wpa_supplicant@.service has no built-in wait for its device
# to exist, so a USB radio slower to enumerate than the built-in one could race it and silently
# fail. ifupdown sidesteps both: nothing here is started live (see the reboot note below), and
# /etc/rc.local (also written below) brings both radios up at the very end of boot with explicit
# retries, so there's no unit-ordering race to lose. The hotspot is always set up as long as
# FIELD_SSID resolves to something - it defaults to this Pi's own hostname (confirmed 2026-09-06:
# with two Pis in the field at once, a fixed shared default like the old "paula-pi-field" means
# both hotspots broadcast the identical SSID, which just confuses a phone trying to tell them
# apart) - set the hostname before provisioning (raspi-config, or Raspberry Pi Imager's own
# customization step) so it's already right, or override FIELD_SSID explicitly if you want
# something other than the hostname. FIELD_PASSWORD is optional: set it
# for a WPA2-secured hotspot, or leave it blank/unset for an OPEN hotspot (no password - anyone in
# range can join and get a shell on this Pi, so only do this somewhere that's acceptable).
# FACTORY_WIFI_PASSWORD is optional the same way - blank/unset joins an open factory network
# instead of a secured one. e.g.:
#   FIELD_PASSWORD='something-real' FACTORY_WIFI_SSID='OfficeWifi' FACTORY_WIFI_PASSWORD='...' ./provision-pi.sh
#   FACTORY_WIFI_SSID='OfficeWifi' ./provision-pi.sh   # open hotspot, open factory network
# The built-in radio is identified by its driver (brcmfmac) each run, then permanently pinned to
# the fixed name wlan0 via a udev rule (with the USB adapter, if any, always wlan1) - config files
# always target these two fixed names, regardless of whatever the kernel happened to enumerate
# this particular boot (confirmed 2026-09-07: without the udev pin, a plain reboot with no
# hardware changes could swap which physical radio the kernel called wlan0 vs wlan1, silently
# binding the hotspot to the wrong one). If you add/remove the USB adapter later, re-run this
# script so it re-detects whether one is present at all.
# WIFI_COUNTRY (default AU) sets both radios' regulatory domain - required for the built-in radio
# to transmit at all; override if provisioning outside Australia.
#
# CONSOLE_FONTSIZE (default 16x32, a large/readable console-setup size) controls the text-console
# font this script sets on the local monitor/keyboard - override if 16x32 is too big for yours,
# e.g. CONSOLE_FONTSIZE='12x24' ./provision-pi.sh. Valid sizes are whatever `console-setup`'s
# default "Fixed"/"Terminus" faces support (8x16, 10x20, 12x24, 16x32, ...).
#
# This script writes every config file and enables every service it needs, then reboots on its
# own at the very end - nothing WiFi-related is started live, on purpose (see the note above), so
# there's no live network transition to babysit over SSH. After it reboots (30-45s, /etc/rc.local
# needs its own retry-sleeps to finish), join the FIELD_SSID network and: ssh <user>@192.168.50.1
# - then test with java -jar ~/paulauploader/target/paulauploader.jar sync-pull

set -euo pipefail

NUC_HOST="${NUC_HOST:-192.168.1.138}"
NUC_USER="${NUC_USER:-ari}"
NUC_KEY="${NUC_KEY:-$HOME/.ssh/chilhuacle}"
REPO_URL="${REPO_URL:-https://github.com/arifainchtein/PaulaUploader.git}"
PAULADEPLOYER_REPO_URL="${PAULADEPLOYER_REPO_URL:-https://github.com/arifainchtein/PaulaDeployer.git}"
FIELD_SSID="${FIELD_SSID:-$(hostname)}"
FIELD_PASSWORD="${FIELD_PASSWORD:-}"
FACTORY_WIFI_SSID="${FACTORY_WIFI_SSID:-}"
FACTORY_WIFI_PASSWORD="${FACTORY_WIFI_PASSWORD:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-AU}"
CONSOLE_FONTSIZE="${CONSOLE_FONTSIZE:-16x32}"

# Confirmed gotcha (2026-09-07): running an out-of-date checkout of this script (e.g. forgetting
# to `git pull` before re-running) after a bug fix landed here produced confusing, hard-to-diagnose
# symptoms that looked like a fresh bug instead of a stale-version problem. Printing the actual
# commit this checkout is at, every run, makes that immediately obvious instead of needing a
# separate `git log` check.
echo "== provision-pi.sh running from commit: $(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --short HEAD 2>/dev/null || echo 'unknown - not a git checkout') =="

# Done first, before anything else, so the rest of this script's own output benefits too - the
# default console font on a Lite install (no desktop) is tiny on most monitors/TVs. Applied via
# setupcon immediately (no reboot needed) rather than just editing the config file for next boot.
echo "== Enlarging the console font to $CONSOLE_FONTSIZE (default is tiny on most monitors) =="
if grep -q '^FONTSIZE=' /etc/default/console-setup 2>/dev/null; then
  sudo sed -i "s/^FONTSIZE=.*/FONTSIZE=\"$CONSOLE_FONTSIZE\"/" /etc/default/console-setup
else
  echo "FONTSIZE=\"$CONSOLE_FONTSIZE\"" | sudo tee -a /etc/default/console-setup >/dev/null
fi
sudo setupcon --force 2>/dev/null || echo "   (setupcon not available yet - will take effect after first boot's console-setup runs)"

echo "== Installing JDK, Maven, PostgreSQL, Python, git, ifupdown, hostapd, dnsmasq, iptables, curl =="
sudo apt-get update
sudo apt-get install -y default-jdk maven postgresql python3 python3-pip python-is-python3 rsync git curl \
  ifupdown isc-dhcp-client wpasupplicant hostapd dnsmasq iptables

echo "== Disabling NetworkManager - using the classic ifupdown/wpa_supplicant/hostapd stack instead =="
# Ported directly from ~/Data/Teleonome/digitalgeppettowebapp's CreateTeleonome.sh /
# network_with_internal_mode.sh, a dual-WiFi (AP + client) setup that's been working in the field
# for years. NetworkManager's live reconfiguration and systemd-networkd/wpa_supplicant@.service's
# lack of any built-in wait-for-device ordering both caused real, repeated failures earlier
# (2026-09-04) - ifupdown + a retrying /etc/rc.local (below) sidesteps both problems entirely by
# just not depending on systemd unit ordering being right at all.
sudo systemctl disable --now NetworkManager 2>/dev/null || true
sudo systemctl mask NetworkManager 2>/dev/null || true

echo "== Ensure SSH is enabled =="
sudo systemctl enable ssh
# Tolerate a leftover sshd already bound to :22 from an earlier boot/session (confirmed
# 2026-09-04: `enable --now` failing with "Address already in use" here is harmless - SSH is
# already up and working, just not the instance systemd thinks it's tracking) rather than
# treating that as fatal.
sudo systemctl start ssh || echo "   (ssh.service didn't (re)start - sshd is very likely already listening on :22 from earlier; harmless, continuing)"

echo "== Ensure passwordless sudo for $USER =="
# Confirmed gotcha (2026-09-05, again 2026-09-07): this has never actually been guaranteed by
# this script - only assumed, because stock Raspberry Pi OS images usually grant it to the
# initial user automatically. "Usually" isn't "always": one Paula was missing it entirely
# (forced §14.2's Postgres role-creation step to need an interactive terminal), and PaulaDeployer's
# web-triggered Shutdown button silently failed on another - sudo has no TTY to prompt on when
# invoked from a servlet, so without NOPASSWD it just fails immediately and PaulaDeployer had no
# way to notice or report that. `sudo -n true` isn't a reliable way to check this first - it also
# succeeds off a live interactive session's cached credential timestamp, not just real NOPASSWD,
# which would give a false "already fine" here and leave it silently broken again once that
# timestamp expires. Just always (re)write the file instead - safe to run every time, whether or
# not it was already there.
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/010_${USER}-nopasswd" > /dev/null
sudo chmod 440 "/etc/sudoers.d/010_${USER}-nopasswd"

echo "== Detecting WiFi interfaces (built-in radio vs USB adapter) =="
# Identify the built-in radio by its driver (brcmfmac, Broadcom - what every Pi's onboard WiFi
# uses) instead of by enumeration order; whatever other wifi device shows up (if any) is treated
# as the USB adapter. Pure sysfs, no NetworkManager/nmcli dependency (disabled above).
#
# Confirmed gotcha (2026-09-07): kernel enumeration order between the SDIO-attached built-in
# radio and a USB dongle is NOT guaranteed stable across reboots - confirmed directly on Paula2,
# a plain reboot with no hardware changes swapped which physical radio got called wlan0 vs
# wlan1, so hostapd's hardcoded "interface=wlan0" ended up bound to the dongle instead of the
# built-in radio. BUILTIN_WIFI/USB_WIFI below are therefore FIXED target names (wlan0/wlan1),
# used for every config file written further down, regardless of whatever the kernel happened to
# enumerate this boot - CURRENT_BUILTIN_DEV (below) is only used to tell udev what to rename.
# Teleonome's actual CreateTeleonome.sh (after calling network_with_internal_mode.sh) does the
# same thing: pins the built-in radio to a fixed name via a udev rule keyed on its driver - that
# step just hadn't been ported over here until now. Renaming only takes effect on next boot, but
# since every file below already targets the fixed wlan0/wlan1 names, this converges to fully
# correct in the one reboot this script already does at the end - no second run needed.
CURRENT_BUILTIN_DEV=""
DONGLE_PRESENT=false
for dev in $(ls /sys/class/net); do
  [ -d "/sys/class/net/$dev/wireless" ] || continue
  driver=$(basename "$(readlink -f "/sys/class/net/$dev/device/driver" 2>/dev/null)" 2>/dev/null || true)
  if [ "$driver" = "brcmfmac" ] && [ -z "$CURRENT_BUILTIN_DEV" ]; then
    CURRENT_BUILTIN_DEV="$dev"
  elif [ "$dev" != "$CURRENT_BUILTIN_DEV" ]; then
    DONGLE_PRESENT=true
  fi
done
BUILTIN_WIFI="wlan0"
USB_WIFI=""
if [ "$DONGLE_PRESENT" = true ]; then
  USB_WIFI="wlan1"
fi
if [ -z "$CURRENT_BUILTIN_DEV" ]; then
  echo "Could not identify a brcmfmac (built-in) WiFi radio - proceeding with wlan0 as the hotspot name anyway."
fi
echo "Built-in radio (hotspot): $BUILTIN_WIFI (currently enumerated as ${CURRENT_BUILTIN_DEV:-unknown})"
echo "USB adapter (factory network): ${USB_WIFI:-none detected - plug it in and re-run if you want FactoryNet set up now}"

if [ -n "$CURRENT_BUILTIN_DEV" ]; then
  sudo tee /etc/udev/rules.d/72-static-names.rules > /dev/null <<EOF
ACTION=="add", SUBSYSTEM=="net", DRIVERS=="brcmfmac", NAME="${BUILTIN_WIFI}"
EOF
fi

echo "== Writing field-WiFi config: hostapd+dnsmasq AP on $BUILTIN_WIFI, wpa_supplicant client on ${USB_WIFI:-<none>} =="
# Classic ifupdown/hostapd/dnsmasq/wpa_supplicant stack, ported from
# ~/Data/Teleonome/digitalgeppettowebapp/src/main/webapp/ConfigFiles/:Teleonome/network_with_internal_mode.sh
# and its referenced /etc files - proven working in the field. Every file below is just written to
# disk; nothing is started live here - the /etc/rc.local written further down does all the actual
# interface bring-up, at the very end of boot, with retries, after the reboot at the end of this
# script.
sudo tee /etc/network/interfaces > /dev/null <<EOF
source-directory /etc/network/interfaces.d

auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp

allow-hotplug ${BUILTIN_WIFI}
iface ${BUILTIN_WIFI} inet static
address 192.168.50.1
netmask 255.255.255.0
network 192.168.50.0
broadcast 192.168.50.255
EOF
if [ -n "$USB_WIFI" ]; then
  sudo tee -a /etc/network/interfaces > /dev/null <<EOF

allow-hotplug ${USB_WIFI}
iface ${USB_WIFI} inet dhcp
wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF
fi

HOSTAPD_EXTRA=""
if [ -n "$FIELD_PASSWORD" ]; then
  HOSTAPD_EXTRA="wpa=2
wpa_passphrase=${FIELD_PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP"
  echo "   Hotspot will be WPA2-secured (FIELD_PASSWORD set)."
else
  echo "   WARNING: FIELD_PASSWORD not set - hotspot '$FIELD_SSID' will be OPEN. Anyone in range"
  echo "   can join it and get an SSH session to this Pi. Fine for a quick field test, not for"
  echo "   anywhere you don't control access to. Re-run with FIELD_PASSWORD set to secure it."
fi
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=${BUILTIN_WIFI}
driver=nl80211
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
ssid=${FIELD_SSID}
hw_mode=g
channel=6
country_code=${WIFI_COUNTRY}
ieee80211n=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
${HOSTAPD_EXTRA}
EOF
grep -q '^DAEMON_CONF=' /etc/default/hostapd 2>/dev/null \
  && sudo sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd \
  || echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee -a /etc/default/hostapd > /dev/null
sudo systemctl unmask hostapd
sudo systemctl disable hostapd 2>/dev/null || true   # brought up by /etc/rc.local instead, not systemd at boot

sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
interface=${BUILTIN_WIFI}
listen-address=192.168.50.1
bind-interfaces
domain-needed
bogus-priv
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,12h
EOF
sudo systemctl disable dnsmasq 2>/dev/null || true   # same - rc.local restarts it after hostapd is up

if [ -n "$USB_WIFI" ] && [ -n "$FACTORY_WIFI_SSID" ]; then
  echo "== $USB_WIFI will join factory network '$FACTORY_WIFI_SSID' on next boot =="
  NETBLOCK="network={
    ssid=\"${FACTORY_WIFI_SSID}\"
    key_mgmt=NONE
}"
  if [ -n "$FACTORY_WIFI_PASSWORD" ]; then
    NETBLOCK="network={
    ssid=\"${FACTORY_WIFI_SSID}\"
    psk=\"${FACTORY_WIFI_PASSWORD}\"
}"
  fi
  sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null <<EOF
country=${WIFI_COUNTRY}
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

${NETBLOCK}
EOF
elif [ -n "$USB_WIFI" ]; then
  echo "FACTORY_WIFI_SSID not set - $USB_WIFI has no network to join yet."
  echo "Set FACTORY_WIFI_SSID and re-run, or write /etc/wpa_supplicant/wpa_supplicant.conf yourself."
else
  echo "No USB WiFi adapter detected - skipping factory-network client setup. Plug one in and re-run to add it."
fi

echo "== Writing /etc/rc.local to bring both radios up at the end of every boot, with retries =="
# Ported directly from Teleonome's working rc.local.withinternal: bringing the AP interface up
# with explicit retries, THEN restarting hostapd/dnsmasq, THEN cycling the client interface, all
# at the very end of boot - this is what actually avoids the startup-ordering races that hit
# systemd-managed equivalents (confirmed 2026-09-04).
sudo tee /etc/rc.local > /dev/null <<EOF
#!/bin/sh -e
ifup ${BUILTIN_WIFI} || true
sleep 5
ifup ${BUILTIN_WIFI} || true
sleep 2
service hostapd restart
sleep 3
service dnsmasq restart
sleep 2
EOF
if [ -n "$USB_WIFI" ]; then
  # Confirmed gotcha (2026-09-07): a single ifup attempt (silently swallowed by || true) wasn't
  # enough for the USB dongle - it needed manual "sudo ifup wlan1" after boot to actually come up,
  # even though this exact line was already present in rc.local. USB device enumeration timing is
  # less predictable than the SDIO-attached built-in radio (which already gets two attempts above)
  # - rc.local running at "the end of boot" doesn't guarantee the dongle's driver has finished
  # initializing by then. Retries up to 6 times, 5s apart (30s worst case), actually checking
  # success (&& break) instead of blindly continuing regardless like the old single-shot did.
  sudo tee -a /etc/rc.local > /dev/null <<EOF
ifdown ${USB_WIFI} || true
sleep 2
i=0
while [ \$i -lt 6 ]; do
  ifup ${USB_WIFI} && break || true
  i=\$((i+1))
  sleep 5
done
EOF
fi
# Lets PaulaDeployer (or anything else on 8080) be reached at plain http://<hostname>/ - port 80
# needs root to bind directly, but Tomcat itself never should (confirmed 2026-09-05: running
# Tomcat as root to get port 80 caused two real bugs - user.home resolving to /root instead of
# /home/pi, and jSerialComm's native library ending up under /root/.jSerialComm where a later
# pi-owned process couldn't reuse it). A kernel-level NAT redirect decouples "needs port 80" from
# "needs to run as root" entirely - Tomcat keeps running as pi on plain 8080, unaware port 80
# exists at all. -C (check) before -A (add) so re-running this (e.g. every boot via rc.local)
# doesn't pile up duplicate rules.
#
# Confirmed gotcha (2026-09-07): iptables was never actually apt-installed by this script (only
# ever mentioned in written manual instructions) - on a fresh Trixie image the binary genuinely
# doesn't exist, so this line failed with "iptables: not found" under rc.local's `set -e`, which
# made the WHOLE script exit nonzero. rc-local.service then failed, and systemd's default
# KillMode killed every process still running in its cgroup - including the wpa_supplicant
# process the WiFi retry loop above had JUST successfully started for wlan1, which is why wlan1
# came up (confirmed in dmesg - a real DHCP lease) and then got torn back down seconds later. Now
# apt-installed for real above, but ALSO guarded with `|| true` here as a second line of defense -
# nothing after the WiFi bring-up in this script should ever be able to kill it again, no matter
# what future edge case shows up here.
sudo tee -a /etc/rc.local > /dev/null <<'EOF'
{ iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null || \
  iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080; } || true
EOF
echo "exit 0" | sudo tee -a /etc/rc.local > /dev/null
sudo chmod +x /etc/rc.local
sudo systemctl enable rc-local 2>/dev/null || true

echo "== Serial port access without root - dialout group =="
sudo usermod -a -G dialout "$USER"
echo "NOTE: takes effect on next login/reboot, not this shell."

echo "== pyserial for esptool.py (same gotcha the factory NUC itself hit - see project memory) =="
# Confirmed gotcha (2026-09-06): even `pip3 install --break-system-packages pyserial` can still
# hit PEP 668's "externally-managed-environment" error on Trixie. Debian's own packaged pyserial
# sidesteps the whole pip-vs-system-Python fight entirely - apt is the sanctioned path here, not
# a pip flag.
sudo apt-get install -y python3-serial

echo "== Local Postgres for paulauploader =="
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='paulauploader'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE paulauploader LOGIN PASSWORD 'paulauploader';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='paulauploader'" | grep -q 1 || \
  sudo -u postgres createdb -O paulauploader paulauploader

psql "postgresql://paulauploader:paulauploader@127.0.0.1:5432/paulauploader" -c "
create table if not exists pendingDeployment(
    id int primary key,
    productid int,
    productname varchar(100),
    serialnumber varchar(50),
    firmwarerepositoryname varchar(100),
    firmwareid int,
    firmwareversion int,
    binpath text,
    partitionspath text,
    downloadedon bigint
);
create table if not exists deploymentResult(
    id serial primary key,
    deploymentid int,
    productid int,
    success boolean,
    firmwareid int,
    firmwareversion int,
    flashedon bigint,
    reported boolean default false
);
create table if not exists deployAttempt(
    id serial primary key,
    manifestfile varchar(200) not null,
    productid int,
    productname varchar(100),
    serialnumber varchar(50),
    reponame varchar(100),
    version int,
    startedon bigint,
    completedon bigint,
    status varchar(20) default 'Running',
    terminallog text,
    reported boolean default false,
    productdefinitionid int
);
"

echo "== Ensure this Pi has an SSH key trusted by the NUC (needed for the rsync fetch below) =="
if [ ! -f "$NUC_KEY" ]; then
  echo "No key at $NUC_KEY yet - generating one now."
  ssh-keygen -t ed25519 -f "$NUC_KEY" -N ""
fi
# If this key was copied in manually (e.g. reusing an existing key from another machine) rather
# than generated fresh above, its permissions often don't survive the copy - ssh silently refuses
# a group/world-readable private key rather than erroring clearly, which looks identical to "not
# trusted yet" from the check below. Fix it unconditionally rather than trying to detect it.
chmod 600 "$NUC_KEY"
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$NUC_KEY" "${NUC_USER}@${NUC_HOST}" true 2>/dev/null; then
  echo "This Pi's key isn't installed on the NUC yet (or the NUC isn't reachable right now)."
  echo "If the NUC is reachable, run this once, then re-run this script:"
  echo "  ssh-copy-id -i ${NUC_KEY}.pub ${NUC_USER}@${NUC_HOST}"
  echo "(it'll ask for ${NUC_USER}'s NUC password once, then never again)"
  exit 1
fi

echo "== Fetching esptool + bootloader files from the NUC (matches FirmwareFlasher's hardcoded paths) =="
mkdir -p "$HOME/.arduino15/packages/esp32/tools/esptool_py/3.0.0"
mkdir -p "$HOME/.arduino15/packages/esp32/hardware/esp32/1.0.6/tools/partitions"
mkdir -p "$HOME/.arduino15/packages/esp32/hardware/esp32/1.0.6/tools/sdk/bin"

rsync -av -e "ssh -i $NUC_KEY" \
  "${NUC_USER}@${NUC_HOST}:.arduino15/packages/esp32/tools/esptool_py/3.0.0/" \
  "$HOME/.arduino15/packages/esp32/tools/esptool_py/3.0.0/"

rsync -av -e "ssh -i $NUC_KEY" \
  "${NUC_USER}@${NUC_HOST}:.arduino15/packages/esp32/hardware/esp32/1.0.6/tools/partitions/boot_app0.bin" \
  "$HOME/.arduino15/packages/esp32/hardware/esp32/1.0.6/tools/partitions/boot_app0.bin"

rsync -av -e "ssh -i $NUC_KEY" \
  "${NUC_USER}@${NUC_HOST}:.arduino15/packages/esp32/hardware/esp32/1.0.6/tools/sdk/bin/bootloader_dio_80m.bin" \
  "$HOME/.arduino15/packages/esp32/hardware/esp32/1.0.6/tools/sdk/bin/bootloader_dio_80m.bin"

echo "== Cloning and building paulauploader from GitHub =="
if [ -d "$HOME/paulauploader/.git" ]; then
  git -C "$HOME/paulauploader" pull
else
  git clone "$REPO_URL" "$HOME/paulauploader"
fi
mvn -f "$HOME/paulauploader/pom.xml" package

echo "== Installing Tomcat for PaulaDeployer (the field-operations webapp, ~/Data/DigitalStables/PaulaDeployer) =="
# 8.5.100 specifically (not "latest 9.x/10.x/11.x") to match the factory NUC's own Tomcat
# (confirmed running 8.5.78) - same javax.servlet.* API (Tomcat 10+ switched to jakarta.servlet.*,
# a breaking rename), so anything modeled on the factory webapp's ProcessingFormHandler pattern
# drops in without a namespace mismatch. Note: the 8.5.x line is EOL (final release, no more
# security patches) - accepted tradeoff for API compatibility with the existing factory webapp,
# but worth knowing if this is meant to run somewhere internet-exposed.
# Lives under ~/pauladeployer, not ~/paulauploader - a separate directory for PaulaDeployer (the
# webapp Tomcat actually serves) rather than nested inside this CLI tool's own project folder,
# even though this script (PaulaUploader's own) is what provisions it. Self-contained tarball
# extraction rather than `apt install tomcatN` - keeps the exact version pinned regardless of
# whatever Trixie's own package happens to ship.
TOMCAT_VERSION="8.5.100"
TOMCAT_DIR="$HOME/pauladeployer/tomcat"
# Confirmed gotcha (2026-09-07): checking just "does $TOMCAT_DIR exist" isn't enough - an earlier
# interrupted run (network hiccup mid-download, disk space, or the script aborting at some later
# step) can leave an empty/partial directory behind from mkdir -p having already run before the
# actual extraction finished. Every run after that then saw the directory "already present" and
# skipped reinstalling forever, silently leaving Tomcat never actually installed. Check for a real
# marker file (bin/catalina.sh, only present after a genuinely complete extraction) instead, and
# wipe out and redo any incomplete leftover rather than trusting it.
if [ ! -x "$TOMCAT_DIR/bin/catalina.sh" ]; then
  rm -rf "$TOMCAT_DIR"
  TOMCAT_TARBALL="/tmp/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
  curl -fsSL -o "$TOMCAT_TARBALL" \
    "https://archive.apache.org/dist/tomcat/tomcat-8/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
  mkdir -p "$TOMCAT_DIR"
  tar -xzf "$TOMCAT_TARBALL" -C "$TOMCAT_DIR" --strip-components=1
  rm -f "$TOMCAT_TARBALL"
  chmod +x "$TOMCAT_DIR"/bin/*.sh
  if [ ! -x "$TOMCAT_DIR/bin/catalina.sh" ]; then
    echo "ERROR: Tomcat extraction did not produce $TOMCAT_DIR/bin/catalina.sh - download or"
    echo "extraction failed. Check disk space (df -h) and network, then re-run."
    exit 1
  fi
  echo "Tomcat $TOMCAT_VERSION extracted to $TOMCAT_DIR - deploy a WAR to $TOMCAT_DIR/webapps/,"
  echo "start with $TOMCAT_DIR/bin/startup.sh, stop with $TOMCAT_DIR/bin/shutdown.sh."
else
  echo "Tomcat already present and looks valid at $TOMCAT_DIR - leaving it as-is (delete the folder and re-run to reinstall)."
fi

# Confirmed gotcha (2026-09-04/05): Tomcat's stock webapps/ROOT sample app shadows any ROOT.war
# dropped in next to it (a directory takes priority over the war of the same name) - remove it
# once, before this Pi's own ROOT.war ever lands, so PaulaDeployer is what actually answers "/".
rm -rf "$TOMCAT_DIR/webapps/ROOT"

echo "== Cloning and building PaulaDeployer (the field-operations webapp) from GitHub =="
# Built here, not copied from a dev machine's scp step - PaulaDeployer's own pom.xml has a
# maven-antrun-plugin that scp's its WAR to a Paula over SSH using a DEV MACHINE's private key
# (see its pom.xml's server.address/private.key properties), which doesn't exist on Paula itself
# and isn't needed here anyway since the build already IS on the target - -Dmaven.antrun.skip=true
# skips that step, then the built WAR is copied straight into Tomcat's webapps/ locally.
if [ -d "$HOME/pauladeployer-src/.git" ]; then
  git -C "$HOME/pauladeployer-src" pull
else
  git clone "$PAULADEPLOYER_REPO_URL" "$HOME/pauladeployer-src"
fi
mvn -f "$HOME/pauladeployer-src/pom.xml" package -Dmaven.antrun.skip=true
cp "$HOME/pauladeployer-src/target/ROOT.war" "$TOMCAT_DIR/webapps/ROOT.war"

echo "== Installing a systemd service so Tomcat starts automatically on every boot =="
# Confirmed gotcha (2026-09-05): without this, Tomcat only ever ran when someone manually SSH'd
# in and ran startup.sh - fine on a bench, useless in the field where there's no monitor/keyboard
# and a power cycle (or a crash) would otherwise leave PaulaDeployer silently unreachable with no
# way to notice short of trying to load it. Type=forking + CATALINA_PID lets systemd track the
# actual java process via Tomcat's own startup.sh/shutdown.sh rather than needing catalina.sh's
# foreground "run" mode. Restart=on-failure so a crash also self-heals without a manual visit.
sudo tee /etc/systemd/system/pauladeployer-tomcat.service > /dev/null <<EOF
[Unit]
Description=Tomcat for PaulaDeployer
After=network.target postgresql.service

[Service]
Type=forking
User=pi
Environment=CATALINA_HOME=$TOMCAT_DIR
Environment=CATALINA_PID=$TOMCAT_DIR/temp/tomcat.pid
ExecStart=$TOMCAT_DIR/bin/startup.sh
ExecStop=$TOMCAT_DIR/bin/shutdown.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable pauladeployer-tomcat

echo ""
echo "== Everything installed and configured. Rebooting in 5 seconds to apply it all at once =="
echo "(dialout group membership, the field hotspot, and the factory-network client all need a"
echo "fresh boot to take effect cleanly - this is the only reboot needed, and it's automatic.)"
echo ""
echo "After it comes back up (30-45s):"
echo "  - From your phone/laptop: join the '$FIELD_SSID' WiFi network, then ssh <user>@192.168.50.1"
echo "  - Test the CLI: java -jar ~/paulauploader/target/paulauploader.jar sync-pull"
echo "  - PaulaDeployer is already built and deployed - just open http://192.168.50.1/ (or"
echo "    :8080) in a phone's browser, no manual WAR copy needed. It starts automatically on"
echo "    every boot via the pauladeployer-tomcat systemd service - use"
echo "    'sudo systemctl {start|stop|restart|status} pauladeployer-tomcat' to control it by hand"
echo "    (not the raw startup.sh/shutdown.sh scripts, so systemd's own state stays in sync)."
echo "  - To pick up future PaulaDeployer code changes: cd ~/pauladeployer-src && git pull &&"
echo "    mvn package -Dmaven.antrun.skip=true && cp target/ROOT.war $TOMCAT_DIR/webapps/ROOT.war"
echo "    && sudo systemctl restart pauladeployer-tomcat"
echo "  - To pick up future code changes: cd ~/paulauploader && git pull && mvn package"
sleep 5
sudo reboot
