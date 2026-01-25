# Server Migration Guide

This documents the process for migrating to a new server.

## Prerequisites

- New Linode provisioned with latest Debian
- Root SSH access to the new server
- DNS TTL lowered to 1 minute (do this before migration, wait for old TTL to expire from caches)
- Optional: Create a new A record in DNS for `old.coinflipper.org` pointing to old server IP for command-line convenience; `new.coinflipper.org` can point to the new one for quicker propagation

## Overview

1. Run `bootstrap.sh` to provision infrastructure
2. Transfer env files and database backups from old server
3. Maintenance mode on old server + DNS cutover
4. Add each app using `coinops add` (certbot works because DNS points here)

## Step 1: Bootstrap New Server

SSH to the new server as root and run:

```bash
curl -sL https://raw.githubusercontent.com/jpnance/CoinOps/main/bootstrap.sh | bash
```

Or download and run:

```bash
curl -O https://raw.githubusercontent.com/jpnance/CoinOps/main/bootstrap.sh
bash bootstrap.sh
```

This provisions:
- Admin user with sudo access
- Docker and Docker network
- Chezmoi dotfiles (which includes coinops CLI)
- Nginx (base install with ACME challenge support)
- Certbot (for SSL certificates)

## Step 2: Transfer Backups and Environment Files

From your local machine, copy database backups:

```bash
scp -r oldserver:backups/archives/* newserver:seeds/
```

Copy environment files for each app:

```bash
ssh oldserver 'find ./apps -maxdepth 2 -name ".env"' | while read path; do
  slug=$(echo "$path" | cut -d/ -f3)
  scp "oldserver:${path}" "newserver:envs/${slug}.env"
done
```

Or manually:

```bash
for slug in login pso classix pickahit subcontest; do
  scp oldserver:apps/${slug}/.env newserver:envs/${slug}.env
done
```

The `coinops add` script will use these automatically.

## Step 3: Maintenance Mode and DNS Cutover

Put the old production server into maintenance mode to prevent writes during migration.

```bash
# On old server
sudo systemctl stop nginx
```

Then update DNS to point to the new server's IP. With TTL at 1 minute, propagation should be fast. Wait for it before proceeding - this ensures certbot can validate domains during Step 4.

```bash
# Check propagation (should show new IP)
dig +noall +answer coinflipper.org thedynastyleague.com
```

## Step 4: Add Apps

SSH to the new server as your admin user and add apps:

```bash
# One at a time (shows plan, confirms):
coinops add pickahit

# Or batch with no prompts:
for app in pickahit pso login classix subcontest; do
  coinops add $app -y
done
```

For each app, the script will:
1. Clone the repository
2. Read `coinops.json` for configuration
3. Use `~/envs/<slug>.env` if found (or open `.env.example` in editor)
4. Seed database from `~/seeds/<slug>.gz` if found
5. Obtain SSL certificate via certbot
6. Generate and enable nginx vhost
7. Start containers

Use `--no-ssl` if DNS hasn't propagated yet:

```bash
coinops add pickahit --no-ssl
```

### App Types

- **node**: Full-stack apps with Docker containers and MongoDB
- **static**: Static sites served directly by nginx
- **upload**: Manually uploaded content served by nginx
- **service**: Background services (Docker containers, no nginx)

## Post-Migration

### Verify Apps Are Running

```bash
curl https://pickahit.coinflipper.org/
curl https://login.coinflipper.org/
```

### Verify Auto-Deploy

The `coinops deploy` script should run via cron. Push a change to verify it deploys automatically.

### Verify Backups

Run the backup script manually:

```bash
coinops backup
ls -la ~/backups/archives/
```

### Clean Up

- Raise DNS TTL back to 1 hour
- Remove `old.coinflipper.org` and `new.coinflipper.org` DNS records (easy to re-add next migration)
- Decommission old server once satisfied
- Remove `~/seeds/` directory if no longer needed
- Remove `~/envs/` directory if no longer needed

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
sudo certbot certonly --webroot -w /var/www/letsencrypt -d <domain>
```

Or use standalone (stop nginx first):

```bash
sudo systemctl stop nginx
sudo certbot certonly --standalone -d <domain>
sudo systemctl start nginx
```
