set -e

source config/env.sh
source lib/install.sh
# install codeql (phase 9)

ensure_pm
check_sudo
install_tools_workspace
check_report_dir "$REPORT_DIR/codeql"

install_jq

echo "installing CodeQL CLI"

install_codeql

CODEQL_BIN=$(resolve_codeql)
if [ -z "$CODEQL_BIN" ]; then
	echo "codeql installation failed"
	exit 1
fi

CODEQL_VERSION=$("$CODEQL_BIN" version 2>/dev/null | head -1)
echo "CodeQL CLI install successfully: $CODEQL_VERSION"
