#!/bin/bash
#
# add-app.sh - Set up a new app from a GitHub repo
#
# Usage: add-app.sh <repo> [--no-ssl] [-y]
#
#   <repo>      GitHub repo (e.g., pickahit, jpnance/pickahit, or full URL)
#   --no-ssl    Skip SSL certificate (default: obtain cert)
#   -y, --yes   Skip confirmation prompt
#

set -e

# ==============================================================================
# Configuration
# ==============================================================================

apps_dir="${HOME}/apps"
backups_dir="${HOME}/backups"
seeds_dir="${HOME}/seeds"
envs_dir="${HOME}/envs"
github_user="jpnance"

# ==============================================================================
# Parse arguments
# ==============================================================================

repo=""
do_ssl=true
auto_yes=false

while [[ $# -gt 0 ]]; do
	case $1 in
		--no-ssl)
			do_ssl=false
			shift
			;;
		-y|--yes)
			auto_yes=true
			shift
			;;
		-*)
			echo "Unknown option: $1"
			exit 1
			;;
		*)
			repo="$1"
			shift
			;;
	esac
done

if [ -z "${repo}" ]; then
	echo "Usage: add-app.sh <repo> [--no-ssl] [-y]"
	echo ""
	echo "  <repo>      GitHub repo (e.g., pickahit, jpnance/pickahit, or full URL)"
	echo "  --no-ssl    Skip SSL certificate (default: obtain cert)"
	echo "  -y, --yes   Skip confirmation prompt"
	exit 1
fi

# ==============================================================================
# Determine repo URL
# ==============================================================================

if [[ "${repo}" == https://* ]] || [[ "${repo}" == git@* ]]; then
	# Full URL provided
	repo_url="${repo}"
	repo_name=$(basename "${repo}" .git)
elif [[ "${repo}" == */* ]]; then
	# owner/repo format
	repo_url="https://github.com/${repo}"
	repo_name=$(basename "${repo}")
else
	# Just repo name, assume github_user
	repo_url="https://github.com/${github_user}/${repo}"
	repo_name="${repo}"
fi

# ==============================================================================
# Clone to temp directory and read config
# ==============================================================================

echo "==> Cloning ${repo_url}..."
temp_dir=$(mktemp -d)
trap 'rm -rf "${temp_dir}"' EXIT

if ! git clone --quiet "${repo_url}" "${temp_dir}/repo"; then
	echo "Error: Failed to clone ${repo_url}"
	exit 1
fi

config="${temp_dir}/repo/coinops.json"
if [ ! -f "${config}" ]; then
	echo "Error: No coinops.json found in ${repo_url}"
	exit 1
fi

# Read config
slug=$(jq -r '.slug // empty' "${config}")
if [ -z "${slug}" ]; then
	echo "Error: No slug defined in coinops.json"
	exit 1
fi

domain=$(jq -r '.domain // empty' "${config}")
port=$(jq -r '.port // empty' "${config}")
app_type=$(jq -r '.type // empty' "${config}")
root=$(jq -r '.root // empty' "${config}")
deploy_cmd=$(jq -r '.deploy_cmd // empty' "${config}")
up_cmd=$(jq -r '.up_cmd // empty' "${config}")
backup_cmd=$(jq -r '.backup_cmd // empty' "${config}")
mongo_container=$(jq -r '.mongo_container // empty' "${config}")

app_dir="${apps_dir}/${slug}"

# ==============================================================================
# Check if app already exists
# ==============================================================================

if [ -d "${app_dir}" ]; then
	echo "Error: ${app_dir} already exists."
	echo ""
	echo "This app is already set up. To manage it:"
	echo "  deploy.sh, up.sh, etc."
	echo ""
	echo "To tear down and rebuild:"
	echo "  rm -rf ${app_dir}"
	echo "  add-app.sh ${repo}"
	exit 1
fi

# ==============================================================================
# Gather plan info
# ==============================================================================

# Check for env file
env_source=""
env_status=""
if [ "${app_type}" = "node" ]; then
	if [ -f "${envs_dir}/${slug}.env" ]; then
		env_source="${envs_dir}/${slug}.env"
		env_status="found"
	elif [ -f "${temp_dir}/repo/.env.example" ]; then
		env_source=".env.example"
		env_status="will edit"
	else
		env_source=""
		env_status="none"
	fi
fi

# Check for seed file
seed_source=""
seed_status=""
if [ "${app_type}" = "node" ] && [ -n "${mongo_container}" ]; then
	if [ -f "${seeds_dir}/${slug}.gz" ]; then
		seed_source="${seeds_dir}/${slug}.gz"
		seed_status="found"
	else
		seed_status="none"
	fi
fi

# SSL status
if [ -z "${domain}" ]; then
	ssl_status="n/a (no domain)"
	do_ssl=false
elif [ "${do_ssl}" = true ]; then
	ssl_status="yes"
else
	ssl_status="skip (use without --no-ssl to obtain)"
fi

# Root path for static sites
root_path="${app_dir}"
[ -n "${root}" ] && root_path="${app_dir}/${root}"

# ==============================================================================
# Display plan
# ==============================================================================

echo ""
echo "Plan:"
echo "  Repo: ${repo_url}"
echo "  Slug: ${slug}"
echo "  Directory: ${app_dir}"
echo "  Type: ${app_type}"

[ -n "${domain}" ] && echo "  Domain: ${domain}"
[ -n "${port}" ] && echo "  Port: ${port}"
[ -n "${root}" ] && echo "  Root: ${root_path}"

if [ "${app_type}" = "node" ]; then
	if [ "${env_status}" = "found" ]; then
		echo "  Env: ${env_source} (${env_status})"
	elif [ "${env_status}" = "will edit" ]; then
		echo "  Env: copy .env.example, open in editor"
	else
		echo "  Env: (none found)"
	fi
fi

if [ -n "${mongo_container}" ]; then
	if [ "${seed_status}" = "found" ]; then
		echo "  Seed: ${seed_source} (${seed_status})"
	else
		echo "  Seed: (none found)"
	fi
fi

[ -n "${domain}" ] && echo "  SSL: ${ssl_status}"
[ -n "${deploy_cmd}" ] && echo "  Deploy: ${deploy_cmd}"

if [ "${app_type}" = "node" ] || [ "${app_type}" = "service" ]; then
	echo "  Start: yes"
fi

echo ""

# ==============================================================================
# Confirm
# ==============================================================================

if [ "${auto_yes}" != true ]; then
	read -p "Proceed? [Y/n]: " confirm
	if [ "${confirm}" = "n" ] || [ "${confirm}" = "N" ]; then
		echo "Aborted."
		exit 0
	fi
fi

# ==============================================================================
# Execute: Move repo into place
# ==============================================================================

echo ""
echo "==> Setting up ${slug}..."

# Move from temp to final location
mv "${temp_dir}/repo" "${app_dir}"
trap - EXIT  # Clear the trap since we moved the repo

cd "${app_dir}"

# ==============================================================================
# Execute: Set up .env
# ==============================================================================

if [ "${app_type}" = "node" ]; then
	if [ "${env_status}" = "found" ]; then
		echo "==> Using env from ${env_source}"
		cp "${env_source}" .env
	elif [ "${env_status}" = "will edit" ]; then
		cp .env.example .env
		echo "==> Opening .env for editing..."
		${EDITOR:-vim} .env
	fi
fi

# ==============================================================================
# Execute: Run deploy command
# ==============================================================================

if [ -n "${deploy_cmd}" ]; then
	echo "==> Running deploy command..."
	eval "${deploy_cmd}"
fi

# ==============================================================================
# Execute: Seed database
# ==============================================================================

if [ "${seed_status}" = "found" ]; then
	echo "==> Seeding database from ${seed_source}..."
	docker compose up -d mongo
	until docker compose exec -T mongo mongosh --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
		echo "    Waiting for mongo..."
		sleep 1
	done
	gunzip -c "${seed_source}" | docker exec -i "${mongo_container}" mongorestore --archive --drop
	echo "    Database seeded."
fi

# ==============================================================================
# Execute: SSL certificate
# ==============================================================================

if [ "${do_ssl}" = true ] && [ -n "${domain}" ]; then
	echo "==> Obtaining SSL certificate for ${domain}..."
	sudo certbot certonly --webroot -w /var/www/letsencrypt -d "${domain}"
fi

# ==============================================================================
# Execute: Generate nginx vhost
# ==============================================================================

if [ -n "${domain}" ]; then
	echo "==> Generating nginx vhost..."

	vhost_file="/etc/nginx/sites-available/${domain}"

	if [ "${app_type}" = "node" ]; then
		# Proxy vhost for node apps
		if [ "${do_ssl}" = true ]; then
			sudo tee "${vhost_file}" > /dev/null <<EOF
server {
	listen 443 ssl;
	server_name ${domain};

	ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
	include /etc/letsencrypt/options-ssl-nginx.conf;
	ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

	access_log /var/log/nginx/${domain}.access.log;
	error_log /var/log/nginx/${domain}.error.log;

	gzip on;

	location / {
		proxy_pass http://localhost:${port};
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection 'upgrade';
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_cache_bypass \$http_upgrade;
	}
}
EOF
		else
			sudo tee "${vhost_file}" > /dev/null <<EOF
server {
	listen 80;
	server_name ${domain};

	access_log /var/log/nginx/${domain}.access.log;
	error_log /var/log/nginx/${domain}.error.log;

	gzip on;

	location / {
		proxy_pass http://localhost:${port};
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection 'upgrade';
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_cache_bypass \$http_upgrade;
	}
}
EOF
		fi
	else
		# Static vhost for static/upload sites
		if [ "${do_ssl}" = true ]; then
			sudo tee "${vhost_file}" > /dev/null <<EOF
server {
	listen 443 ssl;
	server_name ${domain};

	ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
	include /etc/letsencrypt/options-ssl-nginx.conf;
	ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

	root ${root_path};
	index index.html;

	access_log /var/log/nginx/${domain}.access.log;
	error_log /var/log/nginx/${domain}.error.log;

	gzip on;

	location / {
		try_files \$uri \$uri/ =404;
	}
}
EOF
		else
			sudo tee "${vhost_file}" > /dev/null <<EOF
server {
	listen 80;
	server_name ${domain};

	root ${root_path};
	index index.html;

	access_log /var/log/nginx/${domain}.access.log;
	error_log /var/log/nginx/${domain}.error.log;

	gzip on;

	location / {
		try_files \$uri \$uri/ =404;
	}
}
EOF
		fi
	fi

	# Enable the site
	sudo ln -sf "${vhost_file}" /etc/nginx/sites-enabled/
	sudo nginx -t && sudo systemctl reload nginx
	echo "    Nginx configured and reloaded."

	# Set ACLs for static/upload sites so www-data can read content
	if [ "${app_type}" = "static" ] || [ "${app_type}" = "upload" ]; then
		mkdir -p "${root_path}"
		if [ ! -f "${root_path}/index.html" ]; then
			echo "<html><body><h1>${slug} is ready</h1><p>Awaiting content.</p></body></html>" > "${root_path}/index.html"
		fi
		echo "==> Setting ACLs on ${root_path}..."
		sudo setfacl -m u:www-data:x "${app_dir}"
		sudo setfacl -R -m u:www-data:rx "${root_path}"
		sudo setfacl -R -d -m u:www-data:rx "${root_path}"
	fi
fi

# ==============================================================================
# Execute: Create backup directory
# ==============================================================================

if [ -n "${backup_cmd}" ]; then
	mkdir -p "${backups_dir}/${slug}"
	echo "==> Created backup directory: ${backups_dir}/${slug}"
fi

# ==============================================================================
# Execute: Start the app
# ==============================================================================

if [ "${app_type}" = "node" ] || [ "${app_type}" = "service" ]; then
	echo "==> Starting ${slug}..."
	if [ -n "${up_cmd}" ]; then
		eval "${up_cmd}"
	else
		docker compose up -d
	fi
	echo "    Started."
fi

# ==============================================================================
# Done
# ==============================================================================

echo ""
echo "=============================================================================="
echo "Done! ${slug} is set up."
echo "=============================================================================="
if [ -n "${domain}" ]; then
	if [ "${do_ssl}" = true ]; then
		echo "Visit: https://${domain}"
	else
		echo "Visit: http://${domain} (no SSL)"
	fi
fi
