#!/usr/bin/env bash
# Verify an installed backend binary against the plugin source tree, using the
# identity files scripts/build-backend.sh records at install time. setup.sh
# calls this to decide between a rebuild and the ready path, and
# native-session.sh calls it before every launch so a stale or tampered binary
# is never started as the login backend.
#
# Usage: backend-verify.sh <backend-binary> <plugin-source-root>
# Exits 0 when the binary is current; exits 1 with a one-line reason on stderr
# when it is missing, stale, or does not match its recorded hash.
set -euo pipefail

backend_binary=${1:?usage: backend-verify.sh <backend-binary> <source-root>}
source_root=${2:?usage: backend-verify.sh <backend-binary> <source-root>}
runtime_dir=$(dirname -- "$backend_binary")
backend_source_id_file="$runtime_dir/backend-source.sha256"
backend_binary_hash_file="$runtime_dir/backend-binary.sha256"

[[ -x $backend_binary && -s $backend_source_id_file \
  && -s $backend_binary_hash_file ]] || {
  echo "backend binary or identity files are missing" >&2
  exit 1
}

current_source_id=$("$source_root/scripts/backend-source-id.sh")
expected_source_id=$(<"$backend_source_id_file")
[[ $expected_source_id == "$current_source_id" ]] || {
  echo "installed backend does not match the plugin source (stale build)" >&2
  exit 1
}

expected_binary_hash=$(<"$backend_binary_hash_file")
[[ $expected_binary_hash =~ ^[0-9a-f]{64}$ ]] || {
  echo "recorded backend hash is invalid" >&2
  exit 1
}
actual_binary_hash=$(sha256sum -- "$backend_binary")
[[ ${actual_binary_hash%% *} == "$expected_binary_hash" ]] || {
  echo "installed backend binary hash does not match the recorded hash" >&2
  exit 1
}
