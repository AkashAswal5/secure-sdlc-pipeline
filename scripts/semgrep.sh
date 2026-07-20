#!/bin/bash

set -euo pipefail
 # -e  Exit on error
 # -u  Undefined variables become errors
 # -o pipefail  Detect failures inside pipelines


source config/env.sh
SEMGREP_RULES_CONFIG="${SEMGREP_RULES:-auto}"

echo "starting scan on directory $WORKSPACE"
echo "using rules: $SEMGREP_RULES_CONFIG"

# run Scan
echo "Running static analysis"

semgrep scan --config "$SEMGREP_RULES_CONFIG" "$WORKSPACE" --json --output "$REPORT_DIR/semgrep_${TIMESTAMP}.json"

semgrep scan --config "$SEMGREP_RULES_CONFIG" "$WORKSPACE"  --text --output "$REPORT_DIR/semgrep_${TIMESTAMP}.txt"

SCAN_EXIT_CODE=$?

echo "Scan completed, Report generated in $REPORT_DIR"

if [ $SCAN_EXIT_CODE -ne 0 ]; then
  echo "semgrep issue found exit code: $SCAN_EXIT_CODE"
else
  echo "no issue found"
fi

# filter out the result


# present result in various format, like json, txt, 

# save result 

 
