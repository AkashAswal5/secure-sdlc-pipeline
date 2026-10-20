set -e
# make a robust pipeline that should not fail under any condition
source config/env.sh
source lib/install.sh
# install semgrep

ensure_pm
check_sudo
install_tools_workspace
check_report_dir "$REPORT_DIR/semgrep"

install_python3
create_virtual_environment
source "$VENV_DIR/bin/activate"

check_pip

echo -e "\n installing Dependencies \n "

install_semgrep

SEMGREP_VERSION=$(semgrep --version)
echo -e "\n Semgrep install successfully: $SEMGREP_VERSION \n"
