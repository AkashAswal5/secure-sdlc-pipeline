#!/bin/bash

set -e
# make a robust pipeline that should not fail under any condition
source config/env.sh
# install semgrep 

if [ ! -d "$TOOLS_WORSPACE" ]; then
  mkdir -p "$TOOLS_WORKSPACE"
  cd "$TOOLS_WORKSPACE" 
fi

if [ ! -d "$REPORT_DIR" ] ; then
 mkdir -p "$REPORT_DIR/semgrep"
fi 

# install python3 if it is not there
if ! command -v python3 $>/dev/null; then
  echo "python3 is not there"
  # use system specif package manager tool
  sudo pacman -S python-pip
fi

# install dependencies
# sudo pacman -S --needed python-pip python-virtualenv

if [ ! -d "$VENV_DIR" ] ; then
  echo "Creating Virtual environment"
  python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

echo "installing Dependencies"

pip install --upgrade pip
pip install semgrep

SEMGREP_VERSION=$(semgrep --version)
echo "Semgrep install successfully: $SEMGREP_VERSION"

## make semgrep unv
# run semgrep on workspace

WORKSPACE="${1:-.}"
SEMGREP_RULES_CONFIG="${SEMGREP_RULES:-auto}"

echo "starting scan on directory $WORKSPACE"
echo "using rules: $SEMGREP_RULES_CONFIG"

# run Scan
echo "Running static analysis"

set +e 

semgrep scan --config "$SEMGREP_RULES_CONFIG" target "$WORKSPACE" --json --output "$REPORT_DIR/result_${TIMESTAMP}.json" --text --output "$REPORT_DIR/result_${TIMESTAMP}.txt"

SCAN_EXIT_CODE=$?
set -e

echo "Scan completed, Report generated in $REPORT_DIR"

if [ $SCAN_EXIT_CODE -ne 0 ]; then
  echo "semgrep issue found exit code: $SCAN_EXIT_CODE"
else
  echo "no issue found"
fi

deactivate

# filter out the result


# present result in various format, like json, txt, 

# save result 

 
