#!/usr/bin/env bash
set -euo pipefail

if (( $# > 2 )); then
  echo "Usage: scripts/uninstall.sh [--include-shared]" >&2
  exit 2
fi
include_shared=0
for arg in "$@"; do
  case "$arg" in
  --include-shared) include_shared=1 ;;
  *)
    echo "Usage: scripts/uninstall.sh [--include-shared]" >&2
    exit 2
    ;;
  esac
done

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugins_dir="$HOME/.config/omarchy/plugins"
plugin_dir="$plugins_dir/aria"

[[ $HOME == /* && $HOME != / ]] || {
  echo "uninstall.sh: refusing an unsafe home path" >&2
  exit 3
}
command -v omarchy >/dev/null 2>&1 || {
  echo "uninstall.sh: Omarchy is not installed" >&2
  exit 1
}

# Disable first so the shell drops its widget and service before the runtime
# files and plugin checkout disappear. This is intentionally safe to repeat.
omarchy plugin disable aria >/dev/null 2>&1 || true
purge_args=(--purge)
if (( include_shared )); then
  purge_args+=(--include-shared)
fi
"$source_root/scripts/remove-runtime.sh" "${purge_args[@]}"

if [[ -e $plugin_dir || -L $plugin_dir ]]; then
  omarchy plugin remove aria --yes
fi

# Omarchy backs up unmanaged plugin folders instead of deleting them. A full
# uninstall explicitly removes only backups bearing this plugin's exact ID.
for backup in "$plugins_dir"/.aria.bak.*; do
  [[ -e $backup ]] || continue
  rm -rf -- "$backup"
done

omarchy restart shell

hypr_config="$HOME/.config/hypr"
if command -v rg >/dev/null 2>&1 && [[ -d $hypr_config ]] \
    && rg -q 'quickshell\.spotify|Aria' "$hypr_config"; then
  echo >&2
  echo "Legacy Aria references remain in Hyprland config:" >&2
  rg -n 'quickshell\.spotify|Aria' "$hypr_config" >&2 || true
  echo "Remove those custom lines (and their dotfiles source), then run hyprctl reload." >&2
fi

echo "Aria's plugin data, tokens and runtime have been completely uninstalled."
echo "External source checkouts, other plugins, the spotifyd package, and its"
echo "own cache were left alone. Shared Omarchy Spotify files Aria did not"
echo "install were left alone too (pass --include-shared to remove them as"
echo "well; the uninstaller also asks when run from a terminal)."
