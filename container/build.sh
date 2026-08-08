#!/usr/bin/env bash
set -eo pipefail

# Alliance Canada clusters only define `module` in login/interactive shells.
# Source the CVMFS environment init explicitly so it's available here too.
if [[ -f /cvmfs/soft.computecanada.ca/config/profile/bash.sh ]]; then
    source /cvmfs/soft.computecanada.ca/config/profile/bash.sh
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEF_FILE="$SCRIPT_DIR/ollama.def"
OUT="${1:-$PWD/ollama.sif}"

usage() {
    cat <<EOF
Usage: $0 [OUTPUT.sif]
...
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if command -v module >/dev/null 2>&1; then
    set +u
    module load apptainer
    set -u
else
    echo "WARNING: 'module' command still not found after sourcing CVMFS profile." >&2
fi

if ! command -v apptainer >/dev/null 2>&1; then
    echo "ERROR: apptainer not found in PATH." >&2
    echo "Run this on an Alliance Canada login node (e.g. narval, graham)." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"

echo "Building $OUT from $DEF_FILE (downloads base image; can take several minutes)..."
apptainer build "$OUT" "$DEF_FILE"
echo "Done: $OUT"