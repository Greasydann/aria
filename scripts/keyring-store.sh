#!/bin/sh
set -eu
client_id=${1:-}
[ -n "$client_id" ] || exit 2
IFS= read -r refresh_token
[ -n "$refresh_token" ] || exit 3
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/spoty"
id=$(printf '%s' "$client_id" | tr -cd '0-9A-Fa-f')
[ -n "$id" ] || id=default
umask 077
mkdir -p "$state_dir"
printf '%s' "$refresh_token" > "$state_dir/refresh-token-$id"
