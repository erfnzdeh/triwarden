#!/usr/bin/env bash
# A fresh native Vaultwarden behind HTTPS, with synthetic accounts only.
set -euo pipefail
server=${1:?usage: integration.sh /path/to/vaultwarden}
port=${CI_SERVER_PORT:-18843}
[[ $port == 18843 || $port == 18844 ]] || { echo 'Invalid test port' >&2; exit 64; }
python=${CI_SEED_PYTHON:-python3}
state=$(mktemp -d "${TMPDIR:-/tmp}/triwarden-ci.XXXXXX")
mkdir -p build/ci-integration "$state/data"
server_pid=''; proxy_pid=''
cleanup() {
  [[ -z $proxy_pid ]] || kill "$proxy_pid" 2>/dev/null || true
  [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
  [[ -z $proxy_pid ]] || wait "$proxy_pid" 2>/dev/null || true
  [[ -z $server_pid ]] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$state"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -keyout "$state/key.pem" -out "$state/ca.pem" >/dev/null 2>&1
DATA_FOLDER="$state/data" ROCKET_ADDRESS=127.0.0.1 ROCKET_PORT=18880 \
  DOMAIN="https://localhost:$port" WEB_VAULT_ENABLED=false SIGNUPS_ALLOWED=true \
  SIGNUPS_VERIFY=false LOGIN_RATELIMIT_MAX_BURST=1000 LOGIN_RATELIMIT_SECONDS=1 \
  "$server" >build/ci-integration/server.log 2>&1 &
server_pid=$!
cat > "$state/Caddyfile" <<CADDY
{
  admin off
  auto_https off
}
https://localhost:$port {
  bind 127.0.0.1
  tls $state/ca.pem $state/key.pem
  reverse_proxy 127.0.0.1:18880
}
CADDY
caddy run --config "$state/Caddyfile" --adapter caddyfile >build/ci-integration/proxy.log 2>&1 &
proxy_pid=$!
ready=0
for attempt in {1..60}; do
  if curl --fail --silent --cacert "$state/ca.pem" "https://localhost:$port/alive" >/dev/null; then ready=1; break; fi
  kill -0 "$server_pid" && kill -0 "$proxy_pid" || break
  sleep 1
done
[[ $ready == 1 ]] || { echo 'Disposable server did not become ready' >&2; exit 1; }
"$python" DevServer/seed.py "https://localhost:$port" --ca "$state/ca.pem"
(
  cd Packages/VaultCore
  TRIWARDEN_DEV_HOST=localhost TRIWARDEN_DEV_PORTS="$port" TRIWARDEN_DEV_CA="$state/ca.pem" \
    swift test --filter DevServerTests
) 2>&1 | tee build/ci-integration/tests.log
