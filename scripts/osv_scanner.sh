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
mkdir -p "$REPORT_DIR/osv-scanner"

# exit codes: 0 = no vulnerabilities, 1 = vulnerabilities found, 2 = error
# single scan pass: json output, text report is derived from it (avoids a second
# full scan incl. slow remote dependency resolution)
set +e
"$OSV_BIN" scan source --recursive "$WORKSPACE" --format json --output-file "$OSV_JSON_REPORT"
OSV_JSON_EXIT_CODE=$?
set -e

# derive the human-readable text report from the json report (local, fast)
if [ -s "$OSV_JSON_REPORT" ]; then
	{
		echo "osv-scanner scan of $WORKSPACE"
		echo
		jq -r '.results[]? | .source.path as $src | .packages[]?
			| select((.vulnerabilities // []) | length > 0)
			| "source: \($src // "?")\n  package: \(.package.name // "?")@\(.package.version // "?")\n" +
				([.vulnerabilities[]?.id] | unique | map("    - \(.)") | join("\n")) + "\n"' \
			"$OSV_JSON_REPORT"
	} > "$OSV_TXT_REPORT"
fi

echo "Scan completed, Report generated in $REPORT_DIR/osv-scanner"

# record the report path for the aggregator (phase 6)
# no file is written when no package files were found (exit 128) -> tool shows as not_run
if [ -s "$OSV_JSON_REPORT" ]; then
	mkdir -p "$REPORT_DIR"
	echo "osv-scanner|$OSV_JSON_REPORT" >> "$RUN_MANIFEST"
fi

# exit codes: 0 = no vulnerabilities, 1 = vulnerabilities found, 2 = error, 128 = no package files found
if [ "$OSV_JSON_EXIT_CODE" -eq 128 ]; then
	echo "no package files (lockfiles) found in workspace, nothing to scan"
elif [ "$OSV_JSON_EXIT_CODE" -eq 0 ]; then
	echo "no issue found"
else
	echo "osv-scanner issue found, json exit code: $OSV_JSON_EXIT_CODE"
fi

echo -e "............. summary of osv-scanner .............."
if command -v jq >/dev/null 2>&1 && [ -s "$OSV_JSON_REPORT" ]; then
	VULN_COUNT=$(jq -r '[.results[]?.packages[]?.vulnerabilities[]?.id] | unique | length' "$OSV_JSON_REPORT")
	echo -e "\n total unique vulnerabilities found: $VULN_COUNT"
	jq -r '.results[]?.packages[]?.vulnerabilities[]?.id' "$OSV_JSON_REPORT" | sort -u
fi
