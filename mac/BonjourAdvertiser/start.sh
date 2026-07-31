#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
exec swift run quic-video-bonjour "$@"
