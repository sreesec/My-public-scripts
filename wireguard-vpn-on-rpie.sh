#!/bin/bash
# Installation script for a secure WireGuard VPN server on a Raspberry Pi 4 for home use,
# using No-IP for dynamic DNS (A record updates) without SSL certificate configuration.
#
# This script will:
# - Update and upgrade the system.
# - Install WireGuard, UFW, curl, cron, and dnsutils.
# - Generate server and client key pairs.
# - Create the WireGuard configuration with secure permissions.
# - Enable IP forwarding and set up iptables NAT rules.
# - Configure UFW to allow WireGuard traffic.
# - Set up No-IP dynamic DNS (A record) with a cron job.
# - Enable and start WireGuard.
#
# PLEASE EDIT THE VARIABLES AS NEEDED.

set -e

# Ensure the script is run as root.
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

echo "Updating and upgrading the system..."
apt update && apt upgrade -y

echo "Installing required packages..."
apt install -y wireguard wireguard-tools ufw curl cron dnsutils

echo "Loading WireGuard kernel module..."
modprobe wireguard

# Create the WireGuard directory if it doesn't exist.
WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

# Generate server keys if they do not exist.
if [ ! -f "$WG_DIR/privatekey" ]; then
    echo "Generating WireGuard server keys..."
    wg genkey | tee "$WG_DIR/privatekey" | wg pubkey > "$WG_DIR/publickey"
    chmod 600 "$WG_DIR/privatekey"
fi

# Generate a client key pair in a subdirectory.
CLIENT_DIR="$WG_DIR/client"
mkdir -p "$CLIENT_DIR"
if [ ! -f "$CLIENT_DIR/client_privatekey" ]; then
    echo "Generating WireGuard client keys..."
    wg genkey | tee "$CLIENT_DIR/client_privatekey" | wg pubkey > "$CLIENT_DIR/client_publickey"
    chmod 600 "$CLIENT_DIR/client_privatekey"
fi

# Read keys into variables.
SERVER_PRIVATE=$(cat "$WG_DIR/privatekey")
SERVER_PUBLIC=$(cat "$WG_DIR/publickey")
CLIENT_PRIVATE=$(cat "$CLIENT_DIR/client_privatekey")
CLIENT_PUBLIC=$(cat "$CLIENT_DIR/client_publickey")

# Create the WireGuard configuration file.
WG_CONFIG="$WG_DIR/wg0.conf"
cat > "$WG_CONFIG" <<EOF
[Interface]
# Server private key
PrivateKey = $SERVER_PRIVATE
Address = 10.0.0.1/24
ListenPort = 51820
SaveConfig = true
# NAT and forwarding rules (assumes eth0 is your internet interface; adjust if necessary)
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# Home Client
PublicKey = $CLIENT_PUBLIC
AllowedIPs = 10.0.0.2/32
EOF

chmod 600 "$WG_CONFIG"
echo "WireGuard configuration written to $WG_CONFIG"

# Enable IP forwarding.
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# Setup UFW rules.
echo "Configuring UFW firewall..."
# Allow WireGuard UDP port.
ufw allow 51820/udp
ufw --force enable

# ----- No-IP DDNS Setup (for A record updates) -----
echo "Setting up No-IP for dynamic DNS (A record) updates."
read -p "Enter your No-IP hostname (e.g., yourdomain.no-ip.org): " NOIP_HOSTNAME
read -p "Enter your No-IP username: " NOIP_USER
read -p "Enter your No-IP password: " NOIP_PASSWORD

NOIP_DIR="/opt/noip"
mkdir -p "$NOIP_DIR"
cat > "$NOIP_DIR/noip.sh" <<EOF
#!/bin/bash
curl -s -u "$NOIP_USER:$NOIP_PASSWORD" "http://dynupdate.no-ip.com/nic/update?hostname=${NOIP_HOSTNAME}&myip="
EOF
chmod +x "$NOIP_DIR/noip.sh"

# Add a cron job to update No-IP every 5 minutes.
(crontab -l 2>/dev/null; echo "*/5 * * * * $NOIP_DIR/noip.sh >/dev/null 2>&1") | crontab -

# ----- Enable and Start WireGuard -----
echo "Enabling and starting WireGuard service..."
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "WireGuard VPN installation completed successfully!"

# ----- Output Sample Client Configuration -----
echo "----------------------------------------------------"
echo "Client configuration for your home VPN:"
echo ""
cat <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE
Address = 10.0.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $NOIP_HOSTNAME:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
echo "----------------------------------------------------"
echo "Store the above client configuration securely on your client device."
