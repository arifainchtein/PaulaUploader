#!/bin/bash
# Factory tunnel, router side (2026-11-03) - run on YOUR COMPUTER, on the home network, once per Paula,
# after provision-pi.sh ran on it with FACTORY_TUNNEL_IP set. Guide: docs/Creating_a_Paula.pdf, section 8.
#
# provision-pi.sh gives the Paula its WireGuard key and tunnel address (10.98.0.N) and leaves
# "<public key> <address>" in ~/factory-tunnel.pub on the Pi. This tells the OpenWrt One about it,
# the same way Paula3 was added by hand on 2026-10-25 (doc 07):
#   1. a peer on wg_remote:    network.<name>=wireguard_wg_remote, public_key, allowed_ips <address>/32
#                              (saved with uci, and added live with `wg set` - no network restart, so
#                              the house WiFi stays up)
#   2. a door in the firewall: zone remote, from <address> only, to FACTORY2 192.168.1.138 tcp 1883
#                              (the FactoryChat broker) and nothing else; then a firewall reload
# The chilhuacle relay needs nothing per Paula - it forwards everything for wg_remote already.
#
# Usage:
#   ./add-paula-to-router.sh paula4                         # reads paula4.local's ~/factory-tunnel.pub
#   PAULA_ADDRESS=192.168.1.171 ./add-paula-to-router.sh paula4
#   ./add-paula-to-router.sh paula4 '<public key>' 10.98.0.4  # without asking the Pi
# Re-running for the same Paula updates its entry (e.g. after a new key). To undo, it prints the commands.
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/chilhuacle}"
ROUTER="${ROUTER:-root@192.168.1.1}"
PI_USER="${PI_USER:-pi}"
BROKER_IP="192.168.1.138"
BROKER_PORT="1883"
SSH=(ssh -o IdentitiesOnly=yes -o ConnectTimeout=10 -i "$SSH_KEY")

if [ $# -lt 1 ] || [[ "$1" == -* ]]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
HOST="$1"
if ! [[ "$HOST" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "ERROR: '$HOST' is not a plain hostname (no .local)" >&2
  exit 1
fi

if [ $# -ge 3 ]; then
  PUBKEY="$2"; TUNNEL_IP="$3"
else
  PI="${PAULA_ADDRESS:-$HOST.local}"
  echo "== Reading the tunnel key from $PI_USER@$PI =="
  read -r PUBKEY TUNNEL_IP < <("${SSH[@]}" "$PI_USER@$PI" 'cat ~/factory-tunnel.pub') || {
    echo "ERROR: no ~/factory-tunnel.pub on $PI - run provision-pi.sh there with FACTORY_TUNNEL_IP set first" >&2
    exit 1
  }
fi
if ! [[ "$PUBKEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "ERROR: '$PUBKEY' doesn't look like a WireGuard public key" >&2
  exit 1
fi
if ! [[ "$TUNNEL_IP" =~ ^10\.98\.0\.([0-9]+)$ && ${BASH_REMATCH[1]} -ge 3 && ${BASH_REMATCH[1]} -le 254 ]]; then
  echo "ERROR: tunnel address '$TUNNEL_IP' - expected 10.98.0.N, N from 3 to 254" >&2
  exit 1
fi
# uci section names: letters, digits, underscore
NAME=$(echo "$HOST" | tr 'A-Z-' 'a-z_')
DOOR="door_chat_$NAME"
[ "$NAME" = "paula3" ] && DOOR="door_factorychat"   # Paula3's door was made by hand with this name
LABEL="Cleotilde-Door-FactoryChat-$(echo "${HOST:0:1}" | tr 'a-z' 'A-Z')${HOST:1}"

echo "== Adding $HOST ($TUNNEL_IP, key $PUBKEY) to the router $ROUTER =="
"${SSH[@]}" "$ROUTER" sh -s -- "$NAME" "$PUBKEY" "$TUNNEL_IP" "$DOOR" "$LABEL" "$BROKER_IP" "$BROKER_PORT" <<'ROUTER_SCRIPT'
set -e
NAME=$1 PUBKEY=$2 IP=$3 DOOR=$4 LABEL=$5 BROKER_IP=$6 BROKER_PORT=$7
# The address must not belong to another peer (each one is a different device's identity).
for s in $(uci show network | sed -n "s/^network\.\([^.=]*\)=wireguard_wg_remote$/\1/p"); do
  [ "$s" = "$NAME" ] && continue
  if uci -q get network.$s.allowed_ips | grep -qw "$IP/32"; then
    echo "ERROR: $IP is already used by the router's peer '$s' - give this Paula another FACTORY_TUNNEL_IP" >&2
    exit 1
  fi
done
OLDKEY=$(uci -q get network.$NAME.public_key || true)
uci set network.$NAME=wireguard_wg_remote
uci set network.$NAME.description="$NAME (Paula, provision-pi.sh)"
uci set network.$NAME.public_key="$PUBKEY"
uci set network.$NAME.allowed_ips="$IP/32"
uci commit network
# live, without restarting the network
[ -n "$OLDKEY" ] && [ "$OLDKEY" != "$PUBKEY" ] && wg set wg_remote peer "$OLDKEY" remove
wg set wg_remote peer "$PUBKEY" allowed-ips "$IP/32"

uci set firewall.$DOOR=rule
uci set firewall.$DOOR.name="$LABEL"
uci set firewall.$DOOR.src='remote'
uci set firewall.$DOOR.src_ip="$IP"
uci set firewall.$DOOR.dest='lan'
uci set firewall.$DOOR.dest_ip="$BROKER_IP"
uci set firewall.$DOOR.proto='tcp'
uci set firewall.$DOOR.dest_port="$BROKER_PORT"
uci set firewall.$DOOR.target='ACCEPT'
uci commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1
echo "   peer:"
wg show wg_remote allowed-ips | grep "$PUBKEY" | sed 's/^/     /'
echo "   door: $(uci get firewall.$DOOR.name) - $IP -> $BROKER_IP tcp $BROKER_PORT"
ROUTER_SCRIPT

cat <<EOF
== Done. Test from the field: phone hotspot on, Paula joins it, and within ~30 s
   'journalctl -t factory-tunnel' on Paula says "tunnel up"; 'wg show wg_remote' on the router shows a
   recent handshake for $TUNNEL_IP; Stream 2 Chat works.
   Optional: add "$TUNNEL_IP": "$HOST" to ~/Teleonome/TunnelPeers.json on the Teleonome Pi, so the
   Network Rules panel shows the name instead of the bare address.
   To undo on the router:
     uci delete network.$NAME; uci delete firewall.$DOOR; uci commit; wg set wg_remote peer $PUBKEY remove; /etc/init.d/firewall reload
EOF
