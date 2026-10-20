set -e

source config/env.sh
source lib/install.sh
# install gitleaks

ensure_pm
check_sudo
install_tools_workspace
check_report_dir "$REPORT_DIR/gitleaks"

install_jq

echo "installing Gitleaks"

install_gitleaks

GITLEAKS_BIN=$(resolve_gitleaks)
if [ -z "$GITLEAKS_BIN" ]; then
	echo "gitleaks installation failed"
	exit 1
fi

GITLEAKS_VERSION=$("$GITLEAKS_BIN" version)
echo "Gitleaks install successfully: $GITLEAKS_VERSION"
