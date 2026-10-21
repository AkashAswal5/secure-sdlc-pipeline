set -e

source config/env.sh
source lib/install.sh
# install trivy

ensure_pm
check_sudo
install_tools_workspace
check_report_dir "$REPORT_DIR/trivy"

install_jq

echo "installing Trivy"

install_trivy

TRIVY_BIN=$(resolve_trivy)
if [ -z "$TRIVY_BIN" ]; then
	echo "trivy installation failed"
	exit 1
fi

TRIVY_VERSION=$("$TRIVY_BIN" --version)
echo "Trivy install successfully: $TRIVY_VERSION"
