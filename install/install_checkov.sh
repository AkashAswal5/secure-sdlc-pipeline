#!/bin/bash
set -e
# References: https://www.checkov.io/2.Basics/Installing%20Checkov.html
source config/env.sh
source lib/install.sh

#install checkov
install_tools_workspace
check_report_dir "$REPORT_DIR/checkov"

install_python3
create_virtual_environment
source "$VENV_DIR/bin/activate"

echo -e "\n installing Dependencies \n "

install_checkov

CHEVKOV_VERSION=$(semgrep --version)
echo -e "\n checkov install successfully: $CHECKOV_VERSION \n"

