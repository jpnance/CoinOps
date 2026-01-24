#!/bin/bash

declare -A sites=(
	["login"]="https://login.coinflipper.org/"
	["classix"]="https://classics.coinflipper.org/"
	["subcontest"]="https://subcontest.coinflipper.org/"
	["pickahit"]="https://pickahit.coinflipper.org/"
	["pso"]="https://thedynastyleague.com/"
)

for name in "${!sites[@]}"; do
	url="${sites[$name]}"
	status_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")

	if [[ "$status_code" != "200" ]]; then
		curl -s -d "$name $status_code" ntfy.sh/coinflipper > /dev/null
	fi
done
