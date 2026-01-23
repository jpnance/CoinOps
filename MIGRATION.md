# Server Migration Guide

This documents the process for migrating to a new server.

## Prerequisites

- New Linode provisioned with latest Debian
- Root SSH access to the new server
- Ansible vault password

## Overview

1. Prepare new server inventory
2. Run Ansible playbook to provision infrastructure
3. Maintenance mode on old server + DNS cutover
4. Transfer database backups from old server
5. Add each app using `add-app.sh` (certbot works because DNS already points here)

## Step 1: Update Inventory

Edit `inventory.yml` with the new server's IP address:

```yaml
servers:
  hosts:
    cloudbreak:
      ansible_host: <NEW_IP_ADDRESS>
```

## Step 2: Run Ansible Playbook

```bash
ansible-playbook site.yml --ask-become-pass
```

Enter your admin password when prompted for BECOME password.

This provisions:
- Admin user with sudo access
- Docker and Docker network
- Chezmoi dotfiles
- Nginx (base install)
- Certbot (for SSL certificates)
- Ops scripts (`deploy.sh`, `up.sh`, `add-app.sh`)
- Backup infrastructure

## Step 3: Maintenance Mode and DNS Cutover

Put the old production server into maintenance mode to prevent writes during migration.

**TODO**: Figure out how to do maintenance mode. Options:
- Nginx static maintenance page
- Docker container stop

Then update DNS to point to the new server's IP. Wait for propagation before proceeding - this ensures certbot can validate domains during Step 5.

```bash
# Check propagation
dig +noall +answer coinflipper.org thedynastyleague.com
```

## Step 4: Transfer Database Backups

From your local machine, pull backups from old production and push to new:

```bash
# Pull from old server
scp oldserver:backups/archives/*.gz ~/migration-seeds/

# Push to new server
scp ~/migration-seeds/*.gz newserver:seeds/
```

Or if you have direct access between servers:

```bash
# From old server
scp backups/archives/*.gz newserver:seeds/
```

## Step 5: Add Apps

SSH to the new server and add each app:

```bash
ssh newserver
mkdir -p ~/seeds  # if not already created
bash ops/add-app.sh
```

For each app, the script will:
1. Clone the repository (or use existing directory)
2. Read `coinops.json` for configuration
3. Prompt to edit `.env` (for node apps)
4. Offer to seed database from `~/seeds/` (for node apps)
5. Obtain SSL certificate via certbot
6. Generate and enable nginx vhost
7. Start containers (for node apps)

### App Types

- **node**: Full-stack apps with Docker containers and MongoDB
- **static**: Static sites served directly by nginx
- **upload**: Manually uploaded content served by nginx
- **service**: Background services (manually configured)

## Post-Migration

### Verify Auto-Deploy

The `deploy.sh` script runs every 5 minutes via cron. Push a change to verify it deploys automatically.

### Verify Backups

Check that hourly backups are running:

```bash
ls -la ~/backups/archives/
```

### Clean Up

- Decommission old server once satisfied
- Remove `~/seeds/` directory if no longer needed

## Troubleshooting

### Containers won't start

Check Docker logs:

```bash
cd ~/apps/<slug>
docker compose logs
```

### Nginx errors

Test configuration:

```bash
sudo nginx -t
```

Check error logs:

```bash
sudo tail -f /var/log/nginx/<domain>.error.log
```

### SSL certificate issues

Re-run certbot manually:

```bash
sudo certbot certonly --standalone -d <domain>
```

Note: Stop nginx first if port 80 is in use:

```bash
sudo systemctl stop nginx
sudo certbot certonly --standalone -d <domain>
sudo systemctl start nginx
```
