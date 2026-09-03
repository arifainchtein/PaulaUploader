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
# factory network. The hotspot is always set up as long as FIELD_SSID resolves to something (it
# has a default below) - FIELD_PASSWORD is optional: set it for a WPA2-secured hotspot, or leave
# it blank/unset for an OPEN hotspot (no password - anyone in range can join and get a shell on
# this Pi, so only do this somewhere that's acceptable). FACTORY_WIFI_PASSWORD is optional the
# same way - blank/unset joins an open factory network instead of a secured one. e.g.:
#   FIELD_PASSWORD='something-real' FACTORY_WIFI_SSID='OfficeWifi' FACTORY_WIFI_PASSWORD='...' ./provision-pi.sh
#   FACTORY_WIFI_SSID='OfficeWifi' ./provision-pi.sh   # open hotspot, open factory network
# The built-in radio is identified by its driver (brcmfmac) rather than assumed to be wlan0 -
# interface enumeration order isn't guaranteed, so this no longer matters which one comes up first.
#
# CONSOLE_FONTSIZE (default 16x32, a large/readable console-setup size) controls the text-console
# font this script sets on the local monitor/keyboard - override if 16x32 is too big for yours,
# e.g. CONSOLE_FONTSIZE='12x24' ./provision-pi.sh. Valid sizes are whatever `console-setup`'s
# default "Fixed"/"Terminus" faces support (8x16, 10x20, 12x24, 16x32, ...).
#
# After this script finishes:
#   1. Log out and back in once (or reboot) so the dialout group membership below takes effect.
#   2. Test: java -jar ~/paulauploader/target/paulauploader.jar sync-pull

set -euo pipefail

NUC_HOST="${NUC_HOST:-192.168.1.137}"
NUC_USER="${NUC_USER:-ari}"
NUC_KEY="${NUC_KEY:-$HOME/.ssh/chilhuacle}"
REPO_URL="${REPO_URL:-git@github.com:arifainchtein/PaulaUploader.git}"
FIELD_SSID="${FIELD_SSID:-paula-pi-field}"
FIELD_PASSWORD="${FIELD_PASSWORD:-}"
FACTORY_WIFI_SSID="${FACTORY_WIFI_SSID:-}"
FACTORY_WIFI_PASSWORD="${FACTORY_WIFI_PASSWORD:-}"
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

echo "== Installing JDK, Maven, PostgreSQL, Python, git, NetworkManager, curl =="
sudo apt-get update
sudo apt-get install -y default-jdk maven postgresql python3 python3-pip python-is-python3 rsync git network-manager curl

echo "== Ensure NetworkManager is actually running (apt install alone doesn't guarantee this) =="
sudo systemctl enable --now NetworkManager
# Give it a moment to come up and register the wifi radios before any nmcli calls below -
# immediately after enable --now, `nmcli device status` can still briefly show "unmanaged" or
# nothing at all while NetworkManager finishes initializing.
for i in $(seq 1 10); do
  nmcli general status >/dev/null 2>&1 && break
  sleep 1
done
nmcli general status >/dev/null 2>&1 || { echo "NetworkManager did not come up after 10s - check 'systemctl status NetworkManager'."; exit 1; }

echo "== Ensure SSH is enabled =="
sudo systemctl enable --now ssh

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

# Assumes a clean Trixie install (no WiFi pre-configured in the Imager, no prior OS on this
# card) - Trixie uses NetworkManager natively, so both radios should already be managed and this
# is just a sanity check, not a fight against a legacy wpa_supplicant/dhcpcd setup. (That WAS a
# real problem once - 2026-09-04, a reused old Bullseye/Teleonome SD card had a standalone
# wpa_supplicant process holding wlan0 from Raspberry Pi Imager's old pre-NetworkManager WiFi
# mechanism, which took real surgery to unwind. Not expected here on a genuinely fresh card, but
# if you ever see "mismatching interface name" on `nmcli connection up`, that confusingly-worded
# error is what an unmanaged device looks like - check `nmcli device status` and `ps aux | grep
# wpa_supplicant` first.)
sudo nmcli device set "$BUILTIN_WIFI" managed yes
[ -n "$USB_WIFI" ] && sudo nmcli device set "$USB_WIFI" managed yes
sleep 2
state=$(nmcli -t -f DEVICE,STATE device status | awk -F: -v d="$BUILTIN_WIFI" '$1==d{print $2}')
if [ "$state" = "unmanaged" ]; then
  echo "$BUILTIN_WIFI is unmanaged - unexpected on a clean Trixie install. Check:"
  echo "  ps aux | grep -i wpa_supplicant   (something already holding the interface?)"
  echo "  cat /etc/NetworkManager/conf.d/*.conf 2>/dev/null   (an unmanaged-devices rule?)"
  echo "Fix whatever's found, then re-run this script."
  exit 1
fi

echo "== Field hotspot: built-in WiFi ($BUILTIN_WIFI) hosts SSID '$FIELD_SSID' =="
# ipv4.method shared also runs NetworkManager's built-in DHCP server for the AP, so phones
# joining get an address automatically - no separate dnsmasq needed. The built-in Broadcom
# radio is used for AP mode specifically because it's the well-tested one (brcmfmac driver,
# the same interface every "Pi as its own hotspot" guide uses) - AP-mode support on USB
# adapters varies a lot by chipset, so the USB adapter below is only ever asked to do plain
# client mode, which is close to universal.
sudo nmcli connection delete Hotspot 2>/dev/null || true
sudo nmcli connection add type wifi ifname "$BUILTIN_WIFI" con-name Hotspot autoconnect yes ssid "$FIELD_SSID"
sudo nmcli connection modify Hotspot 802-11-wireless.mode ap 802-11-wireless.band bg
sudo nmcli connection modify Hotspot ipv4.method shared
if [ -n "$FIELD_PASSWORD" ]; then
  sudo nmcli connection modify Hotspot wifi-sec.key-mgmt wpa-psk
  sudo nmcli connection modify Hotspot wifi-sec.psk "$FIELD_PASSWORD"
  echo "   Secured with WPA2 (FIELD_PASSWORD set)."
else
  echo "   WARNING: FIELD_PASSWORD not set - hotspot '$FIELD_SSID' is OPEN. Anyone in range can"
  echo "   join it and get an SSH session to this Pi. Fine for a quick field test, not for"
  echo "   anywhere you don't control access to. Re-run with FIELD_PASSWORD set to secure it."
fi
sudo nmcli connection up Hotspot

if [ -n "$FACTORY_WIFI_SSID" ] && [ -n "$USB_WIFI" ]; then
  echo "== USB WiFi adapter ($USB_WIFI): joining factory network '$FACTORY_WIFI_SSID' =="
  sudo nmcli connection delete FactoryNet 2>/dev/null || true
  sudo nmcli connection add type wifi ifname "$USB_WIFI" con-name FactoryNet autoconnect yes ssid "$FACTORY_WIFI_SSID"
  if [ -n "$FACTORY_WIFI_PASSWORD" ]; then
    sudo nmcli connection modify FactoryNet wifi-sec.key-mgmt wpa-psk
    sudo nmcli connection modify FactoryNet wifi-sec.psk "$FACTORY_WIFI_PASSWORD"
  fi
  sudo nmcli connection up FactoryNet
elif [ -n "$FACTORY_WIFI_SSID" ] && [ -z "$USB_WIFI" ]; then
  echo "FACTORY_WIFI_SSID set but no USB WiFi adapter detected - plug it in and re-run to set up FactoryNet."
else
  echo "FACTORY_WIFI_SSID not set - skipping USB adapter setup. Set it and re-run, or configure manually:"
  echo "  sudo nmcli connection add type wifi ifname '<usb-iface>' con-name FactoryNet ssid '<ssid>'"
  echo "  sudo nmcli connection modify FactoryNet wifi-sec.key-mgmt wpa-psk wifi-sec.psk '<password>'"
  echo "  sudo nmcli connection up FactoryNet"
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
echo "== Done. Remaining manual steps =="
echo "1. Log out and back in (or reboot) so dialout group membership takes effect."
echo "2. nmcli device status - confirm $BUILTIN_WIFI shows the Hotspot connection and ${USB_WIFI:-<usb-iface>} (if configured) is"
echo "   connected to the factory network."
echo "3. From your phone: join the '$FIELD_SSID' WiFi network, then SSH to this Pi's address on that"
echo "   network (nmcli -f IP4.ADDRESS device show $BUILTIN_WIFI to find it - usually 10.42.0.1)."
echo "4. Test: java -jar ~/paulauploader/target/paulauploader.jar sync-pull"
echo "5. Tomcat $TOMCAT_VERSION is at $TOMCAT_DIR, not yet running anything - deploy the field-ops"
echo "   webapp's WAR to $TOMCAT_DIR/webapps/ once it exists, then $TOMCAT_DIR/bin/startup.sh."
echo ""
echo "To pick up future code changes: cd ~/paulauploader && git pull && mvn package"
