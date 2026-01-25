#!/bin/bash
#
# coinops health - Check site availability
#

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
	echo "Usage: coinops health"
	echo ""
	echo "Check availability of all configured sites."
	echo "Alerts via ntfy if any site returns non-200 status."
	exit 0
fi

declare -A sites=(
	["pso"]="https://thedynastyleague.com/"
	["coinflipper"]="https://coinflipper.org/"
	["login"]="https://login.coinflipper.org/"
	["classix"]="https://classics.coinflipper.org/"
	["subcontest"]="https://subcontest.coinflipper.org/"
	["pickahit"]="https://pickahit.coinflipper.org/"
	["pso"]="https://thedynastyleague.com/"
	["bbgpbg"]="https://props.coinflipper.org/"
	["pwa"]="https://pwa.coinflipper.org/"
)

for name in "${!sites[@]}"; do
	url="${sites[$name]}"
	status_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")

	if [[ "$status_code" != "200" ]]; then
		curl -s -d "$name $status_code" ntfy.sh/coinflipper > /dev/null
	fi
done
