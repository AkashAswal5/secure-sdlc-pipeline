# Tekton: kubernetes-native secure SDLC pipeline (phase 11)

Runs the same pinned scanner image as CI and local Docker, but as Tekton
resources on a Kubernetes cluster. The pipeline is: **clone → scan → gate** —
when the scan task finds new findings it exits non-zero, the task fails, and
the PipelineRun shows `Failed`. That is the k8s-native equivalent of the
GitHub Actions gate.

## Setup

```bash
# 1. Tekton Pipelines must be installed on the cluster
#    https://tekton.dev/docs/pipelines/install/
kubectl apply -f tekton/tasks/task-git-clone.yaml
kubectl apply -f tekton/tasks/task-security-scan.yaml
kubectl apply -f tekton/pipeline.yaml

# 2. build and push the pinned scanner image to a registry the cluster can pull
docker build -t <registry>/secure-sdlc-pipeline:v0.2.0 .
docker push <registry>/secure-sdlc-pipeline:v0.2.0

# 3. run it (point `image` at your registry)
kubectl apply -f tekton/pipelinerun-example.yaml
kubectl get pipelinerun secure-sdlc-run-example -w
```

## Notes

- **Image** — the scan task runs the `Dockerfile` image (all five scanners
  pinned, non-root `scanner` user). Override per run with the `image` param.
- **Gate semantics** — identical to CI: findings already in
  `reports/baseline.json` pass, new findings fail. Refresh the baseline with
  `extra-args: "--baseline"` (the committed baseline workflow equivalent).
- **Reports** — land on the `reports` workspace (unified reports, SARIF,
  SBOM). The example uses a `volumeClaimTemplate`; swap for a shared PVC or a
  bucket-backed workspace to keep history.
- **Skipping scanners** — `skip-tools` defaults to `codeql`: the ~400MB bundle
  is rarely worth it in-cluster unless the target repo has supported languages.
- **Clone depth** — full clone on purpose: gitleaks scans git history.
