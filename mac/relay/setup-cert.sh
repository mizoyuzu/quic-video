#!/usr/bin/env bash
set -euo pipefail

if ! command -v mkcert >/dev/null 2>&1; then
  printf '%s\n' 'mkcert is required: brew install mkcert nss'
  exit 1
fi

cd "$(dirname "$0")/../.."
mkcert -install
local_host_name="$(scutil --get LocalHostName)"
computer_name="$(scutil --get ComputerName)"
wifi_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
names=(
  localhost
  127.0.0.1
  ::1
  "${local_host_name}.local"
  "${computer_name}.local"
)
if [[ -n "$wifi_ip" ]]; then
  names+=("$wifi_ip")
fi
mkcert \
  -cert-file mac/relay/relay.pem \
  -key-file mac/relay/relay-key.pem \
  "${names[@]}"

openssl x509 -in mac/relay/relay.pem -noout -fingerprint -sha256
