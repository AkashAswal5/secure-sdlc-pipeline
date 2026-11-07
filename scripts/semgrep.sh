#!/bin/bash

set -euo pipefail
 # -e  Exit on error
 # -u  Undefined variables become errors
 # -o pipefail  Detect failures inside pipelines

source config/env.sh
SEMGREP_RULES_CONFIG="${SEMGREP_RULES:-auto}"

echo "starting scan on directory $WORKSPACE"
echo "using rules: $SEMGREP_RULES_CONFIG"

source "$VENV_DIR/bin/activate"
# run Scan
echo "Running static analysis"

SEMGREP_JSON_REPORT="$REPORT_DIR/semgrep/semgrep_${TIMESTAMP}.json"
SEMGREP_TXT_REPORT="$REPORT_DIR/semgrep/semgrep_${TIMESTAMP}.txt"
mkdir -p "$REPORT_DIR/semgrep"

# semgrep may exit non-zero on errors, capture exit code manually
# single scan pass: json output, text report is derived from it (avoids a second full scan)
set +e
"$SEMGREP_BIN" scan --config "$SEMGREP_RULES_CONFIG" "$WORKSPACE" --json --output "$SEMGREP_JSON_REPORT"
JSON_EXIT_CODE=$?
set -e

# derive the human-readable text report from the json report (local, fast)
if [ -s "$SEMGREP_JSON_REPORT" ]; then
	{
		echo "semgrep scan of $WORKSPACE"
		echo "rules: $SEMGREP_RULES_CONFIG"
		echo "findings: $(jq '[.results[]?] | length' "$SEMGREP_JSON_REPORT")"
		echo
		jq -r '.results[]? |
			"- [\(.extra.severity // "?")] \(.check_id // "?")  \(.path // "?"):\(.start.line // 0)\n  \(.extra.message // "")"' \
			"$SEMGREP_JSON_REPORT"
	} > "$SEMGREP_TXT_REPORT"
fi

# record the report path for the aggregator (phase 6)
if [ -s "$SEMGREP_JSON_REPORT" ]; then
	mkdir -p "$REPORT_DIR"
	echo "semgrep|$SEMGREP_JSON_REPORT" >> "$RUN_MANIFEST"
fi

echo "Scan completed, Report generated in $REPORT_DIR"

if [ "$JSON_EXIT_CODE" -ne 0 ]; then
  echo "semgrep issue found, json exit code: $JSON_EXIT_CODE"
else
  echo "no issue found"
fi

# filter out the result


# present result in various format, like json, txt, 

# save result 

 
