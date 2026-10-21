set -e

source config/env.sh
source lib/install.sh
# install osv-scanner

ensure_pm
check_sudo
install_tools_workspace
check_report_dir "$REPORT_DIR/osv-scanner"

install_jq

echo "installing OSV-Scanner"

install_osv_scanner

OSV_BIN=$(resolve_osv_scanner)
if [ -z "$OSV_BIN" ]; then
	echo "osv-scanner installation failed"
	exit 1
fi

OSV_VERSION=$("$OSV_BIN" --version)
echo "OSV-Scanner install successfully: $OSV_VERSION"
