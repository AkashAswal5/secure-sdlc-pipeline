#!/bin/bash

set -euo pipefail
 # -e  Exit on error
 # -u  Undefined variables become errors
 # -o pipefail  Detect failures inside pipelines

source config/env.sh

echo "starting scan on directory $WORKSPACE"

echo "Running gitleaks"

if [ ! -d "$WORKSPACE" ]; then
    echo "Workspace not found: $WORKSPACE"
    exit 1
fi

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "Gitleaks is not installed."
    exit 1
fi

set +e # gitleaks return non zero exit code (because it found secrets), script may exit before

gitleaks git "$WORKSPACE" --report-format json --report-path "$REPORT_DIR/gitleaks/gitleaks_git_${TIMESTAMP}.json"
gitleaks dir "$WORKSPACE" --report-format json --report-path "$REPORT_DIR/gitleaks/gitleaks_dir_${TIMESTAMP}.json"

SCAN_EXIT_CODE=$?

set -e

if [ $SCAN_EXIT_CODE -eq 0 ]; then
	echo "scan completed, no issue found"
	echo "gitleaks scan completed, report generated in $REPORT_DIR"
else
	echo "gitleaks issue found exit code: $SCAN_EXIT_CODE"
fi

