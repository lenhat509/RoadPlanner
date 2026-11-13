#!/usr/bin/env bash
# Points git at the versioned hooks in .githooks/.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
git config core.hooksPath .githooks
echo "Git hooks installed (core.hooksPath=.githooks)."
