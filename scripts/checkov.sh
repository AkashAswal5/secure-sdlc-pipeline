#!/bin/bash

set -euo
# -e exit on error
# -u undefine variable become error
# -o pipefall detect failure inside pipelines

source config/env.sh

# i have to make a script that will do a scan so what i need here
# workspace
echo "start running tool on Workspace: $WORKSPACE"

echo "Running Checkov .............."

if [ ! -d  "$WORKSPACE" ]; then
	echo "workspace not found"
	exit 1
fi

if ! command -v checkov >/dev/null 2>&1; then
	echo "checkov not found"
	exit 1
fi

CHECKOV_REPORT="$REPORT_DIR/checkov/checkov_${TIMESTAMP}.json"


# command to run this tool via script
# First i need to run this tool locally





