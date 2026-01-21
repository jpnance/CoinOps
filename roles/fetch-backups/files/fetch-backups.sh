#!/bin/bash

set -e

backup_dir="/home/jpnance/backups"
monthly_dir="${backup_dir}/monthly"
date=$(date +"%Y-%m-%d")
time=$(date +"%H:%M")
hour=$(date +"%H")
year_month=$(date +"%Y-%m")

cd "${backup_dir}"
mkdir -p "${date}/${time}"
cd "${date}/${time}"
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null jpnance@coinflipper.org:backups/archives/* .

alerts=()
dbs=()

for file in *.gz; do
	db="${file%.gz}"
	dbs+=("${db}")

	# Zero-byte file check
	if [ ! -s "${file}" ]; then
		alerts+=("🚨 ${db}: empty file")
		continue
	fi

	meta="${file}.meta"
	if [ ! -f "${meta}" ]; then
		continue
	fi

	monotonic=$(jq -r '.monotonic[]' "${meta}")

	for coll in ${monotonic}; do
		current=$(jq -r ".collections[] | select(.name==\"${coll}\") | .count" "${meta}")

		# Missing collection check
		if [ -z "${current}" ]; then
			alerts+=("⛔ ${db}.${coll}: missing")
			continue
		fi

		# Zero-document check
		if [ "${current}" -eq 0 ] 2>/dev/null; then
			alerts+=("⛔ ${db}.${coll}: 0 docs")
			continue
		fi

		# Shrinkage check
		latest_meta="${backup_dir}/latest/${meta}"
		if [ -f "${latest_meta}" ]; then
			previous=$(jq -r ".collections[] | select(.name==\"${coll}\") | .count" "${latest_meta}")

			if [ -n "${previous}" ] && [ "${current}" -lt "${previous}" ]; then
				diff=$(( previous - current ))
				alerts+=("📉 ${db}.${coll}: -${diff} (${previous} → ${current})")
			fi
		fi
	done
done

cd "${backup_dir}"
ln -fsnT "${date}/${time}" latest

# Monthly golden snapshot
mkdir -p "${monthly_dir}"
if [ ! -d "${monthly_dir}/${year_month}" ]; then
	alerts+=("📦 monthly: ${year_month}")
	cp -al "${date}/${time}" "${monthly_dir}/${year_month}"
fi

# Cleanup old daily directories
cutoff_date=$(date -d "1 month ago" +"%Y-%m-%d")
for dir in "${backup_dir}"/20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
	dir_name=$(basename "${dir}")
	if [[ "${dir_name}" < "${cutoff_date}" ]]; then
		rm -rf "${dir}"
	fi
done

# Send alerts if any
if [ ${#alerts[@]} -gt 0 ]; then
	printf -v ntfy_msg "%s\n\n" "${alerts[@]}"
	curl -s -d "${ntfy_msg}" ntfy.sh/coinflipper > /dev/null
fi

# Success notification twice daily (6am and 6pm)
if [ ${#alerts[@]} -eq 0 ] && { [ "$hour" = "06" ] || [ "$hour" = "18" ]; }; then
	printf -v ntfy_msg "✅ %s\n" "${dbs[@]}"
	curl -s -d "${ntfy_msg}" ntfy.sh/coinflipper > /dev/null
fi
