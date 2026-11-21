#!/usr/bin/env bash
# The agent hook .claude/hooks/agent-git-guard.mjs: agent commit and push are off by
# default, turned on by personal settings, and always forbidden on main.
source "$META_ROOT/tests/lib.sh"

HOOK="$META_ROOT/.claude/hooks/agent-git-guard.mjs"

# An agent without personal settings: the permission variables are unset.
unset METAREPO_AGENT_COMMIT METAREPO_AGENT_PUSH

# A meta-repository with clones on branches: the root on main, the clones on feature/x.
# Sets ROOT, API_REMOTE.
make_meta() {
	ROOT="$PWD/meta"
	git init -q "$ROOT"
	git -C "$ROOT" commit -q --allow-empty -m root
	API_REMOTE="$(make_remote api)"
	WEB_REMOTE="$(make_remote web)"
	git clone -q --branch dev "$API_REMOTE" "$ROOT/repos/api"
	git clone -q --branch dev "$WEB_REMOTE" "$ROOT/repos/web"
	git -C "$ROOT/repos/api" checkout -qb feature/x
	git -C "$ROOT/repos/web" checkout -qb feature/x
}

# The hook's decision: guard <session folder> <command>. $DECISION is allow or deny,
# $REASON is the refusal text.
guard() {
	local input
	input="$(node -e 'console.log(JSON.stringify({hook_event_name: "PreToolUse", tool_name: "Bash", cwd: process.argv[1], tool_input: {command: process.argv[2]}}))' "$1" "$2")"
	local out err status=0
	err="$TEST_TMP/guard.err"
	out="$(cd "$1" && CLAUDE_PROJECT_DIR="$ROOT" node "$HOOK" <<<"$input" 2>"$err")" || status=$?
	[ "$status" -eq 0 ] || fail "hook exited with $status on [$2]: $(cat "$err")"
	[ ! -s "$err" ] || fail "hook wrote to stderr on [$2]: $(cat "$err")"
	REASON="$(node -e '
		const s = process.argv[1];
		if (!s.trim()) { console.log(""); process.exit(0); }
		const o = JSON.parse(s).hookSpecificOutput || {};
		console.log(o.permissionDecision === "deny" ? o.permissionDecisionReason : "");' "$out")"
	if [ -n "$REASON" ]; then DECISION=deny; else DECISION=allow; fi
}

# The hook allowed the command: run it the way the agent would.
run_allowed() { # <folder> <command>
	guard "$1" "$2"
	assert_eq allow "$DECISION" "hook allows [$2]: $REASON"
	(cd "$1" && eval "$2")
}

test_commit_refused_by_default() {
	make_meta
	guard "$ROOT/repos/api" 'git commit -m "feat: x"'
	assert_eq deny "$DECISION" "commit refused"
	assert_contains "$REASON" "METAREPO_AGENT_COMMIT" "message names the setting"
	assert_contains "$REASON" "commits are disabled" "message says commits are disabled"
	assert_contains "$REASON" ".claude/settings.local.json" "message names the settings file"
}

test_commit_in_root_refused_by_default() {
	make_meta
	git -C "$ROOT" checkout -qb docs/x
	guard "$ROOT" 'git commit -am "docs: x"'
	assert_eq deny "$DECISION" "commit in the root refused"
	assert_contains "$REASON" "METAREPO_AGENT_COMMIT"
}

test_commit_allowed_after_opt_in() {
	make_meta
	export METAREPO_AGENT_COMMIT=1
	echo change >"$ROOT/repos/api/file.txt"
	git -C "$ROOT/repos/api" add file.txt
	before="$(git -C "$ROOT/repos/api" rev-list --count HEAD)"
	run_allowed "$ROOT/repos/api" 'git commit -qm "feat: agent commit"'
	assert_eq "$((before + 1))" "$(git -C "$ROOT/repos/api" rev-list --count HEAD)" "commit made"
	assert_eq "feat: agent commit" "$(git -C "$ROOT/repos/api" log -1 --format=%s)" "commit message"
}

test_commit_via_git_c_refused() {
	make_meta
	guard "$ROOT" 'git -C repos/api commit -m x'
	assert_eq deny "$DECISION" "git -C commit refused"
	assert_contains "$REASON" "METAREPO_AGENT_COMMIT"
}

test_commit_after_cd_refused() {
	make_meta
	guard "$ROOT" 'cd repos/web && git commit -m x'
	assert_eq deny "$DECISION" "cd && git commit refused"
	assert_contains "$REASON" "METAREPO_AGENT_COMMIT"
}

test_setting_inside_command_ignored() {
	make_meta
	guard "$ROOT/repos/api" 'METAREPO_AGENT_COMMIT=1 git commit -m x'
	assert_eq deny "$DECISION" "a variable in the command does not allow a commit"
	assert_contains "$REASON" "METAREPO_AGENT_COMMIT"
	guard "$ROOT/repos/api" 'env METAREPO_AGENT_COMMIT=1 git commit -m x'
	assert_eq deny "$DECISION" "env in the command does not allow a commit"
	guard "$ROOT/repos/api" 'export METAREPO_AGENT_COMMIT=1; git commit -m x'
	assert_eq deny "$DECISION" "export in the command does not allow a commit"
}

test_push_refused_by_default() {
	make_meta
	guard "$ROOT/repos/web" 'git push origin feature/x'
	assert_eq deny "$DECISION" "push refused"
	assert_contains "$REASON" "METAREPO_AGENT_PUSH" "message names the setting"
	assert_contains "$REASON" "pushes are disabled" "message says pushes are disabled"
}

test_commit_permission_does_not_allow_push() {
	make_meta
	export METAREPO_AGENT_COMMIT=1
	guard "$ROOT/repos/api" 'git push -u origin feature/x'
	assert_eq deny "$DECISION" "push refused"
	assert_contains "$REASON" "METAREPO_AGENT_PUSH"
}

test_push_allowed_after_opt_in() {
	make_meta
	export METAREPO_AGENT_PUSH=1
	git -C "$ROOT/repos/api" commit -q --allow-empty -m "feat: x"
	run_allowed "$ROOT/repos/api" 'git push -q -u origin feature/x'
	assert_eq "$(git -C "$ROOT/repos/api" rev-parse HEAD)" "$(git --git-dir="$API_REMOTE" rev-parse feature/x)" "branch on the remote"
}

test_commit_on_main_refused() {
	make_meta
	export METAREPO_AGENT_COMMIT=1 METAREPO_AGENT_PUSH=1
	git -C "$ROOT/repos/api" checkout -q main
	guard "$ROOT/repos/api" 'git commit -m x'
	assert_eq deny "$DECISION" "commit on main refused"
	assert_contains "$REASON" "main" "message names main"
	guard "$ROOT" 'git -C repos/api commit -m x'
	assert_eq deny "$DECISION" "git -C commit on main refused"
	assert_contains "$REASON" "main" "git -C: message names main"
	# The meta-repository root is on main: the commit is refused too.
	guard "$ROOT" 'git commit -m x'
	assert_eq deny "$DECISION" "commit on the root main refused"
	assert_contains "$REASON" "main"
	# The same commit on a feature branch passes.
	guard "$ROOT/repos/web" 'git commit -m x'
	assert_eq allow "$DECISION" "commit on a feature branch: $REASON"
}

test_push_to_main_refused() {
	make_meta
	export METAREPO_AGENT_COMMIT=1 METAREPO_AGENT_PUSH=1
	for cmd in 'git push origin main' 'git push origin feature/x:main' 'git push origin +HEAD:refs/heads/main' \
		'git push --all origin' 'git push origin HEAD:main --force'; do
		guard "$ROOT/repos/api" "$cmd"
		assert_eq deny "$DECISION" "[$cmd] refused"
		assert_contains "$REASON" "main" "[$cmd] message names main"
	done
	# A push without a refspec from branch main goes to main.
	git -C "$ROOT/repos/web" checkout -q main
	guard "$ROOT/repos/web" 'git push'
	assert_eq deny "$DECISION" "push from branch main refused"
	assert_contains "$REASON" "main"
	# A feature branch tracking origin/main also goes to main.
	git -C "$ROOT/repos/api" branch -q --set-upstream-to=origin/main feature/x
	guard "$ROOT/repos/api" 'git push'
	assert_eq deny "$DECISION" "push to upstream main refused"
	# Pushing a feature branch passes.
	git -C "$ROOT/repos/api" branch -q --unset-upstream feature/x
	guard "$ROOT/repos/api" 'git push origin feature/x'
	assert_eq allow "$DECISION" "push of a feature branch: $REASON"
}

# The hook leaves commands that neither commit nor push alone.
test_other_git_commands_pass() {
	make_meta
	for cmd in 'git status' 'git log --oneline -3' 'git diff' 'git -C repos/api fetch' 'echo "git commit"' 'ls'; do
		guard "$ROOT" "$cmd"
		assert_eq allow "$DECISION" "[$cmd]: $REASON"
	done
}

test_personal_settings_stay_local() {
	WS="$(make_workspace)"
	mkdir -p "$WS/.claude"
	echo '{"env": {"METAREPO_AGENT_COMMIT": "1"}}' >"$WS/.claude/settings.local.json"
	assert_eq "" "$(git -C "$WS" status --porcelain --untracked-files=all)" "root git status is empty"
	assert_eq ".claude/settings.local.json" "$(git -C "$WS" check-ignore .claude/settings.local.json)" "file is ignored"
}

# The hook is registered in the root settings on Bash next to the kit's hooks.
test_hook_registered() {
	node -e '
		const s = require(process.argv[1]);
		const ok = (s.hooks.PreToolUse || []).some((m) => m.matcher === "Bash" &&
			m.hooks.some((h) => h.command.includes(".claude/hooks/agent-git-guard.mjs")));
		process.exit(ok ? 0 : 1);' "$META_ROOT/.claude/settings.json" || fail "hook is not registered in .claude/settings.json"
}

# --- Attribution ------------------------------------------------------------------

# The meta-repository and the api clone on the work branch bugfix/PROJ-123, agent
# commits enabled. Sets ROOT, API_REMOTE.
make_work_meta() {
	make_meta
	git -C "$ROOT" checkout -qb bugfix/PROJ-123
	git -C "$ROOT/repos/api" checkout -qb bugfix/PROJ-123
	export METAREPO_AGENT_COMMIT=1
}

# The refusal is the attribution refusal and names what was found: refused_for <found>
refused_for() {
	assert_eq deny "$DECISION" "command refused"
	assert_contains "$REASON" "Claude attribution is not allowed in commits and pull requests" "attribution refusal"
	assert_contains "$REASON" "$1" "message names what was found"
}

test_shared_setting_turns_attribution_off() {
	values="$(node -e '
		const s = require(process.argv[1]);
		const a = s.attribution || {};
		console.log(JSON.stringify([a.commit, a.pr, s.includeCoAuthoredBy]));' "$META_ROOT/.claude/settings.json")"
	assert_eq '["","",false]' "$values" "attribution.commit, attribution.pr, includeCoAuthoredBy"
}

test_commit_with_co_author_refused() {
	make_work_meta
	guard "$ROOT" 'git commit -m "fix: totals" -m "Co-Authored-By: Claude <noreply@anthropic.com>"'
	refused_for '`Co-Authored-By`'
}

test_pr_with_generated_line_refused() {
	make_work_meta
	guard "$ROOT" 'gh pr create --base main --title "PROJ-123: totals" --body "Fixes the totals.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"'
	refused_for '`Generated with Claude Code`'
}

test_pr_description_edit_refused() {
	make_work_meta
	guard "$ROOT" 'gh pr edit 12 --body "Uses the Anthropic client for the totals."'
	refused_for '`Anthropic`'
}

test_pr_comment_refused() {
	make_work_meta
	guard "$ROOT" 'gh pr comment 12 --body "Reviewed by Claude"'
	refused_for '`Claude`'
}

test_pr_review_refused() {
	make_work_meta
	guard "$ROOT" 'gh pr review 12 --approve -b "Looks good.

Co-Authored-By: Claude <noreply@anthropic.com>"'
	refused_for '`Co-Authored-By`'
}

test_rule_file_names_allowed() {
	make_work_meta
	guard "$ROOT" 'git commit -m "docs: update CLAUDE.md and .claude/ rules"'
	assert_eq allow "$DECISION" "rule file names: $REASON"
	guard "$ROOT" 'git commit -m "docs: update CLAUDE.local.md"'
	assert_eq allow "$DECISION" "CLAUDE.local.md: $REASON"
}

test_tool_name_allowed() {
	make_work_meta
	guard "$ROOT" 'gh pr create --base main --title "Attribution off" --body "Turns off attribution in the Claude Code settings"'
	assert_eq allow "$DECISION" "Claude Code is allowed: $REASON"
}

test_clean_commit_passes() {
	make_work_meta
	echo total >"$ROOT/repos/api/total.txt"
	git -C "$ROOT/repos/api" add total.txt
	before="$(git -C "$ROOT/repos/api" rev-list --count HEAD)"
	run_allowed "$ROOT/repos/api" 'git commit -q -m "fix: correct the invoice total"'
	assert_eq "$((before + 1))" "$(git -C "$ROOT/repos/api" rev-list --count HEAD)" "commit made"
	assert_eq "fix: correct the invoice total" "$(git -C "$ROOT/repos/api" log -1 --format=%s)" "commit message"
}

test_pr_title_edit_refused() {
	make_work_meta
	guard "$ROOT" 'gh pr edit --title "PROJ-123: totals, written with Claude"'
	refused_for '`Claude`'
}

test_commit_in_clone_checked() {
	make_work_meta
	guard "$ROOT" 'git -C repos/api commit -m "fix: totals" -m "Co-Authored-By: Claude <noreply@anthropic.com>"'
	refused_for '`Co-Authored-By`'
}

test_lower_case_word_refused() {
	make_work_meta
	guard "$ROOT" 'git commit -m "fix: totals (pair-programmed with claude)"'
	refused_for '`claude`'
	guard "$ROOT" 'git commit -m "fix: totals for ANTHROPIC"'
	refused_for '`ANTHROPIC`'
}

test_nested_rule_file_paths_allowed() {
	make_work_meta
	guard "$ROOT" 'git commit -m "docs: update repos/web/CLAUDE.md and .claude/hooks/agent-git-guard.mjs"'
	assert_eq allow "$DECISION" "nested rule file paths: $REASON"
}

test_generated_line_refused_despite_tool_name() {
	make_work_meta
	guard "$ROOT" 'gh pr create --base main --title "PROJ-123: totals" --body "Generated with Claude Code"'
	refused_for '`Generated with Claude Code`'
}

test_commit_message_file_with_attribution_refused() {
	make_work_meta
	printf 'fix: totals\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' >"$ROOT/msg.txt"
	guard "$ROOT" 'git commit -F msg.txt'
	refused_for '`Co-Authored-By`'
	guard "$ROOT" 'git commit --file=msg.txt'
	refused_for '`Co-Authored-By`'
	# Relative to the folder of git -C.
	cp "$ROOT/msg.txt" "$ROOT/repos/api/msg.txt"
	guard "$ROOT" 'git -C repos/api commit -F msg.txt'
	refused_for '`Co-Authored-By`'
}

test_clean_commit_message_file_passes() {
	make_work_meta
	printf 'fix: correct the invoice total\n' >"$ROOT/repos/api/msg.txt"
	echo total >"$ROOT/repos/api/total.txt"
	git -C "$ROOT/repos/api" add total.txt
	before="$(git -C "$ROOT/repos/api" rev-list --count HEAD)"
	run_allowed "$ROOT/repos/api" 'git commit -q -F msg.txt'
	assert_eq "$((before + 1))" "$(git -C "$ROOT/repos/api" rev-list --count HEAD)" "commit made"
	assert_eq "fix: correct the invoice total" "$(git -C "$ROOT/repos/api" log -1 --format=%s)" "commit message"
}

test_pr_body_file_with_attribution_refused() {
	make_work_meta
	printf 'Fixes the totals.\n\nGenerated with Claude Code\n' >"$ROOT/body.md"
	guard "$ROOT" 'gh pr create --base main --title "PROJ-123: totals" --body-file body.md'
	refused_for '`Generated with Claude Code`'
	guard "$ROOT" 'gh pr comment 12 -F body.md'
	refused_for '`Generated with Claude Code`'
	# A clean body file passes.
	printf 'Fixes the totals.\n' >"$ROOT/body.md"
	guard "$ROOT" 'gh pr create --base main --title "PROJ-123: totals" --body-file body.md'
	assert_eq allow "$DECISION" "clean body file: $REASON"
}

test_commit_through_editor_refused() {
	make_work_meta
	for cmd in 'git commit' 'git commit -a' 'git -C repos/api commit --amend'; do
		guard "$ROOT" "$cmd"
		assert_eq deny "$DECISION" "[$cmd] refused"
		assert_contains "$REASON" "would open an editor" "[$cmd] message names the editor"
		assert_contains "$REASON" '`-m`' "[$cmd] message names -m"
	done
	# Reusing an existing message opens no editor.
	guard "$ROOT" 'git commit --amend --no-edit'
	assert_eq allow "$DECISION" "--amend --no-edit: $REASON"
}

test_auto_filled_pr_refused() {
	make_work_meta
	for cmd in 'gh pr create --fill' 'gh pr create --base main --fill-first' 'gh pr create --fill-verbose' 'gh pr create -f'; do
		guard "$ROOT" "$cmd"
		assert_eq deny "$DECISION" "[$cmd] refused"
		assert_contains "$REASON" '`--fill`' "[$cmd] message names --fill"
	done
}

# Permission refusals come before the attribution check.
test_permission_refusal_before_attribution() {
	make_work_meta
	unset METAREPO_AGENT_COMMIT
	guard "$ROOT" 'git commit -m "fix: totals" -m "Co-Authored-By: Claude <noreply@anthropic.com>"'
	assert_eq deny "$DECISION" "commit refused"
	assert_contains "$REASON" "METAREPO_AGENT_COMMIT" "permission message first"
	assert_not_contains "$REASON" "Claude attribution is not allowed" "no attribution message"
}

# --- Merge block -------------------------------------------------------------------

# Both agent settings on; the api clone has bugfix/PROJ-123 with one commit.
make_merge_meta() {
	make_meta
	export METAREPO_AGENT_COMMIT=1 METAREPO_AGENT_PUSH=1
	git -C "$ROOT/repos/api" checkout -qb bugfix/PROJ-123 origin/main
	git -C "$ROOT/repos/api" commit -q --allow-empty -m "fix: totals"
}

test_pr_merge_refused() {
	make_merge_meta
	guard "$ROOT/repos/api" 'gh pr merge 12'
	assert_eq deny "$DECISION" "gh pr merge refused"
	assert_contains "$REASON" "developer merges pull requests by hand" "message says the developer merges"
	guard "$ROOT" 'cd repos/web && gh pr merge 13 --squash --delete-branch'
	assert_eq deny "$DECISION" "gh pr merge in the web clone refused"
	assert_contains "$REASON" "developer merges pull requests by hand"
}

test_merge_on_dev_refused() {
	make_merge_meta
	git -C "$ROOT/repos/api" checkout -q dev
	guard "$ROOT" 'git -C repos/api merge --no-ff bugfix/PROJ-123'
	assert_eq deny "$DECISION" "merge on dev refused"
	assert_contains "$REASON" '`dev`' "message names dev"
	assert_contains "$REASON" "merges by hand" "message says the developer merges by hand"
}

test_merge_on_main_refused() {
	make_merge_meta
	assert_eq main "$(git -C "$ROOT" branch --show-current)" "root on main"
	guard "$ROOT" 'git merge feature/agent-workflow-rules'
	assert_eq deny "$DECISION" "merge on main refused"
	assert_contains "$REASON" '`main`' "message names main"
	assert_contains "$REASON" "merges by hand"
}

test_merge_into_merge_branch_allowed() {
	make_merge_meta
	git -C "$ROOT/repos/api" checkout -qb merge/PROJ-123-into-dev origin/dev
	guard "$ROOT" 'git -C repos/api merge --no-ff bugfix/PROJ-123'
	assert_eq allow "$DECISION" "merge into the merge branch: $REASON"
	run_allowed "$ROOT" 'git -C repos/api merge -q --no-ff --no-edit bugfix/PROJ-123'
	assert_eq "fix: totals" "$(git -C "$ROOT/repos/api" log -1 --format=%s HEAD^2)" "work branch merged"
}

# --- Branch model hints from repos.toml --------------------------------------------

# A registry in the meta-repository root: api main-based on dev, web dev-based on stage.
write_registry() {
	cat >"$ROOT/repos.toml" <<'TOML'
[[repo]]
name = "api"
path = "repos/api"
url = "git@example.com:org/api.git"
ref = "dev"
branch_model = "main-based"
stack = ""

[[repo]]
name = "web"
path = "repos/web"
url = "git@example.com:org/web.git"
ref = "stage"
branch_model = "dev-based"
stack = ""
TOML
}

# The refusal on main names the base branch from the clone's branch model.
test_commit_on_main_names_branch_model() {
	make_meta
	write_registry
	export METAREPO_AGENT_COMMIT=1
	git -C "$ROOT/repos/api" checkout -q main
	git -C "$ROOT/repos/web" checkout -q main
	guard "$ROOT" 'git -C repos/api commit -m x'
	assert_eq deny "$DECISION" "commit on main in api refused"
	assert_contains "$REASON" 'api is main-based, so it starts from `origin/main`' "main-based hint"
	guard "$ROOT/repos/web" 'git commit -m x'
	assert_eq deny "$DECISION" "commit on main in web refused"
	assert_contains "$REASON" 'web is dev-based, so it starts from `origin/stage`' "dev-based hint"
	guard "$ROOT" 'git commit -m x'
	assert_contains "$REASON" 'Create a work branch from `main`' "meta-repository hint"
}

# A merge while the clone is on its rest branch from repos.toml is refused.
test_merge_on_rest_branch_refused() {
	make_meta
	write_registry
	export METAREPO_AGENT_COMMIT=1 METAREPO_AGENT_PUSH=1
	git -C "$ROOT/repos/web" checkout -qb stage
	guard "$ROOT" 'git -C repos/web merge feature/x'
	assert_eq deny "$DECISION" "merge on the rest branch refused"
	assert_contains "$REASON" '`stage`' "message names the rest branch"
	# Without the registry entry the same branch is an ordinary branch.
	rm "$ROOT/repos.toml"
	guard "$ROOT" 'git -C repos/web merge feature/x'
	assert_eq allow "$DECISION" "merge on an unregistered branch: $REASON"
}

# The shared settings match the project's agent_git_default answer.
test_shared_default_matches_answer() {
	answer="$(sed -nE "s/^agent_git_default: *'?([a-z]+)'?/\\1/p" "$META_ROOT/.copier-answers.yml")"
	values="$(node -e '
		const s = require(process.argv[1]);
		const e = s.env || {};
		console.log([e.METAREPO_AGENT_COMMIT || "-", e.METAREPO_AGENT_PUSH || "-"].join(" "));' "$META_ROOT/.claude/settings.json")"
	if [ "$answer" = on ]; then
		assert_eq "1 1" "$values" "agent commit and push on by default"
	else
		assert_eq "- -" "$values" "agent commit and push off by default"
	fi
}

run_tests
