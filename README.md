# coin-ops

Infrastructure automation for the coinflipper ecosystem. Ansible playbooks for provisioning a Debian Linode server + Raspberry Pi backup puller.

## Goal

Automate yearly fresh-start Linode rebuilds. From a blank Debian instance to fully running production in one command (plus certbot after DNS propagates).

## Architecture

### Server (Linode, Debian)

- **User:** `jpnance` with sudo + docker group
- **Apps:** Docker Compose, nginx reverse proxy, Let's Encrypt via certbot
- **Dotfiles:** chezmoi (delivers `~/bin/runt` task runner)
- **Network:** Single Docker network `coinflipper` shared by all apps

### Backup (Raspberry Pi)

- Pulls hourly backups from Linode via SCP
- Checks metadata, alerts on stale/missing backups
- Scripts are tightly coupled with server-side backup script

## Apps

| App | Domain | Type | Port | Repo |
|-----|--------|------|------|------|
| CoinFlipper | coinflipper.org | docker | 3000 | jpnance/CoinFlipper |
| Login | login.coinflipper.org | docker | 3001 | jpnance/CoinFlipperLogin |
| SubContest | subcontest.coinflipper.org | docker | 3002 | jpnance/SubContest |
| PickAHit | pickahit.coinflipper.org | docker | 3003 | jpnance/PickAHit |
| Classics | classics.coinflipper.org | docker | 3004 | jpnance/Classics |
| TheDynastyLeague | thedynastyleague.com | docker | 3005 | jpnance/TheDynastyLeague |
| (any static sites) | ??? | static | — | ??? |

*Ports are placeholders—confirm actual values from .env files.*

## Key Decisions

- **Ansible over shell scripts:** Idempotency, templating, structure
- **Runs from laptop:** No agent on server, just SSH
- **HTTPS git cloning:** Public repos, no SSH key bootstrap needed
- **Secrets via Ansible Vault:** Encrypted in repo, decrypted at runtime
- **Vault password in BitWarden:** One password to rule them all
- **chezmoi before app clones:** Delivers `runt` which apps need for `runt ci`
- **Two nginx vhost templates:** `vhost-docker.conf.j2` (reverse proxy) and `vhost-static.conf.j2` (serve files)
- **Docker log rotation:** Set in `/etc/docker/daemon.json`
- **Certbot runs after DNS propagates:** Possibly a separate step/tag

## Server Setup Flow

1. Create Linode (UI or API)
2. Update DNS A records
3. Update `inventory.yml` with new IP
4. Run `ansible-playbook site.yml --ask-vault-pass`
   - Installs: git, vim, jq, nginx, certbot, fail2ban, ufw, Docker
   - Creates user, hardens SSH
   - Creates `coinflipper` Docker network
   - Installs chezmoi + dotfiles
   - Clones all app repos via HTTPS to `~/Workspace/`
   - Templates `.env` files from vault
   - Runs `runt ci && docker compose up -d` for each app
   - Deploys nginx vhosts (HTTP-only initially)
5. Wait for DNS, then run certbot (manually or via `--tags certs`)
6. Install cron jobs (deploy, backup)

## Secrets Needed (vault.yml)

- `coinflipper_*` — various API tokens, DB passwords
- `dynastyleague_*` — similar
- (List actual .env keys here as you build it out)

## File Structure

```
coin-ops/
├── ansible.cfg
├── inventory.yml
├── site.yml
├── group_vars/
│   ├── all.yml          # App definitions, domains, ports
│   └── vault.yml        # Encrypted secrets
├── roles/
│   ├── base/            # apt, firewall, fail2ban, timezone
│   ├── docker/          # Docker CE + daemon config
│   ├── user/            # jpnance user, SSH keys
│   ├── chezmoi/         # Install chezmoi, apply dotfiles
│   ├── apps/            # Clone repos, .env, docker compose
│   ├── nginx/           # Vhost templates
│   └── certs/           # Certbot (run after DNS)
├── templates/
│   ├── vhost-docker.conf.j2
│   ├── vhost-static.conf.j2
│   └── env/
│       └── *.env.j2
├── files/
│   ├── deploy.sh
│   └── backup.sh
├── pi/
│   ├── pull-backups.sh
│   └── alert-check.sh
└── cron/
    ├── deploy
    └── backup
```

## Next Steps

1. Scaffold directory structure
2. Create `group_vars/all.yml` with app list
3. Create `ansible-vault create group_vars/vault.yml`
4. Build roles one at a time, test against throwaway Linode
5. Add Pi backup scripts
