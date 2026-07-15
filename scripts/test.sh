#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${SCRIPT_DIR}"

# Normalize line endings when the repo is bind-mounted from Windows hosts.
find "${SCRIPT_DIR}" -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true

chmod +x gen_image.sh scripts/*.sh scripts/lib/*.sh .devcontainer/post_start.sh 2>/dev/null || true

bash ./gen_image.sh
bash ./scripts/verify_image.sh
