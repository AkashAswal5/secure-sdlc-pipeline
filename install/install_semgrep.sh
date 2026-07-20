set -e
# make a robust pipeline that should not fail under any condition
source config/env.sh
source lib/install.sh
# install semgrep 

install_tools_workspace()
check_REPORT_DIR "$REPORT_DIR/semgrep"

install_python3 ()
create_virtual_environment()
source "$VENV_DIR/bin/activate"

echo "installing Dependencies"

install_semgrep()

SEMGREP_VERSION=$(semgrep --version)
echo "Semgrep install successfully: $SEMGREP_VERSION"

