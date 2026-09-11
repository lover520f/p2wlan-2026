#!/usr/bin/env bash
set -euo pipefail

# Run a short, isolated smoke test on the staging host.  The process uses a
# temporary database and high ports, so this never touches the managed
# installation or its persistent data.
BUNDLE_DIR=${1:?bundle directory is required}
RUN_ID=${2:-0}
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported staging architecture: $(uname -m)" >&2; exit 1 ;;
esac

ARCHIVE="$BUNDLE_DIR/p2wlan-server-linux-$ARCH.tar.gz"
CHECKSUM="$ARCHIVE.sha256"
[ -f "$ARCHIVE" ] || { echo "missing $ARCHIVE" >&2; exit 1; }
[ -f "$CHECKSUM" ] || { echo "missing $CHECKSUM" >&2; exit 1; }
(cd "$BUNDLE_DIR" && sha256sum -c "$(basename "$CHECKSUM")")

work_dir=$(mktemp -d "/tmp/p2wlan-server-smoke.XXXXXX")
cleanup() {
  if [ -n "${control_pid:-}" ]; then kill "$control_pid" 2>/dev/null || true; wait "$control_pid" 2>/dev/null || true; fi
  if [ -n "${relay_pid:-}" ]; then kill "$relay_pid" 2>/dev/null || true; wait "$relay_pid" 2>/dev/null || true; fi
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

tar -xzf "$ARCHIVE" -C "$work_dir" --no-same-owner --no-same-permissions
(cd "$work_dir" && sha256sum -c SHA256SUMS)
"$work_dir/p2wlan-control" --version
"$work_dir/p2wlan-relay" --version

# Keep ports outside the managed 18080/18081 pair.  RUN_ID is supplied by
# Actions and only affects this temporary process.
control_port=$((28080 + RUN_ID % 500))
relay_port=$((28580 + RUN_ID % 500))
PORT="$control_port" \
DB_PATH="$work_dir/p2pnet.db" \
JWT_SECRET="staging-smoke-$RUN_ID" \
SIGNAL_WS_MAX_CONNECTIONS=32 \
  "$work_dir/p2wlan-control" >"$work_dir/control.log" 2>&1 &
control_pid=$!

RELAY_BIND="127.0.0.1:$relay_port" \
RELAY_REQUIRE_AUTH=false \
RELAY_ALLOW_INSECURE_PLAINTEXT=true \
  "$work_dir/p2wlan-relay" >"$work_dir/relay.log" 2>&1 &
relay_pid=$!

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$control_port/health" >/dev/null; then
    if kill -0 "$relay_pid" 2>/dev/null; then
      echo "staging-server-smoke-passed arch=$ARCH control_port=$control_port relay_port=$relay_port"
      exit 0
    fi
  fi
  if ! kill -0 "$control_pid" 2>/dev/null; then
    cat "$work_dir/control.log" >&2 || true
    exit 1
  fi
  sleep 1
done

echo "staging server did not become healthy" >&2
cat "$work_dir/control.log" >&2 || true
cat "$work_dir/relay.log" >&2 || true
exit 1
