#!/bin/sh
set -eu
umask 077
runtime_dir=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
export RUST_LOG=error

backend="$runtime_dir/omarchy-spotify-backend"
if [ ! -x "$backend" ]; then
  # The player starts this script for login and browsing. Without the backend
  # binary it used to exit silently and the UI only offered a pointless retry,
  # so answer the first request with a structured error naming the fix. The
  # player always writes its first request (login or status) right away; its
  # id is the response id.
  line=""
  IFS= read -r line || line=""
  id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9][0-9]*\).*/\1/p')
  [ -n "$id" ] || id=1
  printf '{"type":"response","id":%s,"status":0,"data":null,"error":"Aria backend is not installed. Run scripts/setup.sh in the plugin folder, then log in again."}\n' "$id"
  echo "native-session.sh: backend binary is missing at $backend; run scripts/setup.sh" >&2
  exit 7
fi
exec "$backend" session --config-path "$config_root/omarchy-spotify/spotifyd.conf"
