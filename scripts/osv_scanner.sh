#!/bin/bash

set -euo pipefail
# -e exit on error
# -u undefine variable become error
# -o pipefail detect failure inside pipelines

source config/env.sh

echo "starting scan on directory $WORKSPACE"

echo "Running OSV-Scanner .............."

if [ ! -d "$WORKSPACE" ]; then
	echo "workspace not found: $WORKSPACE"
	exit 1
fi

# find osv-scanner: PATH first, then tools-workspace binary (github release fallback)
if command -v osv-scanner >/dev/null 2>&1; then
	OSV_BIN=$(command -v osv-scanner)
elif [ -x "$TOOLS_WORKSPACE/bin/osv-scanner" ]; then
	OSV_BIN="$TOOLS_WORKSPACE/bin/osv-scanner"
else
	echo "osv-scanner not found"
	exit 1
fi

OSV_JSON_REPORT="$REPORT_DIR/osv-scanner/osv-scanner_${TIMESTAMP}.json"
OSV_TXT_REPORT="$REPORT_DIR/osv-scanner/osv-scanner_${TIMESTAMP}.txt"

# exit codes: 0 = no vulnerabilities, 1 = vulnerabilities found, 2 = error
set +e
"$OSV_BIN" scan source --recursive "$WORKSPACE" --format json --output-file "$OSV_JSON_REPORT"
OSV_JSON_EXIT_CODE=$?
"$OSV_BIN" scan source --recursive "$WORKSPACE" --format table --output-file "$OSV_TXT_REPORT"
OSV_TXT_EXIT_CODE=$?
set -e

echo "Scan completed, Report generated in $REPORT_DIR/osv-scanner"

# exit codes: 0 = no vulnerabilities, 1 = vulnerabilities found, 2 = error, 128 = no package files found
if [ "$OSV_JSON_EXIT_CODE" -eq 128 ] && [ "$OSV_TXT_EXIT_CODE" -eq 128 ]; then
	echo "no package files (lockfiles) found in workspace, nothing to scan"
elif [ "$OSV_JSON_EXIT_CODE" -eq 0 ] && [ "$OSV_TXT_EXIT_CODE" -eq 0 ]; then
	echo "no issue found"
else
	echo "osv-scanner issue found, json exit code: $OSV_JSON_EXIT_CODE, txt exit code: $OSV_TXT_EXIT_CODE"
fi

echo -e "............. summary of osv-scanner .............."
if command -v jq >/dev/null 2>&1 && [ -s "$OSV_JSON_REPORT" ]; then
	VULN_COUNT=$(jq -r '[.results[]?.packages[]?.vulnerabilities[]?.id] | unique | length' "$OSV_JSON_REPORT")
	echo -e "\n total unique vulnerabilities found: $VULN_COUNT"
	jq -r '.results[]?.packages[]?.vulnerabilities[]?.id' "$OSV_JSON_REPORT" | sort -u
fi
