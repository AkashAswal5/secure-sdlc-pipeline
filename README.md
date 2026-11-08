# Secure SDLC Pipeline 

- Phase 1: Semgrep — Static Application Security Testing (SAST)
- Phase 2: Gitleaks — Detect hardcoded secrets and credentials
- Phase 3: Checkov — Infrastructure as Code (IaC) security scanning
- Phase 4: OSV-Scanner / Grype — Dependency vulnerability scanning
- Phase 5: Trivy — Container image vulnerability scanning
- Phase 6: Report Aggregation — Generate a unified security report
- Phase 7: Pipeline hardening — local-folder input, single-pass scans, multi-repo gitleaks, component breakdown
- Phase 8: Production readiness — SARIF output, CI integration, suppressions/baseline triage, dedup, parallel scans, pinned Docker image
- Phase 9: CodeQL — Advanced semantic code analysis
- Phase 10: SBOM — Generate Software Bill of Materials
- Phase 11: Tekton — Kubernetes-native CI/CD security pipeline

---

## How to run

```bash
# scan a remote repo
./pipeline.sh https://github.com/user/repo

# scan a local git repo (clones it, keeps history for the gitleaks git scan)
# or a plain folder (copies it)
./pipeline.sh /path/to/repo

# scan a container image instead of / in addition to the repo filesystem
./pipeline.sh <url-or-dir> --image nginx:1.25

# other flags
#   --pm <pacman|brew|apt|dnf|apk>   non-interactive package manager (CI)
#   --baseline                       record current findings as the baseline
#   --serial                         run scans one-by-one instead of parallel (debugging)

# env overrides (REPORT_DIR default is /tmp/reports - macOS purges /tmp)
REPORT_DIR="$HOME/reports" WORKSPACE="$HOME/ws" ./pipeline.sh <url-or-dir>
```

### Where the output lands (`$REPORT_DIR`)

| Path | What it shows |
| --- | --- |
| `unified/unified_report_<TS>.md` | executive report: verdict, triage (new/known/suppressed), category + severity summary, findings by component, top offenders, critical findings |
| `unified/unified_report_<TS>.json` | machine readable: metadata (incl. scanner versions), summary, all normalized findings, suppressed findings |
| `unified/secrets_findings_<TS>.md` / `.json` | **every hardcoded secret**: rule, `file:line`, a masked preview (first 8 chars only — full values never land in reports), and for history finds the commit + author |
| `unified/dependency_findings_<TS>.md` | vulnerable packages grouped with advisories, worst severity, which scanners reported them |
| `unified/code_findings_<TS>.md`, `unified/api_findings_<TS>.md`, `unified/infrastructure_findings_<TS>.md` | per-category findings tables |
| `sarif/<tool>.sarif` | SARIF 2.1.0 per tool — upload to GitHub code scanning for inline PR annotations |
| `gitleaks/`, `semgrep/`, `checkov/`, `osv-scanner/`, `trivy/` | raw per-tool reports (the gitleaks json keeps full secret values — handle it accordingly) |

The pipeline exit code gates CI: 0 = no new findings, 1 = new findings detected.

### CI + Docker

- `.github/workflows/security.yml` runs the pipeline on every PR/push, uploads SARIF to code scanning (findings appear as inline PR annotations) and gates on **new** findings only. Dispatch it once with `write_baseline=true` to commit the initial `baseline.json`.
- `docker build -t secure-sdlc-pipeline . && docker run --rm -v "$PWD/reports:/reports" secure-sdlc-pipeline <url-or-dir>` — pinned tool versions, identical scanners every run.

---
### references
- checkov: https://www.checkov.io/1.Welcome/What%20is%20Checkov.html
Checkov scans these IaC file types:
    - Terraform (for AWS, GCP, Azure and OCI)
    - CloudFormation (including AWS SAM)
    - Azure Resource Manager (ARM)
    - Serverless framework
    - Helm charts
    - Kubernetes
    - Docker

- osv-scanner: https://google.github.io/osv-scanner/
OSV-Scanner scans dependency lockfiles / manifests against the OSV database:
    - Lockfiles (package-lock.json, requirements.txt, poetry.lock, go.sum, etc.)
    - SBOMs (SPDX, CycloneDX)
    - Git directories

- trivy: https://trivy.dev/
Trivy scans containers and filesystems:
    - Container images (`./pipeline.sh <url> --image <name>`)
    - Filesystem (dependency vulns + misconfigurations in the repo)
    - Git repos, SBOMs, Kubernetes

- report aggregation: all tool reports are merged into one unified report in `$REPORT_DIR/unified/`:
    - `unified_report_<TS>.json` — machine readable (metadata, summary, all normalized findings)
    - `unified_report_<TS>.md` — human readable executive report (verdict, category/severity summary, top offenders, critical findings, links to category files)
    - pipeline exits non-zero (FAIL verdict) when any tool found issues
    - findings are also split into one json + markdown file pair per category (locations are repo-relative, dependency findings grouped by package):
        - `secrets_findings_<TS>` — hardcoded credentials (gitleaks)
        - `dependency_findings_<TS>` — library / package vulnerabilities (osv-scanner, trivy CVE/GHSA)
        - `api_findings_<TS>` — findings in API route code (src/app/api/**)
        - `code_findings_<TS>` — other application code findings (semgrep)
        - `infrastructure_findings_<TS>` — IaC / Docker / CI-CD / package-manager config findings (checkov, trivy misconfig, semgrep yaml/bash/npm rules)

- phase 8 — production readiness:
    - **parallel scans**: the 5 scan scripts run concurrently (installs stay sequential); `--serial` disables this for debugging
    - **dedup**: the same finding reported by multiple scanners (e.g. trivy + osv-scanner on the same advisory) collapses into one entry with a `.scanners` list and the worst severity
    - **fingerprints**: every finding gets a stable fingerprint `<tool> | <rule-id> | <file>` (no line number — lines drift between commits)
    - **suppressions** (`config/suppressions.json`, override with `SUPPRESSIONS_FILE`):
        ```json
        {"suppressed": [
          {"fingerprint": "semgrep | python.lang.security.exec | lib/foo.py",
           "reason": "accepted risk, ticket SEC-123",
           "expires": "2027-01-01"}
        ]}
        ```
        suppressed findings move to a separate report section and never fail the gate; expired entries automatically re-alert
    - **baseline**: `./pipeline.sh <repo> --baseline` records the current active findings in `$BASELINE_FILE` (default `$REPORT_DIR/baseline.json`, override with `BASELINE_FILE`); later runs only fail the gate on **new** findings — the adoption path for brownfield repos
    - **SARIF 2.1.0**: `$REPORT_DIR/sarif/<tool>.sarif` derived from the normalized findings (still one scan pass per tool) — upload to GitHub code scanning and findings appear as inline PR annotations
    - **scanner versions** are recorded in the unified report metadata (auditable reports)
    - **CI**: `.github/workflows/security.yml` runs the pipeline on every PR/push, uploads SARIF to code scanning, and gates on new findings only; dispatch it once with `write_baseline=true` to commit the initial `baseline.json`
    - **pinned image**: `docker build -t secure-sdlc-pipeline .` pre-installs pinned tool versions at `/opt/tools` (see `Dockerfile` ARGs) so every run uses identical scanner versions

