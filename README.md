# Secure SDLC Pipeline 

- Phase 1: Semgrep — Static Application Security Testing (SAST)
- Phase 2: Gitleaks — Detect hardcoded secrets and credentials
- Phase 3: Checkov — Infrastructure as Code (IaC) security scanning
- Phase 4: OSV-Scanner / Grype — Dependency vulnerability scanning
- Phase 5: Trivy — Container image vulnerability scanning
- Phase 6: Report Aggregation — Generate a unified security report
- Phase 7: GitHub Actions — Automate security scans in CI/CD
- Phase 8: CodeQL — Advanced semantic code analysis
- Phase 9: SBOM — Generate Software Bill of Materials
- Phase 10: Tekton — Kubernetes-native CI/CD security pipeline


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

