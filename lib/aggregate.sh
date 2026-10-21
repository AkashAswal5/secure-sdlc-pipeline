#!/bin/bash

source config/env.sh

# report discovery + per-tool normalizers
# every normalizer outputs ONE json array of findings in a common shape:
#   {tool, severity, id, title, location, description}
# severity scale: Critical / High / Medium / Low / Unknown

# ---- report discovery ----

# find the newest file matching a glob in a tool's report dir, empty string if none
find_latest_report() {
  local dir="$1" glob="$2"
  if [ -d "$dir" ]; then
    ls -t "$dir"/$glob 2>/dev/null | head -1 || true
  fi
  return 0
}

# checkov stores results inside a per-run directory: checkov_<TS>/results_json.json
find_latest_checkov_report() {
  local latest_dir
  latest_dir=$(ls -td "$REPORT_DIR"/checkov/checkov_* 2>/dev/null | head -1 || true)
  if [ -n "$latest_dir" ] && [ -f "$latest_dir/results_json.json" ]; then
    echo "$latest_dir/results_json.json"
  fi
  return 0
}

# resolve a tool's report path for this run:
# 1. run manifest (written by scan scripts, truncated by pipeline.sh at every run start)
# 2. fallback: newest report file per tool (legacy mode, standalone aggregate runs)
# outputs empty string when the tool did not run
manifest_lookup() {
  local tag="$1" path
  if [ -s "${RUN_MANIFEST:-}" ]; then
    path=$(grep "^$tag|" "$RUN_MANIFEST" | tail -1 | cut -d'|' -f2 || true)
  else
    case "$tag" in
      semgrep) path=$(find_latest_report "$REPORT_DIR/semgrep" 'semgrep_*.json') ;;
      gitleaks-git) path=$(find_latest_report "$REPORT_DIR/gitleaks" 'gitleaks_git_*.json') ;;
      gitleaks-dir) path=$(find_latest_report "$REPORT_DIR/gitleaks" 'gitleaks_dir_*.json') ;;
      checkov) path=$(find_latest_checkov_report) ;;
      osv-scanner) path=$(find_latest_report "$REPORT_DIR/osv-scanner" 'osv-scanner_*.json') ;;
      trivy) path=$(find_latest_report "$REPORT_DIR/trivy" 'trivy_*.json') ;;
    esac
  fi
  if [ -n "$path" ] && [ -f "$path" ]; then
    echo "$path"
  fi
  return 0
}

# ---- categorization ----
# every finding gets exactly one category:
#   secrets        - hardcoded credentials (gitleaks)
#   dependency     - library / package vulnerabilities (osv-scanner, trivy CVE/GHSA)
#   api            - findings in API route code (src/app/api/**)
#   code           - other application code findings (semgrep)
#   infrastructure - IaC / Docker / CI-CD / package-manager config findings (checkov, trivy misconfig, semgrep yaml/bash/npm rules)
# reads a findings array on stdin, writes it back with a .category field added
categorize_findings() {
  jq 'map(
    if .tool == "gitleaks" then .category = "secrets"
    elif .tool == "osv-scanner" then .category = "dependency"
    elif .tool == "trivy" and (.id | test("^(CVE|GHSA)")) then .category = "dependency"
    elif .tool == "trivy" then .category = "infrastructure"
    elif .tool == "checkov" then .category = "infrastructure"
    elif .tool == "semgrep" and ((.id | test("^(yaml|bash|package_managers)\\.")) or (.id | test("github-actions|docker-compose"))) then .category = "infrastructure"
    elif .tool == "semgrep" and ((.location // "") | contains("/src/app/api/")) then .category = "api"
    else .category = "code"
    end
  )'
}

# human readable title for a category
category_title() {
  case "$1" in
    secrets) echo "Hardcoded secrets" ;;
    dependency) echo "Dependency / library vulnerabilities" ;;
    api) echo "API route findings" ;;
    code) echo "Application code findings" ;;
    infrastructure) echo "Infrastructure / CI-CD / package findings" ;;
    *) echo "Findings" ;;
  esac
}

# make locations repo-relative: strip the workspace prefix so reports read
# "src/app/api/route.ts:42" instead of "/tmp/workspace/src/app/api/route.ts:42"
# reads a findings array on stdin, writes it back with .location rewritten
relativize_locations() {
  jq --arg ws "$WORKSPACE" 'map(
    .location |= (if startswith($ws + "/") then .[($ws | length) + 1:] else . end)
  )'
}

# ---- normalizers ----

# semgrep: results[].extra.severity is ERROR/WARNING/INFO -> High/Medium/Low
normalize_semgrep() {
  local report="$1"
  if [ -z "$report" ]; then echo "[]"; return 0; fi
  jq -c '[.results[]? | {
    tool: "semgrep",
    severity: ((.extra.severity // "WARNING") | ascii_downcase | {"error":"High","warning":"Medium","info":"Low"}[.] // "Medium"),
    id: (.check_id // "semgrep-finding"),
    title: (.extra.message // .check_id // "semgrep finding"),
    location: ((.path // "?") + ":" + ((.start.line // 0) | tostring)),
    description: (.extra.message // .check_id // "")
  }]' "$report"
}

# gitleaks: no severity concept, hardcoded secrets are always High
# merges the git-history and working-directory reports, dedupes id+location
normalize_gitleaks() {
  local git_report="$1" dir_report="$2" tmp_git tmp_dir
  if [ -z "$git_report" ] && [ -z "$dir_report" ]; then echo "[]"; return 0; fi
  tmp_git=$(mktemp); tmp_dir=$(mktemp)
  if [ -n "$git_report" ]; then
    jq -c '[.[]? | {
      tool: "gitleaks",
      severity: "High",
      id: (.RuleID // "gitleaks-finding"),
      title: (.Description // .RuleID // "hardcoded secret"),
      location: ((.File // "?") + ":" + ((.StartLine // 0) | tostring)),
      description: ((.Description // .RuleID // "") + " - found in git history")
    }]' "$git_report" > "$tmp_git" || echo "[]" > "$tmp_git"
  else
    echo "[]" > "$tmp_git"
  fi
  if [ -n "$dir_report" ]; then
    jq -c '[.[]? | {
      tool: "gitleaks",
      severity: "High",
      id: (.RuleID // "gitleaks-finding"),
      title: (.Description // .RuleID // "hardcoded secret"),
      location: ((.File // "?") + ":" + ((.StartLine // 0) | tostring)),
      description: ((.Description // .RuleID // "") + " - found in working directory")
    }]' "$dir_report" > "$tmp_dir" || echo "[]" > "$tmp_dir"
  else
    echo "[]" > "$tmp_dir"
  fi
  jq -s 'add // [] | unique_by(.id + "|" + .location)' "$tmp_git" "$tmp_dir"
  rm -f "$tmp_git" "$tmp_dir"
}

# checkov: array per framework, failed checks under results.failed_checks[]
# note: a report with zero scannable files is a bare object, not an array - handle both shapes
normalize_checkov() {
  local report="$1"
  if [ -z "$report" ]; then echo "[]"; return 0; fi
  jq -c '[
    (.results?.failed_checks[]?),
    (.[]? | select(type == "object") | .results?.failed_checks[]?) |
    {
      tool: "checkov",
      severity: ((.severity // "MEDIUM") | ascii_downcase | {"critical":"Critical","high":"High","medium":"Medium","low":"Low"}[.] // "Medium"),
      id: (.check_id // "checkov-finding"),
      title: (.check_name // .check_id // "checkov finding"),
      location: (((.file_path // "?") | ltrimstr("/")) + ":" + ((.file_line_range[0] // 0) | tostring)),
      description: ((.check_name // .check_id // "") + " - resource: " + (.resource // "n/a"))
    }
  ]' "$report"
}

# osv-scanner: results[].packages[].vulnerabilities[], no per-vuln severity in json output -> High
normalize_osv() {
  local report="$1"
  if [ -z "$report" ]; then echo "[]"; return 0; fi
  jq -c '[.results[]? | .source.path as $src | .packages[]? | .package.name as $name |
    (.package.version // "?") as $ver | .vulnerabilities[]? | {
    tool: "osv-scanner",
    severity: "High",
    id: (.id // "osv-vuln"),
    title: ("vulnerable dependency: " + $name + "@" + $ver),
    location: (($src // "?") + " -> " + $name + "@" + $ver),
    description: (.summary // .id // "")
  }]' "$report"
}

# trivy: vulnerabilities + misconfigurations under Results[]
normalize_trivy() {
  local report="$1"
  if [ -z "$report" ]; then echo "[]"; return 0; fi
  jq -c '[.Results[]? | .Target as $t |
    (.Vulnerabilities[]? | {
      tool: "trivy",
      severity: ((.Severity // "UNKNOWN") | ascii_downcase | {"critical":"Critical","high":"High","medium":"Medium","low":"Low"}[.] // "Unknown"),
      id: (.VulnerabilityID // "trivy-vuln"),
      title: ((.VulnerabilityID // "vuln") + " in " + (.PkgName // "?") + "@" + (.InstalledVersion // "?")),
      location: (($t // "?") + " -> " + (.PkgName // "?") + "@" + (.InstalledVersion // "?")),
      description: (.Title // .VulnerabilityID // "")
    }),
    (.Misconfigurations[]? | {
      tool: "trivy",
      severity: ((.Severity // "MEDIUM") | ascii_downcase | {"critical":"Critical","high":"High","medium":"Medium","low":"Low"}[.] // "Medium"),
      id: (.ID // "trivy-misconfig"),
      title: (.Title // .ID // "misconfiguration"),
      location: ($t // "?"),
      description: (.Message // .Title // "")
    })
  ]' "$report"
}
