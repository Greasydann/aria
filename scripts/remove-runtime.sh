#!/usr/bin/env bash
set -euo pipefail

purge=0
purge_failed=0
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
# Aria keeps everything it installs inside its own tree. The omarchy-spotify
# locations are the legacy ones this plugin inherited from its fork point and
# are also used by the original Omarchy Spotify plugin, so they are only
# touched when they hold a backend that Aria itself installed (see
# runtime_is_ours below).
config_dir="$config_root/aria"
build_cache_dir="$cache_root/aria"
aria_state_dir="$state_root/aria"
session_runtime_dir="$session_runtime_root/aria"
runtime_dir=${ARIA_RUNTIME_DIR:-${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/aria"}}
legacy_config_dir="$config_root/omarchy-spotify"
legacy_build_cache_dir="$cache_root/omarchy-spotify"
legacy_state_dir="$state_root/omarchy-spotify"
legacy_session_runtime_dir="$session_runtime_root/omarchy-spotify"
legacy_runtime_dir=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}
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
require_safe_path "Aria state" "$aria_state_dir"
require_safe_path "session runtime root" "$session_runtime_root"
require_safe_path "backend runtime" "$runtime_dir"
runtime_dir_is_dedicated=0
if [[ ${runtime_dir##*/} == aria ]]; then
  runtime_dir_is_dedicated=1
fi

plugin_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# True when a directory holds a backend that Aria installed. Recent installs
# record that directly; older ones are recognised by the backend identity
# matching this checkout, or by an attested-release commit that exists in this
# checkout's history (a commit from another repository never does, so a
# backend installed by the original Omarchy Spotify plugin is never claimed).
runtime_is_ours() {
  local dir=$1 origin sha
  [[ -f "$dir/installed-by" ]]     && grep -q '^aria' "$dir/installed-by" 2>/dev/null && return 0
  [[ -x "$dir/omarchy-spotify-backend" ]] \
    && "$plugin_dir/scripts/backend-verify.sh" \
      "$dir/omarchy-spotify-backend" "$plugin_dir" >/dev/null 2>&1 && return 0
  [[ -f "$dir/backend-origin" ]] || return 1
  origin=$(head -n 1 -- "$dir/backend-origin" 2>/dev/null) || origin=""
  sha=${origin#attested-release:}
  [[ -n $sha && $sha != "$origin" && $sha =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ -d "$plugin_dir/.git" ]] || return 1
  git -C "$plugin_dir" cat-file -e "$sha^{commit}" 2>/dev/null
}

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
    rm -rf -- "$config_dir"
    echo "Removed private configuration."
  else
    backup="${config_dir}.bak.$(date -u +%Y%m%d%H%M%S)"
    mv -- "$config_dir" "$backup"
    echo "Moved configuration to: $backup"
  fi
fi

# Everything under the omarchy-spotify names is shared with the original
# Omarchy Spotify plugin. Remove it only when the backend installed there was
# put there by Aria; otherwise this uninstall must leave the other plugin's
# backend, configuration, saved sign-in and backups untouched.
legacy_shared_owned=0
runtime_is_ours "$legacy_runtime_dir" && legacy_shared_owned=1

if [[ -d $legacy_config_dir ]]; then
  if (( ! legacy_shared_owned )); then
    echo "Kept shared Omarchy Spotify configuration (it was not installed by Aria)."
  elif (( purge )); then
    rm -rf -- "$legacy_config_dir"
    echo "Removed legacy spotifyd configuration."
  else
    backup="${legacy_config_dir}.bak.$(date -u +%Y%m%d%H%M%S)"
    mv -- "$legacy_config_dir" "$backup"
    echo "Moved legacy configuration to: $backup"
  fi
fi

if (( purge )); then
  if [[ -d $build_cache_dir ]]; then
    rm -rf -- "$build_cache_dir"
    echo "Removed backend build cache."
  fi
  if [[ -d $session_runtime_dir ]]; then
    rm -rf -- "$session_runtime_dir"
    echo "Removed playback sockets and temporary receiver state."
  fi
  if [[ -d $legacy_build_cache_dir ]]; then
    if (( legacy_shared_owned )); then
      rm -rf -- "$legacy_build_cache_dir"
      echo "Removed legacy backend build cache."
    else
      echo "Kept shared Omarchy Spotify build cache (it was not installed by Aria)."
    fi
  fi
  if [[ -d $legacy_state_dir ]]; then
    if (( legacy_shared_owned )); then
      rm -rf -- "$legacy_state_dir"
      echo "Removed legacy durable playback authorization and session state."
    else
      echo "Kept shared Omarchy Spotify state (it was not installed by Aria)."
    fi
  fi
  # The current generation keeps everything plugin-owned under state/aria:
  # the optional Web API refresh token, session memory and the artwork cache.
  # A complete uninstall removes all of it and reports what it could not.
  if [[ -e $aria_state_dir || -L $aria_state_dir ]]; then
    if rm -rf -- "$aria_state_dir"; then
      echo "Removed plugin tokens and session state."
    else
      echo "remove-runtime.sh: failed to remove plugin state: $aria_state_dir" >&2
      purge_failed=1
    fi
  fi
  if [[ -d $legacy_session_runtime_dir ]]; then
    if (( legacy_shared_owned )); then
      rm -rf -- "$legacy_session_runtime_dir"
      echo "Removed legacy playback sockets and temporary receiver state."
    else
      echo "Kept shared Omarchy Spotify runtime directory (it was not installed by Aria)."
    fi
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
  if [[ -d $legacy_runtime_dir ]]; then
    if (( ! legacy_shared_owned )); then
      echo "Kept shared Omarchy Spotify backend (it was not installed by Aria)."
    elif [[ ${legacy_runtime_dir##*/} == omarchy-spotify ]]; then
      rm -rf -- "$legacy_runtime_dir"
      echo "Removed legacy installed playback backend."
    elif rmdir -- "$legacy_runtime_dir" 2>/dev/null; then
      echo "Removed empty legacy backend directory."
    else
      echo "Kept unknown files in custom backend directory: $legacy_runtime_dir" >&2
    fi
  fi
  for backup in "$config_root"/omarchy-spotify.bak.*; do
    [[ -e $backup ]] || continue
    if (( legacy_shared_owned )); then
      rm -rf -- "$backup"
      echo "Removed old configuration backup: $backup"
    else
      echo "Kept shared Omarchy Spotify backup: $backup"
    fi
  done
  for backup in "$config_root"/aria.bak.*; do
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

if (( purge_failed )); then
  echo "remove-runtime.sh: some plugin files could not be deleted; remove them manually." >&2
  exit 4
fi

echo "Runtime integration removed. The spotifyd package and its own cache were left alone."
