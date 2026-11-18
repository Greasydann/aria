#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# Release executables are published separately with exact-commit build
# provenance. The reviewed source snapshot must not contain an opaque ELF.
[[ ! -e $source_root/backend/dist/$(uname -m)/omarchy-spotify-backend ]]
[[ -f $source_root/.github/workflows/release-backend.yml ]]
backend_source_id=$($source_root/scripts/backend-source-id.sh)
[[ $backend_source_id =~ ^[0-9a-f]{64}$ ]]

# A release built from the manifest's version tag remains valid when main has
# moved ahead with UI-only commits. The attestation must stay bound to the
# tagged commit, while any committed backend change must force a source build.
release_source="$test_root/release-source"
release_runtime="$test_root/release-runtime"
release_target="$test_root/release-target"
release_mock_bin="$test_root/release-mock-bin"
release_fixture="$test_root/release-fixture"
release_gh_log="$test_root/release-gh.log"
release_cargo_log="$test_root/release-cargo.log"
mkdir -p "$release_source/scripts" "$release_mock_bin" "$release_fixture"
while IFS= read -r backend_file; do
  mkdir -p "$release_source/$(dirname -- "$backend_file")"
  cp -- "$source_root/$backend_file" "$release_source/$backend_file"
done < <(cd "$source_root" && rg --files backend)
cp -- "$source_root/scripts/build-backend.sh" \
  "$source_root/scripts/backend-source-id.sh" "$release_source/scripts/"
cp -- "$source_root/manifest.json" "$source_root/rust-toolchain.toml" \
  "$release_source/"
git -C "$release_source" init -q
git -C "$release_source" config user.name "Omarchy Spotify tests"
git -C "$release_source" config user.email "tests@example.invalid"
git -C "$release_source" add .
git -C "$release_source" commit -qm "Release source"
release_version=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$source_root/manifest.json")
[[ $release_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
git -C "$release_source" tag -a "v$release_version" -m "Release v$release_version"
release_commit=$(git -C "$release_source" rev-parse "refs/tags/v$release_version^{commit}")
printf '%s\n' 'UI-only change after the release' >"$release_source/Panel.qml"
git -C "$release_source" add Panel.qml
git -C "$release_source" commit -qm "Change only the UI"
[[ $(git -C "$release_source" rev-parse HEAD) != "$release_commit" ]]

release_asset_name="omarchy-spotify-backend-$(uname -m)"
release_asset="$release_fixture/$release_asset_name"
release_sums="$release_fixture/SHA256SUMS"
printf '%s\n' 'mock attested release' >"$release_asset"
release_hash=$(sha256sum -- "$release_asset")
printf '%s  %s\n' "${release_hash%% *}" "$release_asset_name" >"$release_sums"

printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'output=' \
  'while [ "$#" -gt 0 ]; do' \
  '  case $1 in' \
  '    -o) output=$2; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'case $output in' \
  '  */SHA256SUMS) cp -- "${TEST_RELEASE_SUMS:?}" "$output" ;;' \
  '  *) cp -- "${TEST_RELEASE_ASSET:?}" "$output" ;;' \
  'esac' >"$release_mock_bin/curl"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'printf "%s\n" "$*" >>"${TEST_GH_LOG:?}"' \
  'digest=' \
  'while [ "$#" -gt 0 ]; do' \
  '  case $1 in' \
  '    --source-digest) digest=$2; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  '[ "$digest" = "${TEST_EXPECTED_DIGEST:?}" ]' >"$release_mock_bin/gh"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'printf "%s\n" "$*" >>"${TEST_CARGO_LOG:?}"' \
  'mkdir -p "${CARGO_TARGET_DIR:?}/release"' \
  'printf "%s\n" "mock changed-source build" >"$CARGO_TARGET_DIR/release/omarchy-spotify-backend"' \
  'chmod 755 "$CARGO_TARGET_DIR/release/omarchy-spotify-backend"' \
  'exit 0' >"$release_mock_bin/cargo"
chmod 755 "$release_mock_bin/curl" "$release_mock_bin/gh" \
  "$release_mock_bin/cargo"
: >"$release_gh_log"
: >"$release_cargo_log"

PATH="$release_mock_bin:$PATH" \
TEST_RELEASE_ASSET="$release_asset" \
TEST_RELEASE_SUMS="$release_sums" \
TEST_EXPECTED_DIGEST="$release_commit" \
TEST_GH_LOG="$release_gh_log" \
TEST_CARGO_LOG="$release_cargo_log" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$release_runtime" \
CARGO_TARGET_DIR="$release_target" \
  "$release_source/scripts/build-backend.sh" >/dev/null
cmp -s -- "$release_asset" "$release_runtime/omarchy-spotify-backend"
[[ $(<"$release_runtime/backend-origin") == "attested-release:$release_commit" ]]
grep -q -- "--source-digest $release_commit" "$release_gh_log"
[[ ! -s $release_cargo_log ]]

# Rejected artifacts are never installed, and explain why source fallback ran.
for rejection in checksum attestation; do
  expected_digest="$release_commit"
  if [[ $rejection == checksum ]]; then
    printf '%064d  %s\n' 0 "$release_asset_name" > "$release_sums"
  else
    expected_digest=invalid
  fi
  PATH="$release_mock_bin:$PATH" \
  TEST_RELEASE_ASSET="$release_asset" TEST_RELEASE_SUMS="$release_sums" \
  TEST_EXPECTED_DIGEST="$expected_digest" TEST_GH_LOG="$release_gh_log" \
  TEST_CARGO_LOG="$release_cargo_log" OMARCHY_SPOTIFY_RUNTIME_DIR="$release_runtime" \
  CARGO_TARGET_DIR="$release_target" \
    "$release_source/scripts/build-backend.sh" > "$test_root/rejected-output" 2>&1
  grep -q 'Downloaded release was not verified' "$test_root/rejected-output"
  grep -q 'mock changed-source build' "$release_runtime/omarchy-spotify-backend"
  [[ $(<"$release_runtime/backend-origin") == source-build:* ]]
  printf '%s  %s\n' "${release_hash%% *}" "$release_asset_name" > "$release_sums"
done

printf '%s\n' '// committed backend change' >>"$release_source/backend/src/spotify/transport.rs"
git -C "$release_source" add backend/src/spotify/transport.rs
git -C "$release_source" commit -qm "Change backend after release"
: >"$release_gh_log"
: >"$release_cargo_log"
PATH="$release_mock_bin:$PATH" \
TEST_RELEASE_ASSET="$release_asset" \
TEST_RELEASE_SUMS="$release_sums" \
TEST_EXPECTED_DIGEST="$release_commit" \
TEST_GH_LOG="$release_gh_log" \
TEST_CARGO_LOG="$release_cargo_log" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$release_runtime" \
CARGO_TARGET_DIR="$release_target" \
  "$release_source/scripts/build-backend.sh" >/dev/null
[[ ! -s $release_gh_log ]]
grep -q -- '--locked --release' "$release_cargo_log"
grep -q '^source-build:' "$release_runtime/backend-origin"

pkce_output=$("$source_root/scripts/pkce.sh")
IFS=$'\t' read -r verifier challenge state <<<"$pkce_output"

[[ $verifier =~ ^[A-Za-z0-9._~-]{43,128}$ ]]
[[ $challenge =~ ^[A-Za-z0-9_-]{43,128}$ ]]
[[ $state =~ ^[A-Fa-f0-9]{32,128}$ ]]

expected_challenge=$(printf '%s' "$verifier" |
  openssl dgst -sha256 -binary |
  openssl base64 -A |
  tr '+/' '-_' |
  tr -d '=')
[[ $challenge == "$expected_challenge" ]]


# The local Spotify Connect encryption helper must pass its own self-test.
[[ -x $source_root/scripts/spotify-connect-device.py ]]
"$source_root/scripts/spotify-connect-device.py" self-test |
  jq -e '.status == "ok"' >/dev/null

# Exercise setup, removal and uninstall entirely inside the temporary tree.
# The mock binaries prevent package, service, keyring, or user-config changes
# while still covering the scripts' real file permissions and paths.
mock_bin="$test_root/mock-bin"
runtime_config="$test_root/runtime-config"
runtime_cache="$test_root/runtime-cache"
runtime_state="$test_root/runtime-state"
runtime_session="$test_root/runtime-session"
runtime_backend="$test_root/runtime-lib/omarchy-spotify"
runtime_home="$test_root/runtime-home"
mock_target="$test_root/mock-target"
secret_log="$test_root/secret-tool.log"
systemctl_log="$test_root/systemctl.log"
omarchy_log="$test_root/omarchy.log"
mkdir -p "$mock_bin" "$runtime_config" "$runtime_cache" "$runtime_state" \
  "$runtime_session" "$runtime_backend" "$runtime_home"

printf '%s\n' '#!/bin/sh' 'exit 0' >"$mock_bin/spotifyd"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'mkdir -p "${CARGO_TARGET_DIR:?}/release"' \
  'printf "%s\n" "mock source-built backend" >"$CARGO_TARGET_DIR/release/omarchy-spotify-backend"' \
  'chmod 755 "$CARGO_TARGET_DIR/release/omarchy-spotify-backend"' \
  'exit 0' >"$mock_bin/cargo"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ -n "${TEST_SYSTEMCTL_LOG:-}" ]; then printf "%s\n" "$*" >>"$TEST_SYSTEMCTL_LOG"; fi' \
  'exit 0' >"$mock_bin/systemctl"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"${TEST_SECRET_LOG:?}"' \
  'exit 1' >"$mock_bin/secret-tool"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"${TEST_OMARCHY_LOG:?}"' \
  'if [ "$*" = "plugin remove aria --yes" ]; then' \
  '  rm -f -- "$HOME/.config/omarchy/plugins/aria"' \
  'fi' \
  'exit 0' >"$mock_bin/omarchy"
for mock_helper in socat xdg-open avahi-browse; do
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$mock_bin/$mock_helper"
done
chmod 755 "$mock_bin/cargo" "$mock_bin/spotifyd" "$mock_bin/systemctl" \
  "$mock_bin/secret-tool" "$mock_bin/omarchy" "$mock_bin/socat" \
  "$mock_bin/xdg-open" "$mock_bin/avahi-browse"

sandbox_env=(
  "PATH=$mock_bin:$PATH"
  "HOME=$runtime_home"
  "XDG_CONFIG_HOME=$runtime_config"
  "XDG_CACHE_HOME=$runtime_cache"
  "XDG_STATE_HOME=$runtime_state"
  "XDG_RUNTIME_DIR=$runtime_session"
  "OMARCHY_SPOTIFY_RUNTIME_DIR=$runtime_backend"
)

# A fresh setup stamps the device name into a private copy of the template
# (600 perms) and installs no systemd units: playback starts on demand.
env "${sandbox_env[@]}" \
  "OMARCHY_SPOTIFY_SKIP_BACKEND_BUILD=1" \
  "$source_root/scripts/setup.sh" --device-name "Test speakers" \
  >"$test_root/setup-fresh.log"
runtime_config_dir="$runtime_config/omarchy-spotify"
runtime_spotify_config="$runtime_config_dir/spotifyd.conf"
[[ -f $runtime_spotify_config ]]
[[ $(stat -c '%a' "$runtime_spotify_config") == 600 ]]
[[ $(stat -c '%a' "$runtime_config_dir") == 700 ]]
grep -qx 'device_name = "Test speakers"' "$runtime_spotify_config"
grep -qx 'bitrate = 320' "$runtime_spotify_config"
grep -qx 'no_audio_cache = false' "$runtime_spotify_config"
grep -qx 'max_cache_size = 1000000000' "$runtime_spotify_config"
grep -q 'Installed private config' "$test_root/setup-fresh.log"
[[ ! -e $runtime_config/systemd ]]

# An existing configuration is kept byte-identical unless --force-config asks
# for a refresh.
config_before_hash=$(sha256sum -- "$runtime_spotify_config")
config_before_mtime=$(stat -c '%Y' "$runtime_spotify_config")
env "${sandbox_env[@]}" \
  "OMARCHY_SPOTIFY_SKIP_BACKEND_BUILD=1" \
  "$source_root/scripts/setup.sh" >"$test_root/setup-keep.log"
grep -q 'Keeping existing configuration' "$test_root/setup-keep.log"
! grep -q 'Installed private config' "$test_root/setup-keep.log"
[[ $(sha256sum -- "$runtime_spotify_config") == "$config_before_hash" ]]
[[ $(stat -c '%Y' "$runtime_spotify_config") == "$config_before_mtime" ]]

env "${sandbox_env[@]}" \
  "OMARCHY_SPOTIFY_SKIP_BACKEND_BUILD=1" \
  "$source_root/scripts/setup.sh" --force-config \
  --device-name "Fresh speakers" >"$test_root/setup-forced.log"
grep -q 'Backed up previous configuration' "$test_root/setup-forced.log"
grep -qx 'device_name = "Fresh speakers"' "$runtime_spotify_config"
find "$runtime_config_dir" -maxdepth 1 -name 'spotifyd.conf.bak.*' | grep -q .

# A clean source install records the reviewed backend-source fingerprint, the
# installed executable hash and the build origin.
rm -f -- "$runtime_backend/omarchy-spotify-backend" \
  "$runtime_backend/backend-source.sha256" \
  "$runtime_backend/backend-binary.sha256" \
  "$runtime_backend/backend-origin"
env "${sandbox_env[@]}" \
  "CARGO_TARGET_DIR=$mock_target" \
  "OMARCHY_SPOTIFY_BUILD_FROM_SOURCE=1" \
  "$source_root/scripts/setup.sh" >/dev/null
[[ -x $runtime_backend/omarchy-spotify-backend ]]
[[ $(<"$runtime_backend/backend-source.sha256") == "$backend_source_id" ]]
installed_hash=$(sha256sum -- "$runtime_backend/omarchy-spotify-backend")
[[ $(<"$runtime_backend/backend-binary.sha256") == "${installed_hash%% *}" ]]
[[ $(<"$runtime_backend/backend-origin") == "source-build:$backend_source_id" ]]
[[ $(stat -c '%a' "$runtime_backend/backend-source.sha256") == 600 ]]
[[ $(stat -c '%a' "$runtime_backend/backend-binary.sha256") == 600 ]]

# The shared verification passes for a current install, and setup then takes
# the ready path without rebuilding.
env "${sandbox_env[@]}" \
  "$source_root/scripts/backend-verify.sh" \
  "$runtime_backend/omarchy-spotify-backend" "$source_root"
env "${sandbox_env[@]}" \
  "$source_root/scripts/setup.sh" >"$test_root/setup-ready.log"
grep -q 'Session backend ready' "$test_root/setup-ready.log"

# A stale or tampered binary is refused: the shared verification reports a
# one-line reason, native-session asks for setup instead of exec'ing it, and
# a skip-build setup no longer reports the backend as ready.
printf '%s\n' 'tampered' >"$runtime_backend/omarchy-spotify-backend"
chmod 755 "$runtime_backend/omarchy-spotify-backend"
if env "${sandbox_env[@]}" \
    "$source_root/scripts/backend-verify.sh" \
    "$runtime_backend/omarchy-spotify-backend" "$source_root" \
    >"$test_root/verify-tampered.out" 2>&1; then
  echo "backend-verify.sh accepted a tampered binary" >&2
  exit 1
fi
grep -q 'hash does not match' "$test_root/verify-tampered.out"
native_session_output=$(printf '{"id":7,"command":"status"}\n' |
  env "${sandbox_env[@]}" "$source_root/scripts/native-session.sh" 2>/dev/null) || native_session_status=$?
[[ ${native_session_status:-0} -eq 7 ]]
grep -q '"id":7' <<<"$native_session_output"
grep -q 'Aria backend needs an update. Run scripts/setup.sh in the plugin folder, then log in again.' \
  <<<"$native_session_output"
env "${sandbox_env[@]}" \
  "OMARCHY_SPOTIFY_SKIP_BACKEND_BUILD=1" \
  "$source_root/scripts/setup.sh" >"$test_root/setup-stale.log"
! grep -q 'Session backend ready' "$test_root/setup-stale.log"

# A source-id mismatch and missing identity files are refused the same way.
printf '%064d\n' 0 >"$runtime_backend/backend-source.sha256"
printf '%s\n' 'mock backend' >"$runtime_backend/omarchy-spotify-backend"
chmod 755 "$runtime_backend/omarchy-spotify-backend"
if env "${sandbox_env[@]}" \
    "$source_root/scripts/backend-verify.sh" \
    "$runtime_backend/omarchy-spotify-backend" "$source_root" \
    >"$test_root/verify-stale-source.out" 2>&1; then
  echo "backend-verify.sh accepted a stale source id" >&2
  exit 1
fi
grep -q 'does not match the plugin source' "$test_root/verify-stale-source.out"

rm -f -- "$runtime_backend/backend-source.sha256" \
  "$runtime_backend/backend-binary.sha256"
if env "${sandbox_env[@]}" \
    "$source_root/scripts/backend-verify.sh" \
    "$runtime_backend/omarchy-spotify-backend" "$source_root" \
    >"$test_root/verify-missing-identity.out" 2>&1; then
  echo "backend-verify.sh accepted missing identity files" >&2
  exit 1
fi
grep -q 'identity files are missing' "$test_root/verify-missing-identity.out"

# A missing binary produces the install hint with the request id echoed back
# (fallback id 1 when the line carries none).
native_missing_dir="$test_root/runtime-lib-native/omarchy-spotify"
mkdir -p "$native_missing_dir"
native_missing_output=$(printf '{"id":4,"command":"login"}\n' |
  env "PATH=$mock_bin:$PATH" "HOME=$runtime_home" \
    "XDG_CONFIG_HOME=$runtime_config" "XDG_CACHE_HOME=$runtime_cache" \
    "XDG_STATE_HOME=$runtime_state" "XDG_RUNTIME_DIR=$runtime_session" \
    "OMARCHY_SPOTIFY_RUNTIME_DIR=$native_missing_dir" \
    "$source_root/scripts/native-session.sh" 2>/dev/null) || native_missing_status=$?
[[ ${native_missing_status:-0} -eq 7 ]]
grep -q '"id":4' <<<"$native_missing_output"
grep -q 'Aria backend is not installed. Run scripts/setup.sh in the plugin folder, then log in again.' \
  <<<"$native_missing_output"
native_fallback_output=$(printf '{"command":"login"}\n' |
  env "PATH=$mock_bin:$PATH" "HOME=$runtime_home" \
    "XDG_CONFIG_HOME=$runtime_config" "XDG_CACHE_HOME=$runtime_cache" \
    "XDG_STATE_HOME=$runtime_state" "XDG_RUNTIME_DIR=$runtime_session" \
    "OMARCHY_SPOTIFY_RUNTIME_DIR=$native_missing_dir" \
    "$source_root/scripts/native-session.sh" 2>/dev/null) || native_fallback_status=$?
[[ ${native_fallback_status:-0} -eq 7 ]]
grep -q '"id":1' <<<"$native_fallback_output"

# A plain removal moves the configuration aside and keeps plugin tokens and
# the shared spotifyd cache.
mkdir -p "$runtime_state/aria" "$runtime_cache/spotifyd"
printf '%s\n' '{"token":"mock"}' >"$runtime_state/aria/refresh-token-mock"
printf '%s\n' stale >"$runtime_cache/spotifyd/cached-file"
env "${sandbox_env[@]}" \
  "$source_root/scripts/remove-runtime.sh" >"$test_root/remove-plain.log"
grep -q 'Moved configuration to:' "$test_root/remove-plain.log"
find "$runtime_config" -maxdepth 1 -type d -name 'omarchy-spotify.bak.*' |
  grep -q .
[[ ! -e $runtime_backend/omarchy-spotify-backend ]]
[[ -f $runtime_state/aria/refresh-token-mock ]]
[[ -f $runtime_cache/spotifyd/cached-file ]]

# A modified legacy unit file is never touched; only an exact byte match with
# the last copy this plugin shipped may be disabled and deleted.
mkdir -p "$runtime_config/systemd/user"
printf '%s\n' 'stale unit' >"$runtime_config/systemd/user/omarchy-spotify.service"
: >"$systemctl_log"
mkdir -p "$runtime_config/omarchy-spotify" \
  "$runtime_config/omarchy-spotify.bak.20260827000000" \
  "$runtime_cache/omarchy-spotify/target" \
  "$runtime_state/omarchy-spotify" "$runtime_state/aria" \
  "$runtime_session/omarchy-spotify"
cp -- "$source_root/config/spotifyd.conf" \
  "$runtime_config/omarchy-spotify/spotifyd.conf"
printf '%s\n' stale >"$runtime_config/omarchy-spotify.bak.20260827000000/spotifyd.conf"
printf '%s\n' stale >"$runtime_cache/omarchy-spotify/target/build-artifact"
printf '%s\n' '{"token":"mock"}' >"$runtime_state/aria/refresh-token-mock"
printf '%s\n' stale >"$runtime_session/omarchy-spotify/backend.sock"
: >"$secret_log"
env "${sandbox_env[@]}" \
  "TEST_SECRET_LOG=$secret_log" \
  "TEST_SYSTEMCTL_LOG=$systemctl_log" \
  "$source_root/scripts/remove-runtime.sh" --purge \
  >"$test_root/remove-purge.log" 2>"$test_root/remove-purge.err"
[[ -f $runtime_config/systemd/user/omarchy-spotify.service ]]
grep -q 'kept modified unit file' "$test_root/remove-purge.err"
! grep -q -- '--user disable --now' "$systemctl_log"
[[ ! -e $runtime_config/omarchy-spotify ]]
[[ ! -e $runtime_config/omarchy-spotify.bak.20260827000000 ]]
[[ ! -e $runtime_cache/omarchy-spotify ]]
[[ ! -e $runtime_state/omarchy-spotify ]]
[[ ! -e $runtime_state/aria ]]
[[ ! -e $runtime_session/omarchy-spotify ]]
[[ ! -e $runtime_backend ]]
grep -q 'Removed plugin tokens and session state.' "$test_root/remove-purge.log"
grep -q 'Removed spotifyd configuration.' "$test_root/remove-purge.log"
grep -q 'Cleared matching Aria keyring entries.' "$test_root/remove-purge.log"
grep -q 'clear service aria kind refresh-token' "$secret_log"
# The shared spotifyd cache belongs to the spotifyd package, not this plugin.
[[ -d $runtime_cache/spotifyd ]]
grep -q 'Runtime integration removed' "$test_root/remove-purge.log"

# A relative XDG path is refused before anything is touched.
set +e
env "PATH=$mock_bin:$PATH" "HOME=$runtime_home" \
  XDG_CACHE_HOME="relative-cache" \
  "$source_root/scripts/remove-runtime.sh" --purge >/dev/null 2>&1
unsafe_remove_status=$?
set -e
[[ $unsafe_remove_status -eq 3 ]]

# An undeletable plugin state dir turns into a failed purge with a clear
# message and a distinct exit code.
mkdir -p "$runtime_state/aria" "$runtime_config/omarchy-spotify"
printf '%s\n' '{"token":"mock"}' >"$runtime_state/aria/refresh-token-mock"
chmod 500 "$runtime_state/aria"
set +e
env "${sandbox_env[@]}" \
  "TEST_SECRET_LOG=$secret_log" \
  "$source_root/scripts/remove-runtime.sh" --purge \
  >/dev/null 2>"$test_root/remove-failed.err"
failed_purge_status=$?
set -e
chmod 755 "$runtime_state/aria"
rm -rf -- "$runtime_state/aria"
[[ $failed_purge_status -eq 4 ]]
grep -q 'failed to remove plugin state' "$test_root/remove-failed.err"
grep -q 'some plugin files could not be deleted' "$test_root/remove-failed.err"

# The top-level uninstaller wraps the runtime purge, removes the plugin
# through Omarchy, clears exact-ID backups, restarts the shell, and remains
# idempotent.
plugin_dir="$runtime_home/.config/omarchy/plugins/aria"
plugin_backup="$runtime_home/.config/omarchy/plugins/.aria.bak.20260827000000"
mkdir -p "$(dirname -- "$plugin_dir")" "$plugin_backup" \
  "$runtime_config/omarchy-spotify" "$runtime_state/aria"
ln -s -- "$source_root" "$plugin_dir"
printf '%s\n' stale >"$runtime_config/omarchy-spotify/spotifyd.conf"
printf '%s\n' stale >"$runtime_state/aria/refresh-token-mock"
: >"$omarchy_log"
env "${sandbox_env[@]}" \
  "TEST_OMARCHY_LOG=$omarchy_log" \
  "$source_root/scripts/uninstall.sh" >"$test_root/uninstall.log" 2>&1
[[ ! -e $plugin_dir && ! -L $plugin_dir && ! -e $plugin_backup ]]
[[ ! -e $runtime_config/omarchy-spotify ]]
[[ ! -e $runtime_state/aria ]]
[[ ! -e $runtime_backend ]]
grep -q 'plugin disable aria' "$omarchy_log"
grep -q 'plugin remove aria --yes' "$omarchy_log"
grep -q 'restart shell' "$omarchy_log"
grep -q 'completely uninstalled' "$test_root/uninstall.log"

# A second run has nothing left to remove: no duplicate plugin removal.
env "${sandbox_env[@]}" \
  "TEST_OMARCHY_LOG=$omarchy_log" \
  "$source_root/scripts/uninstall.sh" >/dev/null 2>&1
[[ $(grep -c '^plugin remove aria --yes$' "$omarchy_log") -eq 1 ]]

# Static checks keep the scripts honest about the current architecture.
grep -q 'remove-runtime.sh.*--purge' "$source_root/scripts/uninstall.sh"
grep -q 'omarchy plugin remove aria --yes' "$source_root/scripts/uninstall.sh"
grep -q 'backend-verify.sh' "$source_root/scripts/native-session.sh"
grep -q 'backend-verify.sh' "$source_root/scripts/setup.sh"
grep -q '^## Remove it completely$' "$source_root/README.md"
if grep -rn --exclude-dir=__pycache__ '/home/dann' "$source_root/scripts" \
    "$source_root/Service.qml" "$source_root/BarWidget.qml" \
    "$source_root/Panel.qml" "$source_root/Api.js"; then
  echo "A hardcoded /home/dann path leaked into the plugin" >&2
  exit 1
fi
# The legacy OAuth component stays isolated; the app uses native login.
grep -q 'property string clientId: ""' "$source_root/AuthManager.qml"
! grep -q 'd420a117a32841c2b3474932e49fb54b' "$source_root/AuthManager.qml"
grep -q 'readonly property string redirectUri: "http://127.0.0.1:"' \
  "$source_root/AuthManager.qml"
grep -q 'resolvedClientId' "$source_root/AuthManager.qml"
grep -q 'customClientId' "$source_root/AuthManager.qml"
grep -qF '[0-9a-f]{32}' "$source_root/AuthManager.qml"
! grep -q '"clientId"' "$source_root/manifest.json"
grep -q 'nativeSession: authManager' "$source_root/Service.qml"
! grep -q '"oauthPort"' "$source_root/manifest.json"
grep -q 'window.close()' "$source_root/OAuth.js"
grep -q 'gh attestation verify' "$source_root/scripts/build-backend.sh"
grep -q -- '--cert-identity' "$source_root/scripts/build-backend.sh"
grep -q -- '--source-ref' "$source_root/scripts/build-backend.sh"
grep -q -- '--source-digest' "$source_root/scripts/build-backend.sh"
grep -q -- '--deny-self-hosted-runners' "$source_root/scripts/build-backend.sh"
! grep -q 'ALLOW_UNVERIFIED' "$source_root/scripts/build-backend.sh"
if grep -E '^[[:space:]]*uses:' \
    "$source_root/.github/workflows/release-backend.yml" \
    | grep -Ev '@[0-9a-f]{40}([[:space:]]+#.*)?$'; then
  echo "release-backend.yml contains a mutable action reference" >&2
  exit 1
fi
jq -e '(.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
  and .barWidget.defaultSection == "left"
  and .barWidget.defaults.showMiniPlayer == "On"
  and (.barWidget.schema[] | select(.key == "showMiniPlayer").defaultValue) == "On"
  and .barWidget.defaults.showPausedTrack == "On"
  and (.barWidget.schema[] | select(.key == "showPausedTrack").defaultValue) == "On"
  and .barWidget.defaults.showVinylRecord == "Off"
  and (.barWidget.schema[] | select(.key == "showVinylRecord").defaultValue) == "Off"
  and .barWidget.defaults.shortcutHints == "On"
  and (.barWidget.schema[] | select(.key == "shortcutHints").defaultValue) == "On"
  and .barWidget.defaults.showLyrics == "On"
  and (.barWidget.schema[] | select(.key == "showLyrics").defaultValue) == "On"
  and .barWidget.defaults.maxBarTextWidth == "240"
  and (.barWidget.schema[] | select(.key == "maxBarTextWidth").defaultValue) == "240"' \
  "$source_root/manifest.json" >/dev/null
grep -qx 'section=left' "$source_root/scripts/install-local.sh"
grep -qx 'bitrate = 320' "$source_root/config/spotifyd.conf"
grep -qx 'no_audio_cache = false' "$source_root/config/spotifyd.conf"
grep -qx 'max_cache_size = 1000000000' "$source_root/config/spotifyd.conf"

echo "Script tests passed."
