#!/bin/bash
# HTTPS for PaulaDeployer (2026-11-03) - run ON THE PI (make-paula-cert.sh --install does it).
#
# Needs ~/pauladeployer/tomcat/conf/paula-https.p12 (made by make-paula-cert.sh on your computer).
# Then:
#   - adds an HTTPS connector on 8443 to Tomcat's server.xml (once - marked so a re-run skips it)
#   - redirects port 443 to it (iptables, same as 80 -> 8080), now and on every boot (rc.local)
#   - restarts Tomcat
# Plain http on 80/8080 keeps working - phones without the root certificate still get the app,
# just not the GPS. Safe to re-run, e.g. after installing a renewed certificate.
set -euo pipefail

TOMCAT_DIR="${TOMCAT_DIR:-$HOME/pauladeployer/tomcat}"
KEYSTORE="$TOMCAT_DIR/conf/paula-https.p12"
KEYSTORE_PASSWORD="paulahttps"   # same as make-paula-cert.sh
SERVER_XML="$TOMCAT_DIR/conf/server.xml"
MARKER="PaulaDeployer HTTPS (enable-https.sh)"
REDIRECT='{ iptables -t nat -C PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443 2>/dev/null || \
  iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443; } || true'

if [ ! -f "$KEYSTORE" ]; then
  echo "No $KEYSTORE - make one with make-paula-cert.sh on your computer first. HTTPS not enabled."
  exit 1
fi
chmod 600 "$KEYSTORE"

if grep -q "$MARKER" "$SERVER_XML"; then
  echo "== server.xml already has the HTTPS connector =="
else
  echo "== Adding the HTTPS connector (8443) to server.xml =="
  cp "$SERVER_XML" "$SERVER_XML.before-https"
  python3 - "$SERVER_XML" "$MARKER" "$KEYSTORE_PASSWORD" <<'PY'
import sys
path, marker, password = sys.argv[1:4]
s = open(path).read()
connector = f'''
    <!-- {marker}: certificate from make-paula-cert.sh -->
    <Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="50" SSLEnabled="true" scheme="https" secure="true">
        <SSLHostConfig protocols="TLSv1.2+TLSv1.3">
            <Certificate certificateKeystoreFile="conf/paula-https.p12"
                         certificateKeystoreType="PKCS12"
                         certificateKeystorePassword="{password}" type="RSA" />
        </SSLHostConfig>
    </Connector>
'''
# Right after the opening <Service name="Catalina"> - NOT before '<Engine name="Catalina"': the
# stock server.xml has a commented-out example of that line first, and a connector put there
# lands inside the comment and stops Tomcat from starting (found testing on 8.5.100, 2026-11-03).
anchor = '<Service name="Catalina">'
if s.count(anchor) != 1:
    sys.exit("ERROR: expected one <Service name=\"Catalina\"> in server.xml - add the connector by hand (see docs/Creating_a_Paula.pdf, section 7)")
i = s.index(anchor) + len(anchor)
s = s[:i] + '\n' + connector + s[i:]
open(path, 'w').write(s)
PY
fi

echo "== Redirecting port 443 to 8443 =="
sudo sh -c "$REDIRECT"
if [ -f /etc/rc.local ] && ! grep -q "dport 443" /etc/rc.local; then
  # before the final "exit 0" so it runs on every boot, next to the 80 -> 8080 line
  sudo python3 - "$REDIRECT" <<'PY'
import sys
line = sys.argv[1] + '\n'
s = open('/etc/rc.local').read()
i = s.rfind('exit 0')
s = s[:i] + line + s[i:] if i >= 0 else s + line
open('/etc/rc.local', 'w').write(s)
PY
fi

echo "== Restarting Tomcat =="
sudo systemctl restart pauladeployer-tomcat
for i in $(seq 1 30); do
  if curl -sk -o /dev/null https://127.0.0.1:8443/; then
    echo "== HTTPS is up: https://$(hostname).local/ and https://192.168.50.1/ =="
    echo "   Certificate: $(openssl pkcs12 -in "$KEYSTORE" -passin "pass:$KEYSTORE_PASSWORD" -nokeys -clcerts 2>/dev/null | openssl x509 -noout -subject -enddate | tr '\n' ' ')"
    exit 0
  fi
  sleep 2
done
echo "WARNING: nothing answering on https://127.0.0.1:8443 after 60 s - check $TOMCAT_DIR/logs/catalina.out"
echo "(server.xml before this script: $SERVER_XML.before-https)"
exit 1
