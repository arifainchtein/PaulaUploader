#!/bin/bash
# Provisions a fresh Raspberry Pi OS (Trixie / Debian 13) install to run paulauploader.
# Run this ON THE PI itself, as the normal "pi" user (needs sudo):
#
#   chmod +x provision-pi.sh
#   ./provision-pi.sh
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
# factory network. Built with plain hostapd + dnsmasq + wpa_supplicant + systemd-networkd, NOT
# NetworkManager/nmcli (confirmed 2026-09-04, the hard way: nmcli's live reconfiguration of an
# interface you're actively SSH'd through - which is unavoidable when the only way to reach this
# Pi at all is the very radio being reconfigured - repeatedly killed the controlling session and,
# with it, the still-foreground provisioning script; a config-files-plus-one-reboot approach has
# no live transition to survive). The hotspot is always set up as long as FIELD_SSID resolves to
# something (it has a default below) - FIELD_PASSWORD is optional: set it for a WPA2-secured
# hotspot, or leave it blank/unset for an OPEN hotspot (no password - anyone in range can join and
# get a shell on this Pi, so only do this somewhere that's acceptable). FACTORY_WIFI_PASSWORD is
# optional the same way - blank/unset joins an open factory network instead of a secured one. e.g.:
#   FIELD_PASSWORD='something-real' FACTORY_WIFI_SSID='OfficeWifi' FACTORY_WIFI_PASSWORD='...' ./provision-pi.sh
#   FACTORY_WIFI_SSID='OfficeWifi' ./provision-pi.sh   # open hotspot, open factory network
# The built-in radio is identified by its driver (brcmfmac) rather than assumed to be wlan0 -
# interface enumeration order isn't guaranteed, so this no longer matters which one comes up first.
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
# there's no live network transition to babysit over SSH. After it reboots (30-45s), join the
# FIELD_SSID network and: ssh <user>@192.168.50.1 - then test with
# java -jar ~/paulauploader/target/paulauploader.jar sync-pull

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

echo "== Installing JDK, Maven, PostgreSQL, Python, git, NetworkManager, hostapd, dnsmasq, curl =="
sudo apt-get update
sudo apt-get install -y default-jdk maven postgresql python3 python3-pip python-is-python3 rsync git network-manager hostapd dnsmasq curl

echo "== Ensure NetworkManager is actually running (still handles Ethernet/general networking) =="
sudo systemctl enable --now NetworkManager
for i in $(seq 1 10); do
  nmcli general status >/dev/null 2>&1 && break
  sleep 1
done
nmcli general status >/dev/null 2>&1 || { echo "NetworkManager did not come up after 10s - check 'systemctl status NetworkManager'."; exit 1; }

echo "== Ensure SSH is enabled =="
sudo systemctl enable ssh
# Tolerate a leftover sshd already bound to :22 from an earlier boot/session (confirmed
# 2026-09-04: `enable --now` failing with "Address already in use" here is harmless - SSH is
# already up and working, just not the instance systemd thinks it's tracking) rather than
# treating that as fatal.
sudo systemctl start ssh || echo "   (ssh.service didn't (re)start - sshd is very likely already listening on :22 from earlier; harmless, continuing)"

echo "== Detecting WiFi interfaces (built-in radio vs USB adapter) =="
# Don't assume wlan0=built-in/wlan1=USB - that's only the normal default boot order, not
# guaranteed. Identify the built-in radio by its driver (brcmfmac, Broadcom - what every Pi's
# onboard WiFi uses) instead of by enumeration order; whatever other wifi device shows up (if
# any) is treated as the USB adapter.
BUILTIN_WIFI=""
USB_WIFI=""
for dev in $(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1}'); do
  driver=$(basename "$(readlink -f "/sys/class/net/$dev/device/driver" 2>/dev/null)" 2>/dev/null || true)
  if [ "$driver" = "brcmfmac" ] && [ -z "$BUILTIN_WIFI" ]; then
    BUILTIN_WIFI="$dev"
  elif [ "$dev" != "$BUILTIN_WIFI" ] && [ -z "$USB_WIFI" ]; then
    USB_WIFI="$dev"
  fi
done
if [ -z "$BUILTIN_WIFI" ]; then
  echo "Could not identify a brcmfmac (built-in) WiFi radio - falling back to wlan0 for the hotspot."
  echo "Run 'nmcli device status' yourself to check this is right before trusting the hotspot."
  BUILTIN_WIFI="wlan0"
fi
echo "Built-in radio (hotspot): $BUILTIN_WIFI"
echo "USB adapter (factory network): ${USB_WIFI:-none detected - plug it in and re-run if you want FactoryNet set up now}"

echo "== Writing field-WiFi config: hostapd+dnsmasq AP on $BUILTIN_WIFI, wpa_supplicant client on ${USB_WIFI:-<none>} =="
# Plain hostapd/dnsmasq/wpa_supplicant/systemd-networkd, not NetworkManager/nmcli - see the
# comment block at the top of this script for why. Every file below is just written to disk and
# every service just enabled (not started) - nothing live changes until the reboot at the very
# end of this script, so there's no in-progress network transition to lose an SSH session over.

sudo tee /etc/NetworkManager/conf.d/99-unmanaged-wifi.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:${BUILTIN_WIFI}$( [ -n "$USB_WIFI" ] && echo ";interface-name:${USB_WIFI}" )
EOF

sudo tee "/etc/systemd/network/10-${BUILTIN_WIFI}-ap.network" > /dev/null <<EOF
[Match]
Name=${BUILTIN_WIFI}

[Network]
Address=192.168.50.1/24
DHCP=no
IPForward=no
EOF

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
ssid=${FIELD_SSID}
hw_mode=g
channel=6
country_code=${WIFI_COUNTRY}
auth_algs=1
wmm_enabled=1
${HOSTAPD_EXTRA}
EOF
grep -q '^DAEMON_CONF=' /etc/default/hostapd 2>/dev/null \
  && sudo sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd \
  || echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee -a /etc/default/hostapd > /dev/null
sudo systemctl unmask hostapd

sudo tee /etc/dnsmasq.d/wlan-ap.conf > /dev/null <<EOF
interface=${BUILTIN_WIFI}
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,24h
EOF

sudo systemctl enable systemd-networkd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq

if [ -n "$USB_WIFI" ]; then
  sudo tee "/etc/systemd/network/20-${USB_WIFI}-client.network" > /dev/null <<EOF
[Match]
Name=${USB_WIFI}

[Network]
DHCP=yes
EOF
  if [ -n "$FACTORY_WIFI_SSID" ]; then
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
    sudo tee "/etc/wpa_supplicant/wpa_supplicant-${USB_WIFI}.conf" > /dev/null <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WIFI_COUNTRY}

${NETBLOCK}
EOF
    sudo systemctl enable "wpa_supplicant@${USB_WIFI}.service"
  else
    echo "FACTORY_WIFI_SSID not set - $USB_WIFI is configured for DHCP but has no network to join yet."
    echo "Set FACTORY_WIFI_SSID and re-run, or write /etc/wpa_supplicant/wpa_supplicant-${USB_WIFI}.conf yourself."
  fi
else
  echo "No USB WiFi adapter detected - skipping factory-network client setup. Plug one in and re-run to add it."
fi

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

echo "== Installing Tomcat for the field-operations webapp (planned - not built yet as of this writing) =="
# 8.5.100 specifically (not "latest 9.x/10.x/11.x") to match the factory NUC's own Tomcat
# (confirmed running 8.5.78) - same javax.servlet.* API (Tomcat 10+ switched to jakarta.servlet.*,
# a breaking rename), so anything modeled on the factory webapp's ProcessingFormHandler pattern
# drops in without a namespace mismatch. Note: the 8.5.x line is EOL (final release, no more
# security patches) - accepted tradeoff for API compatibility with the existing factory webapp,
# but worth knowing if this is meant to run somewhere internet-exposed.
# Self-contained tarball extraction into the project folder rather than `apt install tomcatN` -
# keeps the exact version pinned regardless of whatever Trixie's own package happens to ship, and
# keeps it alongside the rest of this project rather than scattered into system directories.
TOMCAT_VERSION="8.5.100"
TOMCAT_DIR="$HOME/paulauploader/tomcat"
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

echo ""
echo "== Everything installed and configured. Rebooting in 5 seconds to apply it all at once =="
echo "(dialout group membership, the field hotspot, and the factory-network client all need a"
echo "fresh boot to take effect cleanly - this is the only reboot needed, and it's automatic.)"
echo ""
echo "After it comes back up (30-45s):"
echo "  - From your phone/laptop: join the '$FIELD_SSID' WiFi network, then ssh <user>@192.168.50.1"
echo "  - Test: java -jar ~/paulauploader/target/paulauploader.jar sync-pull"
echo "  - Tomcat $TOMCAT_VERSION is at $TOMCAT_DIR - deploy the field-ops webapp's WAR to"
echo "    $TOMCAT_DIR/webapps/ once it exists, then $TOMCAT_DIR/bin/startup.sh."
echo "  - To pick up future code changes: cd ~/paulauploader && git pull && mvn package"
sleep 5
sudo reboot
