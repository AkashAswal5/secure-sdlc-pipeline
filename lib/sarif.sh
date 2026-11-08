#!/bin/bash

# SARIF 2.1.0 output derived from the normalized findings (common shape), so
# every tool gets code-scanning-compatible SARIF from ONE scan pass - no
# second scan per format. upload these files (e.g. github/codeql-action/
# upload-sarif) and findings appear as inline PR annotations in code review.
#
# usage: findings_to_sarif <tool-name> <findings.json> <out.sarif>

findings_to_sarif() {
	local tool="$1" findings="$2" out="$3"
	jq --arg tool "$tool" '
		def level: {"Critical": "error", "High": "error", "Medium": "warning", "Low": "note", "Unknown": "note"}[.] // "note";
		# "path:line" locations and "target -> pkg@ver" dependency locations
		def file_part: ((.location // "?") | if test(" -> ") then split(" -> ")[0] else split(":")[0] end);
		def line_part: (if ((.location // "") | test(":[0-9]+$")) then (.location | split(":") | last | tonumber) else null end);
		{
			"$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
			version: "2.1.0",
			runs: [{
				tool: {driver: {
					name: $tool,
					rules: ([.[].id] | unique | map({id: .}))
				}},
				results: map(
					{
						ruleId: .id,
						level: (.severity | level),
						message: {text: ((.title // .id) + " [" + .severity + "]")},
						fingerprints: {"primary/location": .fingerprint},
						partialFingerprints: {"secureSdlcPipeline/primary": .fingerprint},
						properties: {
							category: .category,
							scanners: (.scanners // [.tool]),
							duplicate_count: (.duplicate_count // 0)
						},
						locations: [{
							physicalLocation: (
								{artifactLocation: {uri: file_part}}
								+ (if line_part then {region: {startLine: line_part}} else {} end)
							)
						}]
					}
				)
			}]
		}
	' "$findings" > "$out"
}
