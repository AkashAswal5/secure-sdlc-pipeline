#!/bin/bash

set -euo pipefail
# -e exit on error
# -u undefine variable become error
# -o pipefail detect failure inside pipelines

source config/env.sh

echo "starting scan on directory $WORKSPACE"

echo "Running Trivy .............."

if [ ! -d "$WORKSPACE" ]; then
	echo "workspace not found: $WORKSPACE"
	exit 1
fi

# find trivy: PATH first, then tools-workspace binary (github release fallback)
if command -v trivy >/dev/null 2>&1; then
	TRIVY_BIN=$(command -v trivy)
elif [ -x "$TOOLS_WORKSPACE/bin/trivy" ]; then
	TRIVY_BIN="$TOOLS_WORKSPACE/bin/trivy"
else
	echo "trivy not found"
	exit 1
fi

TRIVY_JSON_REPORT="$REPORT_DIR/trivy/trivy_${TIMESTAMP}.json"
TRIVY_TXT_REPORT="$REPORT_DIR/trivy/trivy_${TIMESTAMP}.txt"

# mode 1: scan a container image when SCAN_IMAGE is set (via ./pipeline.sh --image <name>)
# mode 2: scan the workspace filesystem for dependency vulns and misconfigurations
# --exit-code 1: exit 1 when findings exist (0 = no findings)
set +e
if [ -n "${SCAN_IMAGE:-}" ]; then
	echo "scanning image: $SCAN_IMAGE"
	"$TRIVY_BIN" image --exit-code 1 --format json --output "$TRIVY_JSON_REPORT" "$SCAN_IMAGE"
	TRIVY_JSON_EXIT_CODE=$?
	"$TRIVY_BIN" image --exit-code 1 --format table --output "$TRIVY_TXT_REPORT" "$SCAN_IMAGE"
	TRIVY_TXT_EXIT_CODE=$?
else
	"$TRIVY_BIN" fs --scanners vuln,misconfig --exit-code 1 --format json --output "$TRIVY_JSON_REPORT" "$WORKSPACE"
	TRIVY_JSON_EXIT_CODE=$?
	"$TRIVY_BIN" fs --scanners vuln,misconfig --exit-code 1 --format table --output "$TRIVY_TXT_REPORT" "$WORKSPACE"
	TRIVY_TXT_EXIT_CODE=$?
fi
set -e

echo "Scan completed, Report generated in $REPORT_DIR/trivy"

# record the report path for the aggregator (phase 6)
if [ -s "$TRIVY_JSON_REPORT" ]; then
	mkdir -p "$REPORT_DIR"
	echo "trivy|$TRIVY_JSON_REPORT" >> "$RUN_MANIFEST"
fi

if [ "$TRIVY_JSON_EXIT_CODE" -eq 0 ] && [ "$TRIVY_TXT_EXIT_CODE" -eq 0 ]; then
	echo "no issue found"
else
	echo "trivy issue found, json exit code: $TRIVY_JSON_EXIT_CODE, txt exit code: $TRIVY_TXT_EXIT_CODE"
fi

echo -e "............. summary of trivy .............."
if command -v jq >/dev/null 2>&1 && [ -s "$TRIVY_JSON_REPORT" ]; then
	VULN_COUNT=$(jq -r '[.Results[]?.Vulnerabilities[]?.VulnerabilityID] | unique | length' "$TRIVY_JSON_REPORT")
	MISCONFIG_COUNT=$(jq -r '[.Results[]?.Misconfigurations[]?.ID] | unique | length' "$TRIVY_JSON_REPORT")
	echo -e "\n total unique vulnerabilities: $VULN_COUNT & misconfigurations: $MISCONFIG_COUNT"
	jq -r '.Results[]?.Vulnerabilities[]?.VulnerabilityID' "$TRIVY_JSON_REPORT" | sort -u
fi
