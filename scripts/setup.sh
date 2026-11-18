#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
install_spotifyd=0
force_config=0
require_native=0
skip_backend_build=${OMARCHY_SPOTIFY_SKIP_BACKEND_BUILD:-0}
device_name="Aria"

usage() {
  cat <<'EOF'
Usage: scripts/setup.sh [--require-native] [--install-spotifyd] [--skip-backend-build] [--force-config] [--device-name NAME]

Verify or build the plugin-owned session backend and write its private
configuration. The spotifyd fallback stays dormant; no unit is installed.
EOF
}

while (( $# > 0 )); do
  case $1 in
    --require-native)
      require_native=1
      shift
      ;;
    --install-spotifyd)
      install_spotifyd=1
      shift
      ;;
    --force-config)
      force_config=1
      shift
      ;;
    --skip-backend-build)
      skip_backend_build=1
      shift
      ;;
    --device-name)
      [[ $# -ge 2 ]] || { echo "setup.sh: --device-name requires a value" >&2; exit 2; }
      device_name=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "setup.sh: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if (( install_spotifyd )) && ! command -v spotifyd >/dev/null 2>&1; then
  command -v pacman >/dev/null 2>&1 || {
    echo "setup.sh: --install-spotifyd is supported only on pacman-based Omarchy systems" >&2
    exit 1
  }
  sudo pacman -S --needed spotifyd
fi

for command_name in secret-tool openssl socat xdg-open systemctl awk cmp install python3 avahi-browse sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "setup.sh: required Omarchy base command is missing: $command_name" >&2
    exit 1
  }
done

"$source_root/scripts/spotify-connect-device.py" self-test >/dev/null || {
  echo "setup.sh: the local Spotify Connect encryption helper failed its self-test" >&2
  exit 1
}

config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
config_dir="$config_root/omarchy-spotify"
config_file="$config_dir/spotifyd.conf"

backend_binary=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}/omarchy-spotify-backend
runtime_dir=$(dirname -- "$backend_binary")
backend_source_id_file="$runtime_dir/backend-source.sha256"
backend_binary_hash_file="$runtime_dir/backend-binary.sha256"
backend_ready=0

backend_install_is_current() {
  local current_source_id expected_source_id expected_binary_hash actual_binary_hash

  [[ -x $backend_binary && -s $backend_source_id_file \
    && -s $backend_binary_hash_file ]] || return 1
  current_source_id=$("$source_root/scripts/backend-source-id.sh") || return 1
  expected_source_id=$(<"$backend_source_id_file")
  [[ $expected_source_id == "$current_source_id" ]] || return 1
  expected_binary_hash=$(<"$backend_binary_hash_file")
  [[ $expected_binary_hash =~ ^[0-9a-f]{64}$ ]] || return 1
  actual_binary_hash=$(sha256sum -- "$backend_binary") || return 1
  [[ ${actual_binary_hash%% *} == "$expected_binary_hash" ]]
}

if backend_install_is_current; then
  backend_ready=1
elif (( ! skip_backend_build )); then
  if "$source_root/scripts/build-backend.sh"; then
    backend_ready=1
  else
    echo "Warning: the plugin-owned backend could not be built; checking spotifyd fallback." >&2
  fi
fi

if (( require_native && ! backend_ready )); then
  echo "setup.sh: the native backend is required for Spotify sign-in. Check the connection and retry setup." >&2
  exit 30
fi

if (( ! backend_ready )) && ! command -v spotifyd >/dev/null 2>&1; then
  echo "setup.sh: neither the plugin backend nor spotifyd is available" >&2
  echo "Install Rust to build the backend, or install spotifyd as a fallback." >&2
  exit 30
fi

install -d -m 700 -- "$config_dir"

# Existing configurations are left byte-identical unless --force-config asks
# for a refresh. Fresh and forced installs generate a private copy of the
# template first (stamping the device name into the copy, never the template),
# then replace the path itself, so a dotfiles symlink is never followed and
# its target is never written through.
if [[ -f $config_file && $force_config -eq 0 ]]; then
  echo "Keeping existing configuration: $config_file"
else
  if [[ -f $config_file ]]; then
    backup="${config_file}.bak.$(date -u +%Y%m%d%H%M%S)"
    cp -p -- "$config_file" "$backup"
    echo "Backed up previous configuration to: $backup"
  fi
  generated=$(mktemp "$config_file.generated.XXXXXX")
  if [[ -n $device_name && ${#device_name} -le 64 ]] \
      && [[ $device_name != *[\"\\]* ]] \
      && [[ ! $device_name =~ [^[:print:]] ]]; then
    awk -v name="$device_name" '
      /^device_name[[:space:]]*=/ { print "device_name = \"" name "\""; next }
      { print }
    ' "$source_root/config/spotifyd.conf" > "$generated"
  else
    echo "setup.sh: keeping the template device name; the configured name is not conf-safe" >&2
    cp -- "$source_root/config/spotifyd.conf" "$generated"
  fi
  rm -f -- "$config_file"
  install -m 600 -- "$generated" "$config_file"
  rm -f -- "$generated"
  echo "Installed private config: $config_file"
fi

if (( backend_ready )); then
  echo "Session backend ready: $backend_binary"
fi
echo "Playback remains stopped and will be started on demand by the plugin."
