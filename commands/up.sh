#!/bin/bash
#
# coinops up - Bring up app containers
#

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
	echo "Usage: coinops up"
	echo ""
	echo "Bring up all apps that have an up_cmd defined in coinops.json."
	exit 0
fi

apps_dir="${HOME}/apps"

for app_dir in "${apps_dir}"/*/; do
	[ -d "${app_dir}" ] || continue

	config="${app_dir}coinops.json"
	[ -f "${config}" ] || continue

	# Read slug from coinops.json
	slug=$(jq -r '.slug // empty' "${config}")
	[ -n "${slug}" ] || continue

	# Read up_cmd from coinops.json — skip if not present
	up_cmd=$(jq -r '.up_cmd // empty' "${config}")
	[ -n "${up_cmd}" ] || continue

	echo "Bringing up ${slug}..."
	cd "${app_dir}" || continue
	eval "${up_cmd}"
done

echo "Done."
