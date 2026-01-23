#!/bin/bash

apps_dir="${HOME}/apps"
logfile="${HOME}/ops/logs/deploy.log"
timestamp=$(date)

notifications=()

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

	# Read deploy_cmd from coinops.json — skip if not present
	deploy_cmd=$(jq -r '.deploy_cmd // empty' "${config}")
	[ -n "${deploy_cmd}" ] || continue

	cd "${app_dir}" || continue

	branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
	branch="${branch:-main}"

	if [ -f "${app_dir}.deploy-lock" ]; then
		commit_hash=$(git rev-parse --short HEAD)
		commit_msg=$(git log -1 --pretty=%s)

		notifications+=("🔒 ${slug}: ${commit_msg}")
		echo "${timestamp}: skipped ${slug} @ ${commit_hash} (locked)" >> "${logfile}"
		continue
	fi

	git fetch origin "${branch}"

	local=$(git rev-parse HEAD)
	remote=$(git rev-parse origin/"${branch}")

	if [ "${local}" != "${remote}" ]; then
		git reset --hard origin/"${branch}"
		eval "${deploy_cmd}"

		commit_hash=$(git rev-parse --short HEAD)
		commit_msg=$(git log -1 --pretty=%s)

		notifications+=("🚀 ${slug}: ${commit_msg}")
		echo "${timestamp}: deployed ${slug} @ ${commit_hash}" >> "${logfile}"
	fi
done

if [ ${#notifications[@]} -gt 0 ]; then
	printf -v ntfy_msg "%s\n\n" "${notifications[@]}"
	curl -s -d "${ntfy_msg}" ntfy.sh/coinflipper > /dev/null
fi
