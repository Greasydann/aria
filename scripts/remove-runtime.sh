#!/usr/bin/env bash
set -euo pipefail

purge=0
if [[ ${1:-} == "--purge" ]]; then
  purge=1
  shift
fi
if (( $# > 0 )); then
  echo "Usage: scripts/remove-runtime.sh [--purge]" >&2
  exit 2
fi

config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
cache_root=${XDG_CACHE_HOME:-"$HOME/.cache"}
state_root=${XDG_STATE_HOME:-"$HOME/.local/state"}
session_runtime_root=${XDG_RUNTIME_DIR:-/tmp}
backend_unit_file="$config_root/systemd/user/omarchy-spotify.service"
fallback_unit_file="$config_root/systemd/user/omarchy-spotifyd.service"
config_dir="$config_root/omarchy-spotify"
build_cache_dir="$cache_root/omarchy-spotify"
state_dir="$state_root/omarchy-spotify"
session_runtime_dir="$session_runtime_root/omarchy-spotify"
runtime_dir=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}
backend_binary="$runtime_dir/omarchy-spotify-backend"
backend_source_id_file="$runtime_dir/backend-source.sha256"
backend_binary_hash_file="$runtime_dir/backend-binary.sha256"
backend_origin_file="$runtime_dir/backend-origin"

require_safe_path() {
  local label=$1 value=$2

  [[ $value == /* && $value != / ]] || {
    echo "remove-runtime.sh: refusing unsafe $label path: $value" >&2
    exit 3
  }
}

require_safe_path "configuration root" "$config_root"
require_safe_path "cache root" "$cache_root"
require_safe_path "state root" "$state_root"
require_safe_path "session runtime root" "$session_runtime_root"
require_safe_path "backend runtime" "$runtime_dir"
runtime_dir_is_dedicated=0
if [[ ${runtime_dir##*/} == omarchy-spotify ]]; then
  runtime_dir_is_dedicated=1
fi

# Legacy units from the embedded-engine generations of this plugin. Current
# installs run the session backend on demand and never install a unit. Touch
# a unit file only when it still byte-matches the last copy this plugin
# shipped; a modified or foreign unit is left alone.
removed_a_unit=0
remove_legacy_unit() {
  local unit_name=$1 expected_hash=$2 unit_path=$3
  [[ -f $unit_path ]] || return 0
  local actual_hash
  actual_hash=$(sha256sum -- "$unit_path") || actual_hash=""
  actual_hash=${actual_hash%% *}
  if [[ $actual_hash == "$expected_hash" ]]; then
    systemctl --user disable --now "$unit_name" >/dev/null 2>&1 || true
    rm -f -- "$unit_path"
    removed_a_unit=1
  else
    echo "remove-runtime.sh: kept modified unit file: $unit_path" >&2
  fi
}
remove_legacy_unit omarchy-spotify.service \
  b2d1f3f36ffc518cd1735f7b1b0f4281d092f0157b2b4bffdc78d720dbe70c27 \
  "$backend_unit_file"
remove_legacy_unit omarchy-spotifyd.service \
  2640dc442c5fea7c7765a02154db297b58751c8daefe8021a8b8a9f85eb6a8c8 \
  "$fallback_unit_file"
rm -f -- "$backend_binary" \
  "$backend_source_id_file" "$backend_binary_hash_file" "$backend_origin_file"
if (( removed_a_unit )); then
  systemctl --user daemon-reload
  systemctl --user reset-failed omarchy-spotify.service omarchy-spotifyd.service \
    >/dev/null 2>&1 || true
fi

if [[ -d $config_dir ]]; then
  if (( purge )); then
    [[ $config_dir == "$config_root/omarchy-spotify" ]] || exit 3
    rm -rf -- "$config_dir"
    echo "Removed spotifyd configuration."
  else
    backup="${config_dir}.bak.$(date -u +%Y%m%d%H%M%S)"
    mv -- "$config_dir" "$backup"
    echo "Moved configuration to: $backup"
  fi
fi

if (( purge )); then
  if [[ -d $build_cache_dir ]]; then
    [[ $build_cache_dir == "$cache_root/omarchy-spotify" ]] || exit 3
    rm -rf -- "$build_cache_dir"
    echo "Removed backend build cache."
  fi
  if [[ -d $state_dir ]]; then
    [[ $state_dir == "$state_root/omarchy-spotify" ]] || exit 3
    rm -rf -- "$state_dir"
    echo "Removed durable playback authorization and session state."
  fi
  if [[ -d $session_runtime_dir ]]; then
    [[ $session_runtime_dir == "$session_runtime_root/omarchy-spotify" ]] || exit 3
    rm -rf -- "$session_runtime_dir"
    echo "Removed playback sockets and temporary receiver state."
  fi
  if [[ -d $runtime_dir ]]; then
    if (( runtime_dir_is_dedicated )); then
      rm -rf -- "$runtime_dir"
      echo "Removed installed playback backend."
    elif rmdir -- "$runtime_dir" 2>/dev/null; then
      echo "Removed empty custom backend directory."
    else
      echo "Kept unknown files in custom backend directory: $runtime_dir" >&2
    fi
  fi
  for backup in "$config_root"/omarchy-spotify.bak.*; do
    [[ -e $backup ]] || continue
    rm -rf -- "$backup"
    echo "Removed old configuration backup: $backup"
  done
  if command -v secret-tool >/dev/null 2>&1; then
    for _ in {1..100}; do
      secret-tool clear service aria kind refresh-token >/dev/null 2>&1 || break
    done
    echo "Cleared matching Aria keyring entries."
  fi
else
  rmdir -- "$runtime_dir" 2>/dev/null || true
fi

echo "Runtime integration removed. The spotifyd package and its own cache were left alone."
