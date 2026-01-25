# coinops

Infrastructure automation for the Coinflipper ecosystem. Shell scripts for provisioning a Debian Linode server and managing apps.

## Goal

Automate yearly fresh-start Linode rebuilds. From a blank Debian instance to fully running production in minutes.

## Quick Start

```bash
# On a fresh Debian server as root:
curl -sL https://raw.githubusercontent.com/jpnance/CoinOps/main/bootstrap.sh | bash

# Then as jpnance, add your apps:
for app in pickahit pso login classix subcontest; do
  add-app.sh $app -y
done
```

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

## Scripts

### bootstrap.sh

Provisions a fresh Debian server. Run as root.

- Installs packages (docker, nginx, certbot, etc.)
- Configures firewall, fail2ban, sshd hardening
- Creates admin user with SSH keys
- Installs and applies chezmoi dotfiles

### add-app.sh

Sets up a new app from a GitHub repo.

```bash
add-app.sh <repo> [--no-ssl] [-y]

# Examples:
add-app.sh pickahit              # Clone, configure, start
add-app.sh pickahit --no-ssl     # Skip SSL certificate
add-app.sh pickahit -y           # No confirmation prompt
```

Convention-driven:
- Reads `coinops.json` from repo for configuration
- Uses `~/envs/<slug>.env` if found, else opens `.env.example` in editor
- Seeds from `~/seeds/<slug>.gz` if found
- Generates nginx vhost, obtains SSL cert, starts app

### deploy.sh

Auto-deploy loop. Checks all apps for git changes, pulls and redeploys.

### up.sh

Brings up all apps (runs `up_cmd` from each `coinops.json`).

### make-backups.sh

Creates backups for all apps with `backup_cmd` defined.

### fetch-backups.sh

Pulls backups from server to local machine (runs on Pi or other backup host).

### health-check.sh

Checks site availability, alerts via ntfy on failures.

## Apps

Each app has a `coinops.json` that defines how coinops manages it:

```json
{
  "slug": "pickahit",
  "domain": "pickahit.coinflipper.org",
  "port": 2814,
  "type": "node",
  "deploy_cmd": "docker compose build && docker compose up -d",
  "up_cmd": "docker compose up -d",
  "backup_cmd": "docker exec pickahit-mongo mongodump ...",
  "mongo_container": "pickahit-mongo"
}
```

### Node Apps

| App | Domain | Port |
|-----|--------|------|
| Coinflipper Login | login.coinflipper.org | 5422 |
| SubContest | subcontest.coinflipper.org | 7811 |
| Summer Classics | classics.coinflipper.org | 9895 |
| Pick-a-Hit | pickahit.coinflipper.org | 2814 |
| Primetime Soap Operas | thedynastyleague.com | 9528 |

### Static Sites

| Site | Domain |
|------|--------|
| ProWriterAlpha | pwa.coinflipper.org |
| Coinflipper | coinflipper.org |

### Upload Sites

| Site | Domain |
|------|--------|
| BBGPBG | props.coinflipper.org |

## Migration Flow

1. Create Linode (Debian, UI or API)
2. SSH in as root, run `bootstrap.sh`
3. Transfer env files: `scp oldserver:apps/*/.env newserver:envs/<slug>.env`
4. Transfer seed files: `scp oldserver:backups/archives/* newserver:seeds/`
5. SSH as jpnance, run `add-app.sh <repo>` for each app (or loop with `-y`)
6. Update DNS A records to new IP
7. Verify apps are running

## File Structure

```
coinops/
├── bootstrap.sh           # Server provisioning script
├── bin/
│   └── coinops            # CLI dispatcher
├── commands/
│   ├── add.sh             # App setup
│   ├── deploy.sh          # Auto-deploy loop
│   ├── up.sh              # Bring up apps
│   ├── backup.sh          # Backup creation
│   ├── fetch.sh           # Backup fetching (for Pi)
│   └── health.sh          # Site availability checks
└── README.md
```

## Key Decisions

- **Shell scripts over Ansible:** Simpler, faster, no Python dependency
- **Convention over configuration:** `~/envs/`, `~/seeds/`, `coinops.json`
- **HTTPS by default:** SSL certificates via certbot, automatic renewal
- **Docker from Debian repos:** `docker.io` package (not Docker's official repo)
- **chezmoi for dotfiles:** Consistent shell environment across machines
