#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 0 ] || { echo 'ci-runner-farm container adapter accepts JSON on stdin only' >&2; exit 64; }
exec bash "$SCRIPT_DIR/runner-farm.sh" distributed-adapter
