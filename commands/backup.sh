#!/bin/bash

apps_dir="${HOME}/apps"
backups_dir="${HOME}/backups"

# Clean and recreate archives directory
rm -rf "${backups_dir}/archives/"
mkdir -p "${backups_dir}/archives"

for app_dir in "${apps_dir}"/*/; do
	[ -d "${app_dir}" ] || continue

	config="${app_dir}coinops.json"
	[ -f "${config}" ] || continue

	# Read slug from coinops.json
	slug=$(jq -r '.slug // empty' "${config}")
	if [ -z "${slug}" ]; then
		echo "Warning: No slug defined in ${config}, skipping"
		continue
	fi

	# Read backup_cmd from coinops.json — skip if not present
	backup_cmd=$(jq -r '.backup_cmd // empty' "${config}")
	[ -n "${backup_cmd}" ] || continue

	echo "Backing up ${slug}..."

	# Ensure backup directory exists
	mkdir -p "${backups_dir}/${slug}"
	cd "${backups_dir}/${slug}" || continue

	# Run the backup command
	eval "${backup_cmd}"

	# Generate metadata if monotonic is defined
	monotonic=$(jq -r '.monotonic // empty' "${config}")
	if [ "${monotonic}" != "null" ] && [ -n "${monotonic}" ]; then
		container=$(jq -r '.mongo_container // empty' "${config}")
		db="${slug}"

		if [ -z "${container}" ]; then
			echo "Warning: ${slug} has monotonic but no mongo_container defined, skipping metadata"
			continue
		fi

		monotonic_json=$(jq -c '.monotonic' "${config}")

		docker exec "${container}" mongosh "${db}" --quiet --eval "
			const meta = {
				db: '${db}',
				timestamp: new Date().toISOString(),
				monotonic: ${monotonic_json},
				collections: db.getCollectionNames().map(collectionName => ({
					name: collectionName,
					count: db.getCollection(collectionName).countDocuments()
				}))
			};
			JSON.stringify(meta, null, 2);
		" > "${slug}.gz.meta"
	fi

	# Copy to archives
	cp "${slug}".gz* "${backups_dir}/archives/" 2>/dev/null

done

echo "Backups complete."
