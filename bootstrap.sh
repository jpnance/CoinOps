#!/bin/bash
#
# CoinOps Bootstrap Script
#
# This script replicates the Ansible playbook for provisioning a new server.
# Run as root on a fresh Debian/Ubuntu server.
#
# Usage: curl -sL https://raw.githubusercontent.com/jpnance/CoinOps/main/bootstrap.sh | bash
#    or: bash bootstrap.sh
#

set -e

# ==============================================================================
# Configuration
# ==============================================================================

HOSTNAME="cloudbreak"
ADMIN_USER="jpnance"
ADMIN_EMAIL="jpnance@gmail.com"
DOCKER_NETWORK="coinflipper"

SSH_PUBKEYS=(
	"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKuTniiLi5+CqhwTFBIUCbBrN+BVkJvgMBbm83JkM6QF jpnance@countercheck"
	"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEX83/A/iIr0kjKky3yHQGK5hTHceBPheF/EZp6GoHF9 jpnance@salvage"
	"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIP2/rnsL5jNVgJSz8Gmrt3Jw9C5eaIDI7W5UuI/PRpH jpnance@lifeform"
	"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINeQcID7PFRkqFgzAfR2IGP7qu9ZFi9JLNXZ8NslsbK/ jpnance@sherpa"
)


# ==============================================================================
# Preflight checks
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
	echo "This script must be run as root"
	exit 1
fi

echo "==> Starting CoinOps bootstrap..."

# ==============================================================================
# Base system setup (as root)
# ==============================================================================

echo "==> Updating apt cache..."
apt update

echo "==> Installing base packages..."
apt install -y acl fail2ban git jq kitty-terminfo ufw rsync

echo "==> Setting hostname to ${HOSTNAME}..."
hostnamectl set-hostname "${HOSTNAME}"
grep -q "127.0.1.1 ${HOSTNAME}" /etc/hosts || echo "127.0.1.1 ${HOSTNAME}" >> /etc/hosts

echo "==> Setting timezone to UTC..."
timedatectl set-timezone UTC

echo "==> Configuring firewall..."
ufw allow 22/tcp    # ssh
ufw allow 2222/tcp  # ssh jumpbox
ufw allow 80/tcp    # http
ufw allow 443/tcp   # https
ufw --force enable

echo "==> Enabling fail2ban..."
systemctl enable --now fail2ban

echo "==> Configuring SSH..."
sed -i 's/^#\?Port 22$/Port 22/' /etc/ssh/sshd_config
grep -q "^Port 2222" /etc/ssh/sshd_config || sed -i '/^Port 22/a Port 2222' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config

# ==============================================================================
# Create admin user (as root)
# ==============================================================================

echo "==> Creating admin user ${ADMIN_USER}..."
if ! id "${ADMIN_USER}" &>/dev/null; then
	useradd -m -s /bin/bash "${ADMIN_USER}"
fi
usermod -aG sudo "${ADMIN_USER}"

echo "==> Setting up SSH authorized keys..."
admin_home="/home/${ADMIN_USER}"
mkdir -p "${admin_home}/.ssh"
chmod 700 "${admin_home}/.ssh"

> "${admin_home}/.ssh/authorized_keys"
for key in "${SSH_PUBKEYS[@]}"; do
	echo "${key}" >> "${admin_home}/.ssh/authorized_keys"
done
chmod 600 "${admin_home}/.ssh/authorized_keys"
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${admin_home}/.ssh"

echo "==> Setting admin password..."
echo "Enter password for ${ADMIN_USER}:"
passwd "${ADMIN_USER}"

echo "==> Restarting SSH..."
systemctl restart sshd

# ==============================================================================
# Docker (as root, for admin user)
# ==============================================================================

echo "==> Installing Docker..."
apt install -y docker.io docker-compose

echo "==> Adding ${ADMIN_USER} to docker group..."
usermod -aG docker "${ADMIN_USER}"

echo "==> Configuring Docker daemon..."
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

echo "==> Starting Docker..."
systemctl enable --now docker
systemctl restart docker

echo "==> Creating Docker network ${DOCKER_NETWORK}..."
docker network inspect "${DOCKER_NETWORK}" &>/dev/null || docker network create "${DOCKER_NETWORK}"

# ==============================================================================
# Certbot (as root)
# ==============================================================================

echo "==> Installing certbot..."
apt install -y certbot

echo "==> Enabling certbot auto-renewal..."
systemctl enable --now certbot.timer

echo "==> Setting up letsencrypt directories..."
mkdir -p /etc/letsencrypt
mkdir -p /var/www/letsencrypt/.well-known/acme-challenge

echo "==> Downloading SSL config files..."
curl -sL https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
	-o /etc/letsencrypt/options-ssl-nginx.conf
curl -sL https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem \
	-o /etc/letsencrypt/ssl-dhparams.pem

# ==============================================================================
# Nginx (as root)
# ==============================================================================

echo "==> Installing nginx..."
apt install -y nginx

echo "==> Configuring nginx..."
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/default-acme <<'EOF'
server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
EOF

ln -sf /etc/nginx/sites-available/default-acme /etc/nginx/sites-enabled/default-acme

echo "==> Setting up ACLs for www-data..."
setfacl -m u:www-data:x "${admin_home}"

echo "==> Creating apps directory..."
apps_dir="${admin_home}/apps"
mkdir -p "${apps_dir}"
chown "${ADMIN_USER}:${ADMIN_USER}" "${apps_dir}"
setfacl -m u:www-data:x "${apps_dir}"

echo "==> Reloading nginx..."
systemctl reload nginx

# ==============================================================================
# Chezmoi (install as root, configure as admin user)
# ==============================================================================

echo "==> Installing chezmoi..."
if [ ! -f /usr/local/bin/chezmoi ]; then
	sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin
fi

echo "==> Configuring chezmoi for ${ADMIN_USER}..."
chezmoi_config_dir="${admin_home}/.config/chezmoi"
mkdir -p "${chezmoi_config_dir}"

cat > "${chezmoi_config_dir}/chezmoi.toml" <<'EOF'
[data]
tags = [
  "bash",
  "git",
  "mrpretty",
  "production",
  "runt",
  "vim"
]
EOF

chown -R "${ADMIN_USER}:${ADMIN_USER}" "${admin_home}/.config"

echo "==> Initializing and applying chezmoi as ${ADMIN_USER}..."
su - "${ADMIN_USER}" -c "chezmoi init https://github.com/jpnance/chezmoi-dotfiles"
su - "${ADMIN_USER}" -c "chezmoi apply"

# ==============================================================================
# Done
# ==============================================================================

echo ""
echo "=============================================================================="
echo "Bootstrap complete!"
echo "=============================================================================="
echo ""
echo "You can now log in as ${ADMIN_USER}:"
echo "  ssh ${ADMIN_USER}@\$(hostname -I | awk '{print \$1}')"
echo ""
echo "Then set up your apps with:"
echo "  coinops add <repo>"
echo ""
echo "Note: Root login is now disabled. Make sure you can log in as ${ADMIN_USER}"
echo "before closing this session!"
echo ""
