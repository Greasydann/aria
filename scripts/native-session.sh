#!/bin/sh
set -eu
umask 077
runtime_dir=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
export RUST_LOG=error

backend="$runtime_dir/omarchy-spotify-backend"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
backend_error=""
detail=""

if [ ! -x "$backend" ]; then
  backend_error="Aria backend is not installed. Run scripts/setup.sh in the plugin folder, then log in again."
  detail="backend binary is missing at $backend"
elif ! detail=$("$script_dir/backend-verify.sh" "$backend" "$source_root" 2>&1 >/dev/null); then
  # The binary exists but its recorded identity no longer matches this plugin
  # source (upgrade in progress, stale build, or a modified binary). Refuse to
  # start it and ask for setup instead; setup rebuilds or re-downloads.
  backend_error="Aria backend needs an update. Run scripts/setup.sh in the plugin folder, then log in again."
  detail="backend verification failed: $detail"
fi

if [ -n "$backend_error" ]; then
  # The player starts this script for login and browsing and always writes its
  # first request (login or status) right away; its id is the response id.
  line=""
  IFS= read -r line || line=""
  id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9][0-9]*\).*/\1/p')
  [ -n "$id" ] || id=1
  printf '{"type":"response","id":%s,"status":0,"data":null,"error":"%s"}\n' "$id" "$backend_error"
  echo "native-session.sh: $detail; run scripts/setup.sh" >&2
  exit 7
fi
exec "$backend" session --config-path "$config_root/omarchy-spotify/spotifyd.conf"
