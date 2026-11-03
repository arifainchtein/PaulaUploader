#!/bin/bash
# HTTPS for PaulaDeployer (2026-11-03) - run on YOUR COMPUTER, not on the Pi.
#
# Why: phones only give their GPS to https pages (iPhone: no way around it), and PaulaDeployer's
# Nearby Devices map needs the phone's position as Paula's. Full guide: PaulaUploader/docs/Creating_a_Paula.pdf, section 7.
#
# What it does:
#   1. First run only: creates the Digital Stables root certificate (a private certificate
#      authority) in $CA_DIR - rootCA.key (keep it private, back it up) and rootCA.crt (the one
#      phones install, once).
#   2. Signs a certificate for one Paula: <hostname>.local, <hostname>, Paula's own hotspot
#      address 192.168.50.1, plus any extra names/IPs given, and packs it as a PKCS12 keystore
#      for Tomcat: $CA_DIR/paulas/<hostname>/paula-https.p12
#   3. With --install: copies it to the Pi and runs enable-https.sh there (needs ssh to the Pi and
#      an up-to-date ~/paulauploader checkout on it - git pull first).
#
# Usage:
#   ./make-paula-cert.sh paula3                       # just make the certificate
#   ./make-paula-cert.sh paula3 --install             # make it and install it on pi@paula3.local
#   ./make-paula-cert.sh paula3 172.20.10.2 --install # extra IP/name in the certificate
#   PI_ADDRESS=192.168.1.50 ./make-paula-cert.sh paula3 --install   # ssh to that address instead
#
# Re-running for the same Paula makes a fresh certificate (e.g. before it expires - 825 days,
# the longest an iPhone accepts). The root certificate is never remade once it exists.
set -euo pipefail

CA_DIR="${CA_DIR:-$HOME/DigitalStablesCA}"
PI_USER="${PI_USER:-pi}"
# The keystore only ever lives in Tomcat's conf folder on the Pi, next to server.xml, which holds
# this same password in plain text - so it protects nothing there and is fixed (enable-https.sh
# uses the same one).
KEYSTORE_PASSWORD="paulahttps"
CA_DAYS=3650
CERT_DAYS=825
HOTSPOT_IP="192.168.50.1"

if [ $# -lt 1 ] || [[ "$1" == -* ]]; then
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
HOST="$1"; shift
INSTALL=false
EXTRA=()
for arg in "$@"; do
  if [ "$arg" = "--install" ]; then INSTALL=true; else EXTRA+=("$arg"); fi
done
if ! [[ "$HOST" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "ERROR: '$HOST' is not a plain hostname (letters, digits, '-'; no .local)" >&2
  exit 1
fi

mkdir -p "$CA_DIR"
chmod 700 "$CA_DIR"

# ---- 1. The root certificate (once)
if [ ! -f "$CA_DIR/rootCA.key" ]; then
  echo "== Creating the Digital Stables root certificate in $CA_DIR (first run) =="
  openssl genrsa -out "$CA_DIR/rootCA.key" 3072 2>/dev/null
  chmod 600 "$CA_DIR/rootCA.key"
  openssl req -x509 -new -sha256 -days "$CA_DAYS" -key "$CA_DIR/rootCA.key" \
    -subj "/O=Digital Stables/CN=Digital Stables Paula Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$CA_DIR/rootCA.crt"
  echo "   rootCA.key - KEEP PRIVATE, back it up (losing it means re-installing a new root on every phone)"
  echo "   rootCA.crt - install this on each phone, once (guide section 7)"
else
  echo "== Using the existing root certificate in $CA_DIR =="
fi

# ---- 2. This Paula's certificate
OUT="$CA_DIR/paulas/$HOST"
mkdir -p "$OUT"
SAN="DNS:$HOST.local,DNS:$HOST,IP:$HOTSPOT_IP"
for e in "${EXTRA[@]+"${EXTRA[@]}"}"; do
  if [[ "$e" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then SAN="$SAN,IP:$e"; else SAN="$SAN,DNS:$e"; fi
done
echo "== Signing a certificate for $HOST ($SAN), valid $CERT_DAYS days =="
openssl genrsa -out "$OUT/$HOST.key" 2048 2>/dev/null
chmod 600 "$OUT/$HOST.key"
openssl req -new -sha256 -key "$OUT/$HOST.key" -subj "/O=Digital Stables/CN=$HOST.local" -out "$OUT/$HOST.csr"
cat > "$OUT/$HOST.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$SAN
authorityKeyIdentifier=keyid
subjectKeyIdentifier=hash
EXT
openssl x509 -req -sha256 -days "$CERT_DAYS" -in "$OUT/$HOST.csr" \
  -CA "$CA_DIR/rootCA.crt" -CAkey "$CA_DIR/rootCA.key" -CAcreateserial -CAserial "$CA_DIR/rootCA.srl" \
  -extfile "$OUT/$HOST.ext" -out "$OUT/$HOST.crt" 2>/dev/null
openssl verify -CAfile "$CA_DIR/rootCA.crt" "$OUT/$HOST.crt" >/dev/null
# Tomcat keystore: key + certificate + root (so the phone gets the whole chain)
openssl pkcs12 -export -name tomcat -inkey "$OUT/$HOST.key" -in "$OUT/$HOST.crt" -certfile "$CA_DIR/rootCA.crt" \
  -passout "pass:$KEYSTORE_PASSWORD" -out "$OUT/paula-https.p12"
chmod 600 "$OUT/paula-https.p12"
rm -f "$OUT/$HOST.csr" "$OUT/$HOST.ext"
echo "   $OUT/paula-https.p12 (expires $(openssl x509 -enddate -noout -in "$OUT/$HOST.crt" | cut -d= -f2))"

# ---- 3. Install on the Pi
if $INSTALL; then
  PI="${PI_ADDRESS:-$HOST.local}"
  echo "== Installing on $PI_USER@$PI =="
  scp "$OUT/paula-https.p12" "$PI_USER@$PI:/home/$PI_USER/pauladeployer/tomcat/conf/paula-https.p12"
  ssh "$PI_USER@$PI" "bash ~/paulauploader/https/enable-https.sh"
  echo "== Done: https://$HOST.local/ and https://$HOTSPOT_IP/ (phones need rootCA.crt installed once) =="
else
  echo ""
  echo "Not installed. To install: re-run with --install, or by hand:"
  echo "  scp $OUT/paula-https.p12 $PI_USER@$HOST.local:pauladeployer/tomcat/conf/"
  echo "  ssh $PI_USER@$HOST.local 'bash ~/paulauploader/https/enable-https.sh'"
fi
