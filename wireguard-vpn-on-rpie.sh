#!/bin/bash
# Combined installation script for a secure WireGuard VPN server on a Raspberry Pi 4 for home use.
# This script will:
# - Update and upgrade the system.
# - Install WireGuard, UFW, Certbot, curl, and cron.
# - Generate server and one client key pair.
# - Create the WireGuard configuration with secure permissions.
# - Enable IP forwarding and setup iptables NAT rules.
# - Configure UFW to allow WireGuard traffic.
# - Set up DuckDNS DDNS with a cron job.
# - Obtain an SSL certificate using Certbot in standalone mode.
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
apt install -y wireguard wireguard-tools ufw certbot curl cron

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
# NAT and forwarding rules (assumes eth0 is your internet interface)
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# Home Client
PublicKey = $CLIENT_PUBLIC
AllowedIPs = 10.0.0.2/32
EOF

echo "WireGuard configuration written to $WG_CONFIG"

# Enable IP forwarding.
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
# Ensure the setting persists.
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# Setup UFW to allow WireGuard traffic.
echo "Configuring UFW to allow UDP port 51820..."
ufw allow 51820/udp
ufw --force enable

# ----- DuckDNS DDNS Setup -----
echo "Setting up DuckDNS for dynamic DNS updates."
read -p "Enter your DuckDNS subdomain (without .duckdns.org): " DUCK_SUBDOMAIN
read -p "Enter your DuckDNS token: " DUCK_TOKEN

DUCK_DIR="/opt/duckdns"
mkdir -p "$DUCK_DIR"
cat > "$DUCK_DIR/duck.sh" <<EOF
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=${DUCK_SUBDOMAIN}&token=${DUCK_TOKEN}&ip=" | curl -k -o ${DUCK_DIR}/duck.log -K -
EOF
chmod +x "$DUCK_DIR/duck.sh"

# Add a cron job to update DuckDNS every 5 minutes.
(crontab -l 2>/dev/null; echo "*/5 * * * * $DUCK_DIR/duck.sh >/dev/null 2>&1") | crontab -

# ----- Certbot SSL Certificate -----
echo "Obtaining an SSL certificate using Certbot."
read -p "Enter your full DDNS domain (e.g., yoursubdomain.duckdns.org): " DDNS_DOMAIN
read -p "Enter your email address for Certbot notifications: " CERTBOT_EMAIL

echo "Stopping any service that might use port 80..."
# If a service is running on port 80, the certbot standalone method will fail.
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true

certbot certonly --standalone -d "$DDNS_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL"

# Optionally, set up a cron job for certificate renewal.
(crontab -l 2>/dev/null; echo "0 0 1 * * certbot renew --quiet") | crontab -

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
Endpoint = $DDNS_DOMAIN:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
echo "----------------------------------------------------"
echo "Store the above client configuration securely on your client device."
