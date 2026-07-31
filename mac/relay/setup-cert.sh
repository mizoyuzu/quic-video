#!/usr/bin/env bash
set -euo pipefail

if ! command -v mkcert >/dev/null 2>&1; then
  printf '%s\n' 'mkcert is required: brew install mkcert nss'
  exit 1
fi

cd "$(dirname "$0")/../.."
mkcert -install
mkcert \
  -cert-file mac/relay/relay.pem \
  -key-file mac/relay/relay-key.pem \
  localhost 127.0.0.1 ::1 "$(scutil --get LocalHostName).local"

openssl x509 -in mac/relay/relay.pem -noout -fingerprint -sha256
