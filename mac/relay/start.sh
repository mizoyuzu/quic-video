#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
if ! command -v moq-relay >/dev/null 2>&1; then
  printf '%s\n' 'moq-relay is required. Install the pinned release from moq-dev/moq.'
  exit 1
fi
if [[ ! -f mac/relay/relay.pem || ! -f mac/relay/relay-key.pem ]]; then
  printf '%s\n' 'TLS files are missing. Run mac/relay/setup-cert.sh first.'
  exit 1
fi
exec moq-relay mac/relay/relay.toml
