#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifact_dir="${1:-/workspace/artifacts/issue-146-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -e "$artifact_dir" ]]; then
  echo "Artifact directory already exists: $artifact_dir" >&2
  exit 1
fi
mkdir -p "$artifact_dir"
artifact_dir="$(cd "$artifact_dir" && pwd)"
export SLIVE_E2E_ARTIFACT_DIR="$artifact_dir"
export XDG_CONFIG_HOME="$artifact_dir/profile/config"
export XDG_CACHE_HOME="$artifact_dir/profile/cache"
export XDG_DATA_HOME="$artifact_dir/profile/data"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
chmod 700 "$artifact_dir/profile"
export NO_PROXY="localhost,127.0.0.1,::1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"
export http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
export https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"
export SLIVE_E2E_REPO="$repo_dir"
export SLIVE_E2E_PHASES="${SLIVE_E2E_PHASES:-exercise peer-seed owner-delete peer-merge restart}"
for phase in $SLIVE_E2E_PHASES; do
  case "$phase" in
    exercise|peer-seed|owner-delete|peer-merge|restart|native-endurance|audio-switch) ;;
    *) echo "Unknown real application phase: $phase" >&2; exit 1 ;;
  esac
done
export SLIVE_E2E_COMMAND="SLIVE_E2E_PHASES='$SLIVE_E2E_PHASES' scripts/e2e/issue-146.sh $artifact_dir"
build_tool="$repo_dir/simple_live_app/rust_builder/cargokit/run_build_tool.sh"
build_tool_mode="$(stat -c '%a' "$build_tool")"
if [[ "${SLIVE_E2E_SEAL_ARTIFACTS:-0}" == 1 ]]; then
  python3 "$repo_dir/scripts/e2e/manifest" begin
fi
finish() {
  local result=$?
  trap - EXIT
  chmod "$build_tool_mode" "$build_tool"
  if [[ "${SLIVE_E2E_SEAL_ARTIFACTS:-0}" == 1 ]]; then
    python3 "$repo_dir/scripts/e2e/manifest" finish "$result"
  else
    python3 "$repo_dir/scripts/e2e/manifest" clean
  fi
  exit "$result"
}
trap finish EXIT
for required in flutter dbus-run-session Xvfb xdpyinfo import gdbus ffprobe sha256sum; do
  command -v "$required" >/dev/null || { echo "Missing prerequisite: $required" >&2; exit 2; }
done
flutter --version --machine > "$artifact_dir/flutter-version.json"
dbus-run-session -- bash "$repo_dir/scripts/e2e/run-linux-session.sh"
python3 "$repo_dir/scripts/e2e/manifest" status
