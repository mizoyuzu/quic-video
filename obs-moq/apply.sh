#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s /path/to/moq-checkout\n' "$0"
  exit 2
fi

git -C "$1" apply --recount "$(dirname "$0")"/patches/*.patch
