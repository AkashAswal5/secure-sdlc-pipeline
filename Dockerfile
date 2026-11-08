# pinned, reproducible scanner image for the secure-sdlc-pipeline.
# tools are pre-installed at TOOLS_WORKSPACE (/opt/tools) so the pipeline's
# install steps detect them and skip - every run uses identical tool versions.
#
# build:  docker build -t secure-sdlc-pipeline .
# run:    docker run --rm -v "$PWD/reports:/reports" secure-sdlc-pipeline <git-url-or-local-dir>
#
# bump the ARG versions deliberately and re-verify, do not float them

FROM python:3.12-slim

# pin tool versions (validate these before bumping - releases change frequently)
ARG SEMGREP_VERSION=1.52.0
ARG CHECKOV_VERSION=3.2.341
ARG GITLEAKS_VERSION=8.18.2
ARG OSV_SCANNER_VERSION=1.7.0
ARG TRIVY_VERSION=0.50.0

RUN apt-get update && apt-get install -y --no-install-recommends \
        git jq curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV TOOLS_WORKSPACE=/opt/tools \
    WORKSPACE=/workspace \
    REPORT_DIR=/reports

# python tools (semgrep, checkov) in the venv the pipeline expects
RUN python -m venv "$TOOLS_WORKSPACE/myenv" \
    && "$TOOLS_WORKSPACE/myenv/bin/pip" install --no-cache-dir \
        "semgrep==${SEMGREP_VERSION}" \
        "checkov==${CHECKOV_VERSION}"

# binary tools into the pipeline's tools-workspace fallback dir
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    mkdir -p "$TOOLS_WORKSPACE/bin"; \
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${arch}.tar.gz" \
        | tar -xz -C "$TOOLS_WORKSPACE/bin" gitleaks; \
    curl -fsSL "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_${OSV_SCANNER_VERSION}_linux_${arch}.tar.gz" \
        | tar -xz -C "$TOOLS_WORKSPACE/bin" osv-scanner; \
    curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
        | tar -xz -C "$TOOLS_WORKSPACE/bin" trivy; \
    chmod +x "$TOOLS_WORKSPACE/bin"/*

WORKDIR /pipeline
COPY . /pipeline

ENTRYPOINT ["bash", "pipeline.sh"]
