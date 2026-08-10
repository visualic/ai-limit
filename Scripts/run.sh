#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
exec .build/debug/AILimit "$@"
