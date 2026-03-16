#!/usr/bin/env bash
set -euo pipefail

# init-artifact.sh — Initialize artifact directories and metadata for GitHub Actions CI/CD.
# Supports both build outputs and test results.

ARTIFACT_ROOT="${ARTIFACT_ROOT:-artifacts}"
BUILD_DIR="${ARTIFACT_ROOT}/build"
TEST_DIR="${ARTIFACT_ROOT}/test-results"
METADATA_FILE="${ARTIFACT_ROOT}/metadata.json"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Initialize CI/CD artifact directories and metadata for GitHub Actions.

Options:
  -r, --root DIR    Artifact root directory (default: artifacts)
  -c, --clean       Remove existing artifacts before initializing
  -h, --help        Show this help message
EOF
  exit 0
}

CLEAN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--root)
      ARTIFACT_ROOT="$2"
      BUILD_DIR="${ARTIFACT_ROOT}/build"
      TEST_DIR="${ARTIFACT_ROOT}/test-results"
      METADATA_FILE="${ARTIFACT_ROOT}/metadata.json"
      shift 2
      ;;
    -c|--clean)
      CLEAN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$CLEAN" == true ]] && [[ -d "$ARTIFACT_ROOT" ]]; then
  echo "Cleaning existing artifact directory: ${ARTIFACT_ROOT}"
  rm -rf "$ARTIFACT_ROOT"
fi

echo "Initializing artifact directories..."
mkdir -p "$BUILD_DIR"
mkdir -p "$TEST_DIR"
mkdir -p "${TEST_DIR}/coverage"
mkdir -p "${TEST_DIR}/reports"

# Gather metadata from git and environment
GIT_SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo "unknown")}"
GIT_REF="${GITHUB_REF:-$(git symbolic-ref HEAD 2>/dev/null || echo "unknown")}"
GIT_SHORT_SHA="${GIT_SHA:0:7}"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RUN_ID="${GITHUB_RUN_ID:-local}"
RUN_NUMBER="${GITHUB_RUN_NUMBER:-0}"
REPOSITORY="${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null || echo "unknown")}"

cat > "$METADATA_FILE" <<METAEOF
{
  "timestamp": "${TIMESTAMP}",
  "git": {
    "sha": "${GIT_SHA}",
    "short_sha": "${GIT_SHORT_SHA}",
    "ref": "${GIT_REF}"
  },
  "ci": {
    "run_id": "${RUN_ID}",
    "run_number": "${RUN_NUMBER}",
    "repository": "${REPOSITORY}"
  },
  "artifacts": {
    "build": "${BUILD_DIR}",
    "test_results": "${TEST_DIR}"
  }
}
METAEOF

echo "Artifact structure created:"
echo "  ${ARTIFACT_ROOT}/"
echo "  ├── build/"
echo "  ├── test-results/"
echo "  │   ├── coverage/"
echo "  │   └── reports/"
echo "  └── metadata.json"
echo ""
echo "Metadata written to ${METADATA_FILE}"
echo "  commit: ${GIT_SHORT_SHA}"
echo "  run:    ${RUN_ID}/#${RUN_NUMBER}"
