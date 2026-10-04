#!/usr/bin/env bash
set -euo pipefail
: "${SLIVE_E2E_ARTIFACT_DIR:?Run issue-146.sh}"
: "${SLIVE_E2E_REPO:?Run issue-146.sh}"
artifact_dir="$SLIVE_E2E_ARTIFACT_DIR"
xvfb_pid=''
webdav_pid=''
audio_helper="${SLIVE_E2E_AUDIO_HELPER:-/workspace/toolchains/audio-session.sh}"
cleanup() {
  if declare -F slive_stop_audio >/dev/null; then slive_stop_audio; fi
  if [[ -n "$webdav_pid" ]]; then
    kill "$webdav_pid" 2>/dev/null || true
    wait "$webdav_pid" 2>/dev/null || true
  fi
  if [[ -n "$xvfb_pid" ]]; then
    kill "$xvfb_pid" 2>/dev/null || true
    wait "$xvfb_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
if [[ ! -f "$audio_helper" ]]; then
  echo "Install the real PulseAudio/ALSA session helper and set SLIVE_E2E_AUDIO_HELPER." >&2
  exit 2
fi
source "$audio_helper"
slive_start_audio "$artifact_dir/audio"
if [[ -z "${DISPLAY:-}" ]]; then
  Xvfb -displayfd 3 -screen 0 1440x1000x24 -nolisten tcp 3> "$artifact_dir/display-number" > "$artifact_dir/xvfb.log" 2>&1 &
  xvfb_pid=$!
  for attempt in {1..100}; do
    [[ -s "$artifact_dir/display-number" ]] && break
    kill -0 "$xvfb_pid"
    sleep 0.1
  done
  export DISPLAY=":$(cat "$artifact_dir/display-number")"
fi
xdpyinfo > "$artifact_dir/display-info.txt"
webdav_bin="${SLIVE_E2E_WEBDAV_BIN:-/workspace/toolchains/e2e-venv/bin/wsgidav}"
if [[ ! -x "$webdav_bin" ]]; then
  echo "Install WsgiDAV and cheroot in a virtual environment and set SLIVE_E2E_WEBDAV_BIN." >&2
  exit 2
fi
"$webdav_bin" --version > "$artifact_dir/webdav-version.txt"
mkdir -p "$artifact_dir/webdav-root"
python3 - <<'PY'
import json, os, pathlib, socket
root = pathlib.Path(os.environ['SLIVE_E2E_ARTIFACT_DIR'])
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
(root / 'webdav-port').write_text(str(port))
(root / 'webdav-config.json').write_text(json.dumps({
    'host': '127.0.0.1', 'port': port, 'server': 'cheroot', 'verbose': 1,
    'provider_mapping': {'/': str(root / 'webdav-root')},
    'simple_dc': {'user_mapping': {'*': {'e2e': {'password': 'local-test-only'}}}},
    'http_authenticator': {'accept_basic': True, 'accept_digest': False, 'default_to_digest': False},
}))
PY
export SLIVE_E2E_WEBDAV_URL="http://127.0.0.1:$(cat "$artifact_dir/webdav-port")"
"$webdav_bin" --config "$artifact_dir/webdav-config.json" > "$artifact_dir/webdav.log" 2>&1 &
webdav_pid=$!
for attempt in {1..100}; do
  if curl --noproxy '*' --silent --fail --user e2e:local-test-only -X OPTIONS "$SLIVE_E2E_WEBDAV_URL" >/dev/null; then break; fi
  kill -0 "$webdav_pid"
  sleep 0.1
done
cd "$SLIVE_E2E_REPO/simple_live_app"
phase_failures=0
for phase in $SLIVE_E2E_PHASES; do
  if [[ "$phase" == peer-* ]]; then
    profile_dir="$artifact_dir/peer-profile"
  else
    profile_dir="$artifact_dir/profile"
  fi
  export XDG_CONFIG_HOME="$profile_dir/config"
  export XDG_CACHE_HOME="$profile_dir/cache"
  export XDG_DATA_HOME="$profile_dir/data"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
  chmod 700 "$profile_dir"
  export SLIVE_E2E_PHASE="$phase"
  if ! flutter drive --no-pub -d linux \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/issue_146_test.dart \
    > "$artifact_dir/flutter-$phase.log" 2>&1; then
    python3 "$SLIVE_E2E_REPO/scripts/e2e/manifest" progress "$phase"
    echo "Application phase $phase failed; diagnostics are in $artifact_dir."
    phase_failures=1
    if [[ "$phase" == exercise &&
      ( ! -s "$artifact_dir/peer-initial-backup.zip" || ! -s "$artifact_dir/restart-expected.json" ) ]]; then
      echo "The later process phases have no completed persistence prerequisites."
      break
    fi
    continue
  fi
  python3 "$SLIVE_E2E_REPO/scripts/e2e/manifest" progress "$phase"
done
exit "$phase_failures"
