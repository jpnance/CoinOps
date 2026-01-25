#!/bin/bash
#
# coinops health - Check site availability
#

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
	echo "Usage: coinops health"
	echo ""
	echo "Check availability of configured sites."
	echo "Alerts via ntfy if any site returns non-200 status."
	exit 0
fi

sites=(
	"bbgpbg	props.coinflipper.org"
	"classix	classics.coinflipper.org"
	"coinflipper	coinflipper.org"
	"login	login.coinflipper.org"
	"pickahit	pickahit.coinflipper.org"
	"pso	thedynastyleague.com"
	"pwa	pwa.coinflipper.org"
	"subcontest	subcontest.coinflipper.org"
)

alerts=()

for site in "${sites[@]}"; do
	slug=$(echo "${site}" | cut -f1)
	domain=$(echo "${site}" | cut -f2)

	url="https://${domain}/"
	status_code=$(curl -s -o /dev/null -w "%{http_code}" "${url}")

	if [[ "${status_code}" == "200" ]]; then
		echo "✓ ${slug} (${domain})"
	else
		echo "✗ ${slug} (${domain}) - ${status_code}"
		alerts+=("🚨 ${slug} (${status_code})")
	fi
done

if [ ${#alerts[@]} -gt 0 ]; then
	printf -v ntfy_msg "%s\n" "${alerts[@]}"
	curl -s -d "${ntfy_msg}" ntfy.sh/coinflipper > /dev/null
fi

echo ""
echo "${#sites[@]} sites checked, ${#alerts[@]} issues."
