#!/bin/bash

source config/env.sh

# make sure PM vars are set when install scripts run directly (not via pipeline.sh)
ensure_pm() {
if [ -z "${PM_INSTALL_CMD:-}" ]; then
  source lib/pm.sh
  if [ -n "${PACKAGE_MANAGER:-}" ]; then
    pm_config "$PACKAGE_MANAGER" || exit 1
    pm_export
  else
    select_package_manager_auto
  fi
fi
}

install_tools_workspace() {
if [ ! -d "$TOOLS_WORKSPACE" ]; then
  mkdir -p "$TOOLS_WORKSPACE"
else
  echo " $TOOLS_WORKSPACE exist"
fi
}

check_report_dir() {
if [ ! -d "$1" ] ; then
   mkdir -p "$1"
else
   echo "$1 exist"
fi
}

# install a package with the selected package manager, sudo only when needed
pkg_install() {
  if [ "$PM_NEEDS_SUDO" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    sudo $PM_INSTALL_CMD "$1"
  else
    $PM_INSTALL_CMD "$1"
  fi
}

# sudo is required by pacman/apt/dnf/apk, not by brew; root never needs sudo
check_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    echo "running as root, sudo not needed"
    return 0
  fi
  if [ "$PM_NEEDS_SUDO" -eq 1 ] && ! command -v sudo >/dev/null 2>&1; then
    echo "error: $PACKAGE_MANAGER needs root privileges to install packages, but sudo is not available."
    echo "run as root or install sudo first."
    exit 1
  fi
  echo "sudo check passed"
}

# pip check: works for system pip and venv pip (call after venv activation for venv pip)
check_pip() {
  if python3 -m pip --version >/dev/null 2>&1; then
    echo "pip is available"
    return 0
  fi
  echo "pip is missing"
  if [ -n "$PM_PIP_PKG" ]; then
    pkg_install "$PM_PIP_PKG"
  fi
  if python3 -m pip --version >/dev/null 2>&1; then
    echo "pip installed successfully"
    return 0
  fi
  echo "error: pip is still unavailable"
  return 1
}

# install python3 if it is not there or cannot create venv (e.g. debian needs python3-venv)
install_python3() {
  local venv_test="$TOOLS_WORKSPACE/.venv_check"
  if command -v python3 >/dev/null 2>&1 && python3 -m venv "$venv_test" >/dev/null 2>&1; then
    rm -rf "$venv_test"
    return 0
  fi
  rm -rf "$venv_test"
  echo "python3 is missing or cannot create venv, installing $PM_PYTHON_PKG"
  pkg_install "$PM_PYTHON_PKG"
  if ! python3 -m venv "$venv_test" >/dev/null 2>&1; then
    rm -rf "$venv_test"
    if [ -n "$PM_VENV_PKG" ]; then
      echo "venv still broken, installing $PM_VENV_PKG"
      pkg_install "$PM_VENV_PKG"
    fi
  else
    rm -rf "$venv_test"
  fi
}

create_virtual_environment() {
# recreate the venv when missing OR broken (e.g. macOS purges /tmp contents,
# leaving the dir behind without bin/activate -> source would fail)
if [ ! -f "$VENV_DIR/bin/activate" ] ; then
   echo "Creating Virtual environment"
   rm -rf "$VENV_DIR"
   python3 -m venv "$VENV_DIR"
fi
}

install_semgrep() {
if ! command -v semgrep >/dev/null 2>&1; then
  echo "install semgrep"
  pip install semgrep
else
  echo "semgrep already installed ($(command -v semgrep)), skipping install"
fi
}

# find the gitleaks binary: PATH first, then our tools-workspace fallback location
resolve_gitleaks() {
  if command -v gitleaks >/dev/null 2>&1; then
    command -v gitleaks
  elif [ -x "$TOOLS_WORKSPACE/bin/gitleaks" ]; then
    echo "$TOOLS_WORKSPACE/bin/gitleaks"
  else
    echo ""
  fi
}

# gitleaks is not in apt/dnf/apk repos: download the official binary from github releases
install_gitleaks_binary() {
  local bin_dir="$TOOLS_WORKSPACE/bin"
  mkdir -p "$bin_dir"
  local arch tag tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "unsupported architecture for gitleaks binary: $(uname -m)"
      exit 1
      ;;
  esac
  tag=$(curl -sIL -o /dev/null -w '%{url_effective}' https://github.com/gitleaks/gitleaks/releases/latest | sed 's|.*/tag/||')
  if [ -z "$tag" ] || [ "$tag" = "latest" ]; then
    echo "failed to resolve latest gitleaks release tag"
    exit 1
  fi
  # release asset filenames omit the leading "v" of the tag (v8.30.1 -> gitleaks_8.30.1_...)
  local ver="${tag#v}"
  tmp=$(mktemp -d)
  echo "downloading gitleaks $tag (linux $arch)"
  if ! curl -fsSL -o "$tmp/gitleaks.tar.gz" "https://github.com/gitleaks/gitleaks/releases/download/${tag}/gitleaks_${ver}_linux_${arch}.tar.gz"; then
    echo "gitleaks download failed (no release asset for $tag linux $arch)"
    rm -rf "$tmp"
    exit 1
  fi
  tar -xzf "$tmp/gitleaks.tar.gz" -C "$tmp"
  mv "$tmp/gitleaks" "$bin_dir/gitleaks"
  chmod +x "$bin_dir/gitleaks"
  rm -rf "$tmp"
  echo "gitleaks binary installed at $bin_dir/gitleaks"
}

install_gitleaks() {
  # already on PATH or in the tools-workspace fallback dir -> skip
  if [ -n "$(resolve_gitleaks)" ]; then
    echo "gitleaks already installed at $(resolve_gitleaks), skipping install"
    return 0
  fi
  case "$PACKAGE_MANAGER" in
    pacman|brew)
      echo "installing gitleaks via $PACKAGE_MANAGER"
      pkg_install gitleaks
      ;;
    *)
      echo "gitleaks not available in $PACKAGE_MANAGER, using binary download fallback"
      install_gitleaks_binary
      ;;
  esac
}

install_checkov() {
if ! command -v checkov >/dev/null 2>&1; then
  echo "installing checkov"
  pip3 install checkov
else
  echo "checkov already installed ($(command -v checkov)), skipping install"
fi
}

# find the osv-scanner binary: PATH first, then our tools-workspace fallback location
resolve_osv_scanner() {
  if command -v osv-scanner >/dev/null 2>&1; then
    command -v osv-scanner
  elif [ -x "$TOOLS_WORKSPACE/bin/osv-scanner" ]; then
    echo "$TOOLS_WORKSPACE/bin/osv-scanner"
  else
    echo ""
  fi
}

# osv-scanner is a single go binary: brew ships it, others get the official binary from github releases
install_osv_scanner_binary() {
  local bin_dir="$TOOLS_WORKSPACE/bin"
  mkdir -p "$bin_dir"
  local os arch tag
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *)
      echo "unsupported OS for osv-scanner binary: $(uname -s)"
      exit 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "unsupported architecture for osv-scanner binary: $(uname -m)"
      exit 1
      ;;
  esac
  tag=$(curl -sIL -o /dev/null -w '%{url_effective}' https://github.com/google/osv-scanner/releases/latest | sed 's|.*/tag/||')
  if [ -z "$tag" ] || [ "$tag" = "latest" ]; then
    echo "failed to resolve latest osv-scanner release tag"
    exit 1
  fi
  echo "downloading osv-scanner $tag ($os $arch)"
  curl -sL -o "$bin_dir/osv-scanner" "https://github.com/google/osv-scanner/releases/download/${tag}/osv-scanner_${os}_${arch}"
  chmod +x "$bin_dir/osv-scanner"
  echo "osv-scanner binary installed at $bin_dir/osv-scanner"
}

install_osv_scanner() {
  # already on PATH or in the tools-workspace fallback dir -> skip
  if [ -n "$(resolve_osv_scanner)" ]; then
    echo "osv-scanner already installed at $(resolve_osv_scanner), skipping install"
    return 0
  fi
  case "$PACKAGE_MANAGER" in
    brew)
      echo "installing osv-scanner via brew"
      pkg_install osv-scanner
      ;;
    *)
      echo "osv-scanner not available in $PACKAGE_MANAGER, using binary download fallback"
      install_osv_scanner_binary
      ;;
  esac
}

# find the trivy binary: PATH first, then our tools-workspace fallback location
resolve_trivy() {
  if command -v trivy >/dev/null 2>&1; then
    command -v trivy
  elif [ -x "$TOOLS_WORKSPACE/bin/trivy" ]; then
    echo "$TOOLS_WORKSPACE/bin/trivy"
  else
    echo ""
  fi
}

# trivy is a single go binary: pacman/brew ship it, others get the official binary from github releases
install_trivy_binary() {
  local bin_dir="$TOOLS_WORKSPACE/bin"
  mkdir -p "$bin_dir"
  local os arch tag version tmp
  case "$(uname -s)" in
    Linux) os="Linux" ;;
    Darwin) os="macOS" ;;
    *)
      echo "unsupported OS for trivy binary: $(uname -s)"
      exit 1
      ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="64bit" ;;
    aarch64|arm64) arch="ARM64" ;;
    *)
      echo "unsupported architecture for trivy binary: $(uname -m)"
      exit 1
      ;;
  esac
  tag=$(curl -sIL -o /dev/null -w '%{url_effective}' https://github.com/aquasecurity/trivy/releases/latest | sed 's|.*/tag/||')
  if [ -z "$tag" ] || [ "$tag" = "latest" ]; then
    echo "failed to resolve latest trivy release tag"
    exit 1
  fi
  version="${tag#v}"
  tmp=$(mktemp -d)
  echo "downloading trivy $version ($os $arch)"
  curl -sL -o "$tmp/trivy.tar.gz" "https://github.com/aquasecurity/trivy/releases/download/${tag}/trivy_${version}_${os}-${arch}.tar.gz"
  tar -xzf "$tmp/trivy.tar.gz" -C "$tmp"
  mv "$tmp/trivy" "$bin_dir/trivy"
  chmod +x "$bin_dir/trivy"
  rm -rf "$tmp"
  echo "trivy binary installed at $bin_dir/trivy"
}

install_trivy() {
  # already on PATH or in the tools-workspace fallback dir -> skip
  if [ -n "$(resolve_trivy)" ]; then
    echo "trivy already installed at $(resolve_trivy), skipping install"
    return 0
  fi
  case "$PACKAGE_MANAGER" in
    pacman|brew)
      echo "installing trivy via $PACKAGE_MANAGER"
      pkg_install trivy
      ;;
    *)
      echo "trivy not available in $PACKAGE_MANAGER, using binary download fallback"
      install_trivy_binary
      ;;
  esac
}

install_jq() {
if ! command -v jq >/dev/null 2>&1; then
  echo "installing jq via $PACKAGE_MANAGER"
  pkg_install jq
fi
}
