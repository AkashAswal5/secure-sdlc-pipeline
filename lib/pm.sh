#!/bin/bash

# package manager selection: prompt the user, auto-detect if only one exists,
# or take an override (--pm flag / PACKAGE_MANAGER env var)
# this file is SOURCED (not executed) so exports reach child scripts

SUPPORTED_PMS=(pacman brew apt dnf apk)

pm_config() {
	case "$1" in
		pacman)
			PM_INSTALL_CMD="pacman -S --noconfirm"
			PM_PYTHON_PKG="python"
			PM_PIP_PKG="python-pip"
			PM_VENV_PKG=""
			PM_NEEDS_SUDO=1
			;;
		brew)
			PM_INSTALL_CMD="brew install"
			PM_PYTHON_PKG="python"
			PM_PIP_PKG=""
			PM_VENV_PKG=""
			PM_NEEDS_SUDO=0
			;;
		apt)
			PM_INSTALL_CMD="apt install -y"
			PM_PYTHON_PKG="python3"
			PM_PIP_PKG="python3-pip"
			PM_VENV_PKG="python3-venv"
			PM_NEEDS_SUDO=1
			;;
		dnf)
			PM_INSTALL_CMD="dnf install -y"
			PM_PYTHON_PKG="python3"
			PM_PIP_PKG="python3-pip"
			PM_VENV_PKG=""
			PM_NEEDS_SUDO=1
			;;
		apk)
			PM_INSTALL_CMD="apk add"
			PM_PYTHON_PKG="python3"
			PM_PIP_PKG="py3-pip"
			PM_VENV_PKG=""
			PM_NEEDS_SUDO=1
			;;
		*)
			echo "unsupported package manager: $1 (supported: ${SUPPORTED_PMS[*]})"
			return 1
			;;
	esac
}

pm_export() {
	export PACKAGE_MANAGER PM_INSTALL_CMD PM_PYTHON_PKG PM_PIP_PKG PM_VENV_PKG PM_NEEDS_SUDO
}

detect_pms() {
	DETECTED_PMS=()
	local pm
	for pm in "${SUPPORTED_PMS[@]}"; do
		if command -v "$pm" >/dev/null 2>&1; then
			DETECTED_PMS+=("$pm")
		fi
	done
}

# non-interactive selection, used when install scripts run directly (not via pipeline.sh)
select_package_manager_auto() {
	if [ -n "${PACKAGE_MANAGER:-}" ]; then
		pm_config "$PACKAGE_MANAGER" || exit 1
	else
		detect_pms
		if [ "${#DETECTED_PMS[@]}" -eq 1 ]; then
			PACKAGE_MANAGER="${DETECTED_PMS[0]}"
			pm_config "$PACKAGE_MANAGER" || exit 1
		else
			echo "error: cannot pick a package manager automatically (${DETECTED_PMS[*]:-none found})"
			echo "run via ./pipeline.sh or set PACKAGE_MANAGER (pacman|brew|apt|dnf|apk)"
			exit 1
		fi
	fi
	pm_export
}

# selection used by pipeline.sh: override > auto-detect single > prompt
select_package_manager() {
	local override="${1:-${PACKAGE_MANAGER:-}}"

	if [ -n "$override" ]; then
		pm_config "$override" || exit 1
		PACKAGE_MANAGER="$override"
		echo "package manager (override): $PACKAGE_MANAGER"
		pm_export
		return 0
	fi

	detect_pms
	if [ "${#DETECTED_PMS[@]}" -eq 1 ]; then
		pm_config "${DETECTED_PMS[0]}" || exit 1
		PACKAGE_MANAGER="${DETECTED_PMS[0]}"
		echo "package manager (only one detected): $PACKAGE_MANAGER"
		pm_export
		return 0
	fi

	if [ "${#DETECTED_PMS[@]}" -eq 0 ]; then
		echo "no supported package manager found (${SUPPORTED_PMS[*]}), select manually"
	else
		echo "detected package managers: ${DETECTED_PMS[*]}"
	fi

	local choice pm i
	while true; do
		echo "Select package manager:"
		i=1
		for pm in "${SUPPORTED_PMS[@]}"; do
			echo "  $i) $pm"
			i=$((i + 1))
		done
		read -r -p "enter choice [1-${#SUPPORTED_PMS[@]}]: " choice
		case "$choice" in
			[1-"${#SUPPORTED_PMS[@]}"])
				break
				;;
			*)
				echo "invalid choice: $choice, try again"
				;;
		esac
	done

	PACKAGE_MANAGER="${SUPPORTED_PMS[$((choice - 1))]}"
	pm_config "$PACKAGE_MANAGER" || exit 1
	echo "package manager (selected): $PACKAGE_MANAGER"
	pm_export
}
