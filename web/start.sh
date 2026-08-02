#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
port="${1:-8080}"
exec python3 -m http.server "$port" --bind 127.0.0.1 --directory web
