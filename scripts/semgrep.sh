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

set +e
"$SEMGREP_BIN" scan --config "$SEMGREP_RULES_CONFIG" "$WORKSPACE" --json --output "$REPORT_DIR/semgrep/semgrep_${TIMESTAMP}.json"
JSON_EXIT_CODE=$?

"$SEMGREP_BIN" scan --config "$SEMGREP_RULES_CONFIG" "$WORKSPACE"  --text --output "$REPORT_DIR/semgrep/semgrep_${TIMESTAMP}.txt"
TEXT_EXIT_CODE=$?
set -e

echo "Scan completed, Report generated in $REPORT_DIR"

if [ "$JSON_EXIT_CODE" -ne 0 ] || [ "$TEXT_EXIT_CODE" -ne 0 ]; then
  echo "semgrep issue found, json exit code: $JSON_EXIT_CODE, text exit code: $TEXT_EXIT_CODE"
else
  echo "no issue found"
fi

# filter out the result


# present result in various format, like json, txt, 

# save result 

 
