#!/bin/bash

set -euo pipefail
# -e exit on error
# -u undefine variable become error
# -o pipefail detect failure inside pipelines

source config/env.sh
source "$VENV_DIR/bin/activate"

echo "starting scan on directory $WORKSPACE"

echo "Running Checkov .............."

if [ ! -d "$WORKSPACE" ]; then
	echo "workspace not found: $WORKSPACE"
	exit 1
fi

if ! command -v checkov >/dev/null 2>&1; then
	echo "checkov not found"
	exit 1
fi

CHECKOV_REPORT_DIR="$REPORT_DIR/checkov/checkov_${TIMESTAMP}"
mkdir -p "$CHECKOV_REPORT_DIR"

# checkov exit codes: 0 = no failed checks, 1 = failed checks, 2 = error
# --output-file-path is treated as a directory; results land in results_json.json inside it
set +e
checkov --directory "$WORKSPACE" --output cli --output json --output-file-path "$CHECKOV_REPORT_DIR"
CHECKOV_EXIT_CODE=$?
set -e

CHECKOV_REPORT="$CHECKOV_REPORT_DIR/results_json.json"

echo "Scan completed, Report generated in $CHECKOV_REPORT"

if [ "$CHECKOV_EXIT_CODE" -eq 0 ]; then
	echo "no issue found"
else
	echo "checkov issue found exit code: $CHECKOV_EXIT_CODE"
fi

echo -e "............. summary of checkov .............."
if command -v jq >/dev/null 2>&1 && [ -s "$CHECKOV_REPORT" ]; then
	PASSED=$(jq -r '([.[].summary.passed // 0] | add)' "$CHECKOV_REPORT")
	FAILED=$(jq -r '([.[].summary.failed // 0] | add)' "$CHECKOV_REPORT")
	echo -e "\n total checks passed: $PASSED & failed: $FAILED"
fi
