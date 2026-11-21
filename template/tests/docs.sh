#!/usr/bin/env bash
# Root documents and agent settings: structure that holds in every project language.
source "$META_ROOT/tests/lib.sh"

# Every file the template generated is free of template syntax (sdd-kit files left out).
test_no_template_syntax_left() {
	found="$(cd "$META_ROOT" && git ls-files -co --exclude-standard -z -- '*.md' '*.toml' '*.json' '*.yml' \
		':!openspec/' ':!.claude/commands/' ':!.claude/agents/' ':!.claude/skills/openspec-*' |
		xargs -0 grep -lE '\{\{|\{%|%\}' -- 2>/dev/null | grep -v '^\.copier-answers\.yml$' || true)"
	assert_eq "" "$found" "files with template syntax"
}

# Every generated section has its markers, once, in order.
test_generated_markers() {
	for spec in 'AGENTS.md|<!-- repos:begin:commands -->|<!-- repos:end:commands -->' \
		'AGENTS.md|<!-- repos:begin:branches -->|<!-- repos:end:branches -->' \
		'docs/agents/branches.md|<!-- repos:begin -->|<!-- repos:end -->' \
		'repos/README.md|<!-- repos:begin -->|<!-- repos:end -->' \
		'docs/agents/environment.md|<!-- repos:begin:env -->|<!-- repos:end:env -->' \
		'mise.toml|# repos:begin|# repos:end'; do
		IFS='|' read -r file begin end <<<"$spec"
		assert_eq 1 "$(grep -cxF -- "$begin" "$META_ROOT/$file")" "$file: one [$begin]"
		assert_eq 1 "$(grep -cxF -- "$end" "$META_ROOT/$file")" "$file: one [$end]"
		b="$(grep -nxF -- "$begin" "$META_ROOT/$file" | cut -d: -f1)"
		e="$(grep -nxF -- "$end" "$META_ROOT/$file" | cut -d: -f1)"
		[ "$b" -lt "$e" ] || fail "$file: [$begin] after [$end]"
	done
}

# [bootstrap.repos] is the last table of mise.toml, so nothing else falls into it.
test_bootstrap_table_is_last() {
	after="$(sed -n '/^# repos:end$/,$p' "$META_ROOT/mise.toml" | sed 1d | grep -vE '^\s*(#|$)' || true)"
	assert_eq "" "$after" "content after the generated section"
}

# Decision records keep their format: front matter with a status and at least three sections.
test_decision_record_format() {
	records=("$META_ROOT"/docs/adr/[0-9][0-9][0-9][0-9]-*.md)
	[ "${#records[@]}" -ge 4 ] || fail "fewer than four decisions: ${#records[@]}"
	for f in "${records[@]}"; do
		name="$(basename "$f")"
		assert_eq "---" "$(sed -n 1p "$f")" "$name starts with front matter"
		sed -n '2,/^---$/p' "$f" | grep -qE '^status: (accepted|superseded|proposed)' || fail "$name: no status"
		[ "$(grep -c '^## ' "$f")" -ge 2 ] || fail "$name: fewer than two sections"
	done
}

# The agent settings turn attribution off and register the git guard on Bash.
test_settings() {
	node -e '
		const s = require(process.argv[1]);
		const a = s.attribution || {};
		if (a.commit !== "" || a.pr !== "" || s.includeCoAuthoredBy !== false) process.exit(1);
		const ok = (s.hooks.PreToolUse || []).some((m) => m.matcher === "Bash" &&
			m.hooks.some((h) => h.command.includes(".claude/hooks/agent-git-guard.mjs")));
		process.exit(ok ? 0 : 2);' "$META_ROOT/.claude/settings.json" || fail ".claude/settings.json: attribution or hook entry"
}

# The skill has the front matter the agent needs to load it.
test_skill_front_matter() {
	f="$META_ROOT/.claude/skills/add-ast-grep-rule/SKILL.md"
	assert_eq "---" "$(sed -n 1p "$f")" "front matter"
	grep -qx 'name: add-ast-grep-rule' "$f" || fail "skill name"
	grep -qE '^description: .{40,}' "$f" || fail "skill description"
	f="$META_ROOT/.claude/skills/bootstrap/SKILL.md"
	assert_eq "---" "$(sed -n 1p "$f")" "bootstrap front matter"
	grep -qx 'name: bootstrap' "$f" || fail "bootstrap skill name"
	grep -qE '^description: .*/bootstrap' "$f" || fail "bootstrap skill description"
}

# The e2e/ folder exists exactly when AGENTS.md has the end-to-end section.
test_e2e_folder_matches_rules() {
	if grep -q '(e2e/README.md)' "$META_ROOT/AGENTS.md"; then
		assert_file "$META_ROOT/e2e/README.md"
	else
		assert_no_path "$META_ROOT/e2e"
	fi
}

# The core agent rules stay written down. The checked strings are commands, paths and names that are
# the same in every project language, so the test holds for English and Russian projects alike.
test_rules_written_down() {
	tracker="$(sed -nE "s/^tracker: *'?([a-z]+)'?/\\1/p" "$META_ROOT/.copier-answers.yml")"
	check_has() { # <file> <string...>
		local file="$1" t
		shift
		for t in "$@"; do
			grep -qF -- "$t" "$META_ROOT/$file" || fail "$file no longer mentions [$t]"
		done
	}
	# Planning in the root, branch rules, update before a task, the guard, clone hooks, backlog, checks.
	check_has AGENTS.md 'docs/adr/0003-planning-in-root-openspec.md' 'merge/<name>-into-' \
		'mise run pull' 'mise run status' '.claude/hooks/agent-git-guard.mjs' '--no-verify' \
		'docs/clone-backlog.md' 'add-ast-grep-rule' 'CLAUDE.local.md' 'mise run repos:sync' 'Conventional Commits'
	# Attribution ban, merge branches, no tracking of main, merges stay with the developer.
	check_has docs/agents/branches.md 'Co-Authored-By:' 'Generated with Claude Code' 'merge/' '--no-track' \
		'gh pr merge' 'Conventional Commits'
	# Personal opt-in for commit and push, kept out of git.
	check_has docs/agents/agent-settings.md 'METAREPO_AGENT_COMMIT=1' 'METAREPO_AGENT_PUSH=1' \
		'settings.local.json' 'gh pr merge'
	# Update before a task and the conditions for an automatic pull request.
	check_has docs/agents/ticket-workflow.md 'mise run pull' 'No upstream' 'METAREPO_AGENT_COMMIT' 'METAREPO_AGENT_PUSH'
	if [ "$tracker" != none ]; then
		# Ticket attachments and answers land in the change.
		check_has docs/agents/ticket-workflow.md 'clarifications.md' 'sources/'
		check_has AGENTS.md 'docs/agents/ticket-workflow.md'
	fi
}

# Every agent document is reachable from AGENTS.md.
test_agent_docs_linked() {
	for f in "$META_ROOT"/docs/agents/*.md; do
		name="docs/agents/$(basename "$f")"
		[ "$name" = docs/agents/README.md ] && continue
		grep -qF "($name)" "$META_ROOT/AGENTS.md" || fail "AGENTS.md does not link $name"
	done
}

run_tests
