#!/bin/bash

set -e

apps_dir="${HOME}/apps"
backups_dir="${HOME}/backups"

# Get app slug
slug="${1}"
if [ -z "${slug}" ]; then
	read -p "App slug: " slug
fi

app_dir="${apps_dir}/${slug}"

# Clone if directory doesn't exist
if [ ! -d "${app_dir}" ]; then
	read -p "Git repo [https://github.com/jpnance/${slug}]: " repo
	repo="${repo:-https://github.com/jpnance/${slug}}"

	echo "Cloning ${repo}..."
	git clone "${repo}" "${app_dir}"
fi

cd "${app_dir}"

# Check for coinops.json
config="${app_dir}/coinops.json"
if [ ! -f "${config}" ]; then
	echo "Error: No coinops.json found in ${app_dir}"
	echo "Create one and re-run if you want to use add-app.sh."
	exit 1
fi

# Read config
domain=$(jq -r '.domain // empty' "${config}")
port=$(jq -r '.port // empty' "${config}")
app_type=$(jq -r '.type // empty' "${config}")
root=$(jq -r '.root // empty' "${config}")

echo "Setting up ${slug}..."
echo "  Domain: ${domain}"
echo "  Type: ${app_type}"
[ -n "${port}" ] && echo "  Port: ${port}"
[ -n "${root}" ] && echo "  Root: ${root}"

# For node apps, prompt to configure .env
if [ "${app_type}" = "node" ]; then
	if [ -f ".env.example" ] && [ ! -f ".env" ]; then
		cp .env.example .env
		echo ""
		echo "Opening .env for editing..."
		${EDITOR:-vim} .env
	elif [ ! -f ".env" ]; then
		echo ""
		echo "Warning: No .env file found. Create one if needed."
		read -p "Press enter to continue..."
	fi
fi

# Get SSL certificate
if [ -n "${domain}" ]; then
	echo ""
	read -p "Obtain SSL certificate for ${domain}? (y/n): " do_cert
	if [ "${do_cert}" = "y" ]; then
		sudo certbot certonly --standalone -d "${domain}"
	fi
fi

# Generate nginx vhost
if [ -n "${domain}" ]; then
	echo ""
	echo "Generating nginx vhost..."

	vhost_file="/etc/nginx/sites-available/${domain}"

	if [ "${app_type}" = "node" ]; then
		# Proxy vhost for node apps
		sudo tee "${vhost_file}" > /dev/null <<EOF
server {
	listen 80;
	server_name ${domain};
	return 301 https://\$server_name\$request_uri;
}

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
		# Static vhost for static/upload sites
		root_path="${app_dir}"
		[ -n "${root}" ] && root_path="${app_dir}/${root}"

		sudo tee "${vhost_file}" > /dev/null <<EOF
server {
	listen 80;
	server_name ${domain};
	return 301 https://\$server_name\$request_uri;
}

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
	fi

	# Enable the site
	sudo ln -sf "${vhost_file}" /etc/nginx/sites-enabled/
	sudo nginx -t && sudo systemctl reload nginx
	echo "Nginx configured and reloaded."
fi

# Create backup directory if backup_cmd is defined
backup_cmd=$(jq -r '.backup_cmd // empty' "${config}")
if [ -n "${backup_cmd}" ]; then
	mkdir -p "${backups_dir}/${slug}"
	echo "Created backup directory: ${backups_dir}/${slug}"
fi

# Start containers for node apps
if [ "${app_type}" = "node" ]; then
	echo ""
	read -p "Start containers now? (y/n): " do_start
	if [ "${do_start}" = "y" ]; then
		docker compose up -d
		echo "Containers started."
	fi
fi

echo ""
echo "Done! ${slug} is set up."
[ -n "${domain}" ] && echo "Visit: https://${domain}"
