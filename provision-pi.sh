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
# FIELD_SSID resolves to something (it has a default below) - FIELD_PASSWORD is optional: set it
# for a WPA2-secured hotspot, or leave it blank/unset for an OPEN hotspot (no password - anyone in
# range can join and get a shell on this Pi, so only do this somewhere that's acceptable).
# FACTORY_WIFI_PASSWORD is optional the same way - blank/unset joins an open factory network
# instead of a secured one. e.g.:
#   FIELD_PASSWORD='something-real' FACTORY_WIFI_SSID='OfficeWifi' FACTORY_WIFI_PASSWORD='...' ./provision-pi.sh
#   FACTORY_WIFI_SSID='OfficeWifi' ./provision-pi.sh   # open hotspot, open factory network
# The built-in radio is identified by its driver (brcmfmac) each run and whatever literal kernel
# name it currently has (wlan0, wlan1, ...) is written directly into the config files - same as
# the proven Teleonome pattern this is ported from. If you add/remove the USB adapter later and
# reboot, re-run this script so it re-detects and rewrites the config with the current names.
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
REPO_URL="${REPO_URL:-git@github.com:arifainchtein/PaulaUploader.git}"
FIELD_SSID="${FIELD_SSID:-paula-pi-field}"
FIELD_PASSWORD="${FIELD_PASSWORD:-}"
FACTORY_WIFI_SSID="${FACTORY_WIFI_SSID:-}"
FACTORY_WIFI_PASSWORD="${FACTORY_WIFI_PASSWORD:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-AU}"
CONSOLE_FONTSIZE="${CONSOLE_FONTSIZE:-16x32}"

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

echo "== Installing JDK, Maven, PostgreSQL, Python, git, ifupdown, hostapd, dnsmasq, curl =="
sudo apt-get update
sudo apt-get install -y default-jdk maven postgresql python3 python3-pip python-is-python3 rsync git curl \
  ifupdown isc-dhcp-client wpasupplicant hostapd dnsmasq

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

echo "== Detecting WiFi interfaces (built-in radio vs USB adapter) =="
# Identify the built-in radio by its driver (brcmfmac, Broadcom - what every Pi's onboard WiFi
# uses) instead of by enumeration order; whatever other wifi device shows up (if any) is treated
# as the USB adapter. Pure sysfs, no NetworkManager/nmcli dependency (disabled above).
BUILTIN_WIFI=""
USB_WIFI=""
for dev in $(ls /sys/class/net); do
  [ -d "/sys/class/net/$dev/wireless" ] || continue
  driver=$(basename "$(readlink -f "/sys/class/net/$dev/device/driver" 2>/dev/null)" 2>/dev/null || true)
  if [ "$driver" = "brcmfmac" ] && [ -z "$BUILTIN_WIFI" ]; then
    BUILTIN_WIFI="$dev"
  elif [ "$dev" != "$BUILTIN_WIFI" ] && [ -z "$USB_WIFI" ]; then
    USB_WIFI="$dev"
  fi
done
if [ -z "$BUILTIN_WIFI" ]; then
  echo "Could not identify a brcmfmac (built-in) WiFi radio - falling back to wlan0 for the hotspot."
  BUILTIN_WIFI="wlan0"
fi
echo "Built-in radio (hotspot): $BUILTIN_WIFI"
echo "USB adapter (factory network): ${USB_WIFI:-none detected - plug it in and re-run if you want FactoryNet set up now}"
# These are the CURRENT boot's kernel names, used directly below (no renaming, no MAC pinning) -
# ported as-is from the proven Teleonome pattern, which does the same. If you add/remove the USB
# adapter later, re-run this script so it re-detects and rewrites these files with the current
# names, same as you would on a Teleonome.

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
  sudo tee -a /etc/rc.local > /dev/null <<EOF
ifdown ${USB_WIFI} || true
sleep 2
ifup ${USB_WIFI} || true
sleep 2
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
sudo tee -a /etc/rc.local > /dev/null <<'EOF'
iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null || \
  iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
EOF
echo "exit 0" | sudo tee -a /etc/rc.local > /dev/null
sudo chmod +x /etc/rc.local
sudo systemctl enable rc-local 2>/dev/null || true

echo "== Serial port access without root - dialout group =="
sudo usermod -a -G dialout "$USER"
echo "NOTE: takes effect on next login/reboot, not this shell."

echo "== pyserial for esptool.py (same gotcha the factory NUC itself hit - see project memory) =="
pip3 install --break-system-packages pyserial || pip3 install pyserial

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
if [ ! -d "$TOMCAT_DIR" ]; then
  TOMCAT_TARBALL="/tmp/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
  curl -fsSL -o "$TOMCAT_TARBALL" \
    "https://archive.apache.org/dist/tomcat/tomcat-8/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"
  mkdir -p "$TOMCAT_DIR"
  tar -xzf "$TOMCAT_TARBALL" -C "$TOMCAT_DIR" --strip-components=1
  rm -f "$TOMCAT_TARBALL"
  chmod +x "$TOMCAT_DIR"/bin/*.sh
  echo "Tomcat $TOMCAT_VERSION extracted to $TOMCAT_DIR - deploy a WAR to $TOMCAT_DIR/webapps/,"
  echo "start with $TOMCAT_DIR/bin/startup.sh, stop with $TOMCAT_DIR/bin/shutdown.sh."
else
  echo "Tomcat already present at $TOMCAT_DIR - leaving it as-is (delete the folder and re-run to reinstall)."
fi

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
echo "  - Test: java -jar ~/paulauploader/target/paulauploader.jar sync-pull"
echo "  - Tomcat $TOMCAT_VERSION is at $TOMCAT_DIR - deploy the field-ops webapp's WAR to"
echo "    $TOMCAT_DIR/webapps/, then either reboot or 'sudo systemctl restart pauladeployer-tomcat'"
echo "    - it now starts automatically on every boot via the pauladeployer-tomcat systemd service,"
echo "    no manual startup.sh needed. Use that service (not the raw startup.sh/shutdown.sh scripts)"
echo "    to stop/start it by hand too, so systemd's own state stays in sync."
echo "  - To pick up future code changes: cd ~/paulauploader && git pull && mvn package"
sleep 5
sudo reboot
