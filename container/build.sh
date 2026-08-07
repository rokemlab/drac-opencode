#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEF_FILE="$SCRIPT_DIR/ollama.def"
OUT="${1:-$PWD/ollama.sif}"

usage() {
    cat <<EOF
Usage: $0 [OUTPUT.sif]

Build the Apptainer image for GPU-backed Ollama on Alliance Canada clusters.

Arguments:
  OUTPUT.sif   Output image path (default: $PWD/ollama.sif)

Run this on an Alliance Canada login node (apptainer is not available on
macOS). The login node has internet access to fetch the base image.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ! command -v apptainer >/dev/null 2>&1; then
    echo "ERROR: apptainer not found in PATH." >&2
    echo "Run this on an Alliance Canada login node (e.g. narval, graham)." >&2
    echo "If apptainer is not on PATH, try: module load apptainer" >&2
    exit 1
fi

echo "Building $OUT from $DEF_FILE (downloads base image; can take several minutes)..."
apptainer build "$OUT" "$DEF_FILE"
echo "Done: $OUT"
