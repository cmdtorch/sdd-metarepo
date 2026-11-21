#!/usr/bin/env bash
# Checks the agent files in the root (part of mise run lint):
# - the root has no CLAUDE.md, CLAUDE.local.md or .claude/CLAUDE.md: any of them
#   stops Claude Code from reading AGENTS.md (docs/adr/0002-only-agents-md.md);
# - every relative link in AGENTS.md points to an existing file.
set -euo pipefail

failed=0
for file in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do
	if [ -e "$file" ]; then
		echo "$file: not allowed in the root, agent rules live only in AGENTS.md (docs/adr/0002-only-agents-md.md)"
		failed=1
	fi
done

if [ ! -f AGENTS.md ]; then
	echo "AGENTS.md: file is missing"
	exit 1
fi
while read -r link; do
	target="${link%%#*}"
	[ -n "$target" ] || continue
	if [ ! -e "$target" ]; then
		echo "AGENTS.md: link to a missing file: $target"
		failed=1
	fi
done < <(grep -oE '\]\([^)[:space:]]+\)' AGENTS.md | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^([a-z]+:|#)' || true)

exit "$failed"
