#!/bin/bash

# REPO_URL
WORKSPACE="/tmp/workspace"
#REPORT_DIR="$HOME/reports"
REPORT_DIR="/tmp/reports"
TOOLS_WORKSPACE="/tmp/cyber_tools/semgrep-workspace"
# TOOLS_WORKSPACE="$HOME/cyber_tools/semgrep-workspace"
VENV_DIR="$TOOLS_WORKSPACE/myenv"
PACKAGE_MANAGER="pacman -S"
TIMESTAMP=$(date +"20%y_%m_%d_%H:%M:%S")

SEMGREP_RULES_CONFIG="auto"

