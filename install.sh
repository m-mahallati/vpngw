#!/usr/bin/env bash
# Installer for vpngw — run once on the Raspberry Pi:  sudo ./install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "==> installing dependencies"
apt-get update -qq
apt-get install -y dnsmasq iptables curl dnsutils

# dnsmasq is controlled by vpngw, not by systemd at boot
systemctl disable --now dnsmasq >/dev/null 2>&1 || true

echo "==> installing /usr/local/sbin/vpngw"
install -m 0755 "$SRC/vpngw" /usr/local/sbin/vpngw

echo "==> installing systemd unit"
install -m 0644 "$SRC/systemd/vpn-gateway.service" /etc/systemd/system/vpn-gateway.service
systemctl daemon-reload

if [ ! -f /etc/vpngw.conf ]; then
    echo "==> generating /etc/vpngw.conf"

    LAN_IF="$(ip -o -4 addr show scope global | awk '$2 !~ /^(lo|tun|tap|wg|ppp|xvpn)/ {print $2; exit}')"
    LAN_CIDR="$(ip -4 route show dev "$LAN_IF" scope link proto kernel | awk '{print $1; exit}')"
    VPN_IF="$(ls /sys/class/net | grep -E '^(xvpn|tun|wg|nordlynx|proton)' | head -1)"
    VPN_IF="${VPN_IF:-xvpn-tun0}"

    cat > /etc/vpngw.conf <<EOF
# vpngw configuration

# LAN-side interface of the Pi (also its uplink to the access point)
LAN_IF="$LAN_IF"

# Subnet your LAN clients live on
LAN_CIDR="$LAN_CIDR"

# The VPN tunnel interface created by your VPN client
VPN_IF="$VPN_IF"

# Resolvers dnsmasq forwards to. These are queried THROUGH the tunnel.
UPSTREAM_DNS="1.1.1.1 9.9.9.9"

# yes = client traffic is dropped whenever the tunnel is down (no leaks)
KILL_SWITCH=yes

# yes = also block the Pi's OWN queries to UPSTREAM_DNS if they'd leave outside
# the tunnel. Set to no if the Pi's /etc/resolv.conf points at one of them.
DNS_LEAK_GUARD=yes

# yes = block IPv6 forwarding so clients can't bypass the tunnel over v6
BLOCK_IPV6=yes

DNS_CACHE_SIZE=1000
DNSMASQ_SERVICE=dnsmasq

# Per-client exceptions — manage these with:
#   vpngw block <ip> / unblock <ip>     no internet through the Pi at all
#   vpngw bypass <ip> / unbypass <ip>   skip the tunnel, use the normal uplink
BLOCK_IPS=""
BYPASS_IPS=""

# Local accounts on the Pi whose outbound traffic is dropped. They can still
# log in over SSH. Manage with: vpngw user-block <user> / user-unblock <user>
BLOCK_USERS=""
SSH_PORT=22
EOF
    chmod 0644 /etc/vpngw.conf
    echo "    LAN_IF=$LAN_IF  LAN_CIDR=$LAN_CIDR  VPN_IF=$VPN_IF"
else
    echo "==> /etc/vpngw.conf already exists, leaving it alone"
fi

cat <<'EOF'

==> done.

  Review the config:   sudo nano /etc/vpngw.conf
  Turn it on:          sudo vpngw on
  Check it:            sudo vpngw status
  Verify the tunnel:   sudo vpngw test
  Turn it off:         sudo vpngw off
  Survive reboots:     sudo vpngw enable-boot

EOF
