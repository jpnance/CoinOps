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
	while true; do
		read -p "GitHub repo name [${slug}]: " repo_name
		repo_name="${repo_name:-${slug}}"
		repo="https://github.com/jpnance/${repo_name}"

		echo "Cloning ${repo}..."
		if git clone "${repo}" "${app_dir}"; then
			break
		else
			echo "Couldn't clone ${repo}. Try again?"
		fi
	done
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

# For node apps, set up .env
envs_dir="${HOME}/envs"
if [ "${app_type}" = "node" ] && [ ! -f ".env" ]; then
	if [ -f "${envs_dir}/${slug}.env" ]; then
		echo ""
		echo "Using .env from ${envs_dir}/${slug}.env"
		cp "${envs_dir}/${slug}.env" .env
	elif [ -f ".env.example" ]; then
		cp .env.example .env
		echo ""
		echo "Opening .env for editing..."
		${EDITOR:-vim} .env
	else
		echo ""
		echo "Warning: No .env file found. Create one if needed."
		read -p "Press enter to continue..."
	fi
fi

# Run deploy command to build the app
deploy_cmd=$(jq -r '.deploy_cmd // empty' "${config}")
if [ -n "${deploy_cmd}" ]; then
	echo ""
	echo "Running deploy command..."
	eval "${deploy_cmd}"
fi

# Seed database for node apps
seeds_dir="${HOME}/seeds"
if [ "${app_type}" = "node" ] && [ -d "${seeds_dir}" ]; then
	seed_files=("${seeds_dir}"/*.gz)
	if [ -f "${seed_files[0]}" ]; then
		mongo_container=$(jq -r '.mongo_container // empty' "${config}")
		if [ -n "${mongo_container}" ]; then
			echo ""
			echo "Select a seed file (or skip):"
			saved_columns="${COLUMNS}"
			COLUMNS=1
			select seed_path in "${seed_files[@]}" "Skip"; do
				if [ "${seed_path}" = "Skip" ] || [ -z "${seed_path}" ]; then
					echo "Skipping database seed."
					break
				fi
				if [ -f "${seed_path}" ]; then
					echo "Starting mongo container..."
					docker compose up -d mongo
					until docker compose exec -T mongo mongosh --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
						echo "Waiting for mongo..."
						sleep 1
					done
					echo "Restoring from ${seed_path}..."
					gunzip -c "${seed_path}" | docker exec -i "${mongo_container}" mongorestore --archive --drop
					echo "Database seeded."
				fi
				break
			done
			COLUMNS="${saved_columns}"
		fi
	fi
fi

# Get SSL certificate
if [ -n "${domain}" ]; then
	echo ""
	read -p "Obtain SSL certificate for ${domain}? (y/n): " do_cert
	if [ "${do_cert}" = "y" ]; then
		sudo certbot certonly --webroot -w /var/www/letsencrypt -d "${domain}"
	fi
fi

# Generate nginx vhost
if [ -n "${domain}" ]; then
	echo ""
	echo "Generating nginx vhost..."

	vhost_file="/etc/nginx/sites-available/${domain}"

	if [ "${app_type}" = "node" ]; then
		# Proxy vhost for node apps
		if [ "${do_cert}" = "y" ]; then
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
		root_path="${app_dir}"
		[ -n "${root}" ] && root_path="${app_dir}/${root}"

		if [ "${do_cert}" = "y" ]; then
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
	echo "Nginx configured and reloaded."

	# Set ACLs for static/upload sites so www-data can read content
	if [ "${app_type}" = "static" ] || [ "${app_type}" = "upload" ]; then
		root_path="${app_dir}"
		[ -n "${root}" ] && root_path="${app_dir}/${root}"

		mkdir -p "${root_path}"
		if [ ! -f "${root_path}/index.html" ]; then
			echo "<html><body><h1>${slug} is ready</h1><p>Awaiting content.</p></body></html>" > "${root_path}/index.html"
		fi
		echo "Setting ACLs on ${root_path}..."
		# Allow www-data to traverse into app directory
		sudo setfacl -m u:www-data:x "${app_dir}"
		# Allow www-data to read content
		sudo setfacl -R -m u:www-data:rx "${root_path}"
		sudo setfacl -R -d -m u:www-data:rx "${root_path}"
	fi
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
if [ -n "${domain}" ]; then
	if [ "${do_cert}" = "y" ]; then
		echo "Visit: https://${domain}"
	else
		echo "Visit: http://${domain} (no SSL configured)"
	fi
fi
