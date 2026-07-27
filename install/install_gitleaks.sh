set -e

source config/env.sh
source lib/install.sh
# install gitleaks

install_tools_workspace
check_report_dir "$REPORT_DIR/gitleaks"

echo "installing Gitleaks"

install_gitleaks

GITLEAKS_VERSION=$(gitleaks version)
echo "Semgrep install successfully: $GITLEAKS_VERSION"


