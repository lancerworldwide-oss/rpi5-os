#!/bin/bash
set -euo pipefail

bash /workspace/scripts/lib/setup_binfmt.sh

if [ -d /workspace/.git ]; then
    git config --global --add safe.directory /workspace 2>/dev/null || true
fi

echo "DDM dev container ready."
