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
# factory network. Set FIELD_PASSWORD (required if you want the hotspot set up) and optionally
# FACTORY_WIFI_SSID/FACTORY_WIFI_PASSWORD for the USB adapter, e.g.:
#   FIELD_PASSWORD='something-real' FACTORY_WIFI_SSID='OfficeWifi' FACTORY_WIFI_PASSWORD='...' ./provision-pi.sh
# Assumes the built-in radio enumerates as wlan0 and the USB adapter as wlan1 (the normal default
# boot order) - check with `nmcli device status` first if that seems off.
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

echo "== Installing JDK, Maven, PostgreSQL, Python, git, NetworkManager =="
sudo apt-get update
sudo apt-get install -y default-jdk maven postgresql python3 python3-pip python-is-python3 rsync git network-manager

echo "== Ensure SSH is enabled =="
sudo systemctl enable --now ssh

if [ -n "$FIELD_PASSWORD" ]; then
  echo "== Field hotspot: built-in WiFi (wlan0) hosts SSID '$FIELD_SSID' =="
  # ipv4.method shared also runs NetworkManager's built-in DHCP server for the AP, so phones
  # joining get an address automatically - no separate dnsmasq needed. The built-in Broadcom
  # radio is used for AP mode specifically because it's the well-tested one (brcmfmac driver,
  # the same interface every "Pi as its own hotspot" guide uses) - AP-mode support on USB
  # adapters varies a lot by chipset, so the USB adapter below is only ever asked to do plain
  # client mode, which is close to universal.
  sudo nmcli connection delete Hotspot 2>/dev/null || true
  sudo nmcli connection add type wifi ifname wlan0 con-name Hotspot autoconnect yes ssid "$FIELD_SSID"
  sudo nmcli connection modify Hotspot 802-11-wireless.mode ap 802-11-wireless.band bg
  sudo nmcli connection modify Hotspot ipv4.method shared
  sudo nmcli connection modify Hotspot wifi-sec.key-mgmt wpa-psk
  sudo nmcli connection modify Hotspot wifi-sec.psk "$FIELD_PASSWORD"
  sudo nmcli connection up Hotspot
else
  echo "FIELD_PASSWORD not set - skipping field hotspot setup. Set it and re-run, or configure manually:"
  echo "  sudo nmcli connection add type wifi ifname wlan0 con-name Hotspot ssid '<ssid>'"
  echo "  sudo nmcli connection modify Hotspot 802-11-wireless.mode ap ipv4.method shared \\"
  echo "    wifi-sec.key-mgmt wpa-psk wifi-sec.psk '<password>'"
  echo "  sudo nmcli connection up Hotspot"
fi

if [ -n "$FACTORY_WIFI_SSID" ]; then
  echo "== USB WiFi adapter (wlan1): joining factory network '$FACTORY_WIFI_SSID' =="
  sudo nmcli connection delete FactoryNet 2>/dev/null || true
  sudo nmcli connection add type wifi ifname wlan1 con-name FactoryNet autoconnect yes ssid "$FACTORY_WIFI_SSID"
  if [ -n "$FACTORY_WIFI_PASSWORD" ]; then
    sudo nmcli connection modify FactoryNet wifi-sec.key-mgmt wpa-psk
    sudo nmcli connection modify FactoryNet wifi-sec.psk "$FACTORY_WIFI_PASSWORD"
  fi
  sudo nmcli connection up FactoryNet
else
  echo "FACTORY_WIFI_SSID not set - skipping USB adapter setup. Set it and re-run, or configure manually:"
  echo "  sudo nmcli connection add type wifi ifname wlan1 con-name FactoryNet ssid '<ssid>'"
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

echo ""
echo "== Done. Remaining manual steps =="
echo "1. Log out and back in (or reboot) so dialout group membership takes effect."
echo "2. nmcli device status - confirm wlan0 is the Hotspot connection and wlan1 (if configured) is"
echo "   connected to the factory network; if the interface names came out swapped, redo the nmcli"
echo "   connection commands above with wlan0/wlan1 exchanged."
echo "3. From your phone: join the '$FIELD_SSID' WiFi network, then SSH to this Pi's address on that"
echo "   network (nmcli -f IP4.ADDRESS device show wlan0 to find it - usually 10.42.0.1)."
echo "4. Test: java -jar ~/paulauploader/target/paulauploader.jar sync-pull"
echo ""
echo "To pick up future code changes: cd ~/paulauploader && git pull && mvn package"
