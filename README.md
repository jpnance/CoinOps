# CoinOps

Infrastructure automation for the coinflipper ecosystem. Ansible playbooks for provisioning a Debian Linode server and Raspberry Pi backup puller.

## Goal

Automate yearly fresh-start Linode rebuilds. From a blank Debian instance to fully running production in one command.

## Architecture

### Server (Linode, Debian)

- **User:** `jpnance` with sudo + docker group
- **Apps:** Docker Compose behind nginx reverse proxy, HTTPS via Let's Encrypt
- **Dotfiles:** chezmoi (bash, git, vim, tmux configs)
- **Network:** Single Docker network `coinflipper` shared by all apps

### Backup (Raspberry Pi)

- Pulls hourly backups from Linode via SCP
- Validates metadata, alerts on stale/missing/shrinking collections via ntfy
- Monthly golden snapshots, auto-cleanup of old dailies
- **Deployed manually** via `runt deploy-pi` (Pi runs Buster with Python 3.7, too old for modern Ansible)

## Apps

| App | Domain | Port | Repo |
|-----|--------|------|------|
| Coinflipper Login | login.coinflipper.org | 5422 | jpnance/CoinflipperLogin |
| SubContest | subcontest.coinflipper.org | 7811 | jpnance/SubContest |
| Summer Classics | classics.coinflipper.org | 9895 | jpnance/SummerClassics |
| Pick-a-Hit | pickahit.coinflipper.org | 2814 | jpnance/pickahit |
| Primetime Soap Operas | thedynastyleague.com | 9528 | jpnance/PSO |

## Key Decisions

- **Ansible over shell scripts:** Idempotency, templating, structure
- **Runs from laptop:** No agent on server, just SSH
- **Seeder key for server-to-server SSH:** Temporary private key deployed during playbook, deleted at cleanup
- **HTTPS git cloning:** Public repos, no deploy key needed
- **Secrets via Ansible Vault:** Encrypted in repo, password file at `~/.vault_pass`
- **Seed from live prod:** During cutover, databases are seeded directly from the outgoing server
- **Copy certs from old prod:** SSL certificates rsync'd from outgoing server, certbot installed for renewal only
- **Docker from Debian repos:** `docker.io` and `docker-compose` packages (not Docker's official repo)
- **Docker log rotation:** Configured in `/etc/docker/daemon.json`
- **Container restart policy:** `restart: unless-stopped` in all docker-compose files
- **Sequential app provisioning:** Each app is fully set up before moving to the next

## Server Setup Flow

1. Create Linode (Debian, UI or API)
2. Update DNS A records to new IP
3. Update `inventory.yml` with new IP
4. Run `ansible-playbook site.yml`
   - **Preflight:** Verifies old prod is reachable (runs locally)
   - **Bootstrap (as root):** Installs packages, configures firewall, creates user, deploys seeder key
   - **Configure (as jpnance):** Docker, chezmoi, app clones, database seeding, backups, deploy, certs, nginx
   - **Cleanup:** Removes seeder key and temporary configs
5. Verify apps are running: `curl -k https://<new-ip>/ -H "Host: login.coinflipper.org"`
6. Cut over DNS when ready

## Secrets (group_vars/all/vault.yml)

- `vault_google_api_key`
- `vault_pso_fantrax_cookies`
- `vault_login_gmail_*`
- `vault_seeder_private_key` (for new server → old server during cutover)
- `vault_seeder_public_key` (added to old server's authorized_keys)

## File Structure

```
CoinOps/
├── ansible.cfg
├── inventory.yml
├── site.yml
├── group_vars/
│   └── all/
│       ├── vars.yml        # App definitions, domains, ports
│       └── vault.yml       # Encrypted secrets
├── roles/
│   ├── preflight/          # Verify old prod is reachable
│   ├── base/               # apt, ufw, fail2ban, timezone
│   ├── user/               # jpnance user, SSH keys, sudo, seeder key
│   ├── docker/             # Docker, daemon config, network
│   ├── chezmoi/            # Install chezmoi, apply dotfiles
│   ├── apps/               # Clone repos, .env templates, seed DBs, start containers
│   ├── make-backups/       # Backup scripts, cron job
│   ├── deploy/             # Auto-deploy script, cron job
│   ├── certs/              # Copy certs from old prod, install certbot
│   ├── nginx/              # Install nginx, vhost templates
│   ├── cleanup/            # Remove seeder key, temporary configs
│   └── fetch-backups/      # Pi backup script (deployed via runt, not Ansible)
└── runts/
    └── deploy-pi           # Manual deploy of fetch-backups.sh to Pi
```

## Running Specific Roles

*(TODO: Add tags for faster partial runs)*

## Pi Setup

The Raspberry Pi runs Buster (Python 3.7) which is too old for modern Ansible. Deploy manually:

```bash
runt deploy-pi
```

This copies `roles/fetch-backups/files/fetch-backups.sh` to the Pi. Cron jobs must be set up once manually:

```bash
# Fetch backups from Linode hourly
0 * * * * /bin/bash ~/backups/fetch-backups.sh

# Propagate monthly snapshots to offsite backup (5 min later)
5 * * * * /usr/bin/rsync -az ~/backups/monthly/* jpnance@offsite.com:~/backups
```
