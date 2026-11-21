#!/usr/bin/env bash
# The repository registry: scripts/repos.mjs add, sync, check and the generated files.
source "$META_ROOT/tests/lib.sh"

AGENTS_COMMANDS=('<!-- repos:begin:commands -->' '<!-- repos:end:commands -->')
AGENTS_BRANCHES=('<!-- repos:begin:branches -->' '<!-- repos:end:branches -->')

# A fresh project is already in sync: sync changes nothing and check passes.
test_fresh_project_in_sync() {
	WS="$(make_workspace)"
	run_repos sync
	assert_eq 0 "$RC" "sync: $OUT"
	assert_eq "" "$(git -C "$WS" status --porcelain)" "sync changed nothing"
	run_repos check
	assert_eq 0 "$RC" "check: $OUT"
	assert_contains "$OUT" "(0 repositories)"
}

# add --yes appends the entry, regenerates every list and creates the task stubs.
test_add_without_questions() {
	WS="$(make_workspace)"
	run_repos add --yes --name api --url git@github.com:acme/api.git --branch-model main-based --stack "Go, PostgreSQL"
	assert_eq 0 "$RC" "add: $OUT"
	assert_contains "$(cat "$WS/repos.toml")" 'name = "api"'
	assert_contains "$(cat "$WS/repos.toml")" 'branch_model = "main-based"'
	assert_contains "$(cat "$WS/repos.toml")" 'stack = "Go, PostgreSQL"'
	assert_eq '[bootstrap.repos]
"repos/api" = { url = "git@github.com:acme/api.git", ref = "dev" }' "$(between "$WS/mise.toml" '# repos:begin' '# repos:end')" "mise.toml block"
	assert_contains "$(cd "$WS" && mise bootstrap repos status)" "repos/api" "mise sees the clone"
	assert_contains "$(between "$WS/AGENTS.md" "${AGENTS_COMMANDS[@]}")" '`mise run api:test <' "AGENTS.md commands"
	assert_contains "$(between "$WS/AGENTS.md" "${AGENTS_BRANCHES[@]}")" '`api` (main-based)' "AGENTS.md branches"
	assert_contains "$(between "$WS/docs/agents/branches.md" '<!-- repos:begin -->' '<!-- repos:end -->')" '| `api` | main-based | `dev` | `origin/main` |' "branches.md table"
	assert_contains "$(between "$WS/repos/README.md" '<!-- repos:begin -->' '<!-- repos:end -->')" '| `repos/api` | `git@github.com:acme/api.git` |' "repos/README.md table"
	for task in test check run install; do
		[ -x "$WS/mise-tasks/api/$task" ] || fail "no executable stub mise-tasks/api/$task"
	done
	assert_contains "$(cd "$WS" && mise tasks 2>&1)" "api:test" "mise lists the clone tasks"
	run_repos check
	assert_eq 0 "$RC" "check: $OUT"
	assert_contains "$OUT" "Not configured yet" "check lists the stubs"
}

# The dev-based model gets its own rule, and a bare name expands with the GitHub owner.
test_dev_based_and_bare_name() {
	WS="$(make_workspace)"
	org="$(sed -nE 's/^github_org: *//p' "$WS/.copier-answers.yml")"
	run_repos add --yes --url web --ref stage --branch-model dev-based
	assert_eq 0 "$RC" "add: $OUT"
	assert_contains "$(cat "$WS/repos.toml")" "url = \"git@github.com:$org/web.git\"" "expanded URL"
	assert_contains "$(between "$WS/AGENTS.md" "${AGENTS_BRANCHES[@]}")" '`web` (dev-based)' "AGENTS.md branches"
	assert_contains "$(between "$WS/docs/agents/branches.md" '<!-- repos:begin -->' '<!-- repos:end -->')" '| `web` | dev-based | `stage` | `origin/stage` |' "branches.md row"
}

# The name comes from the URL when it is not given.
test_name_from_url() {
	WS="$(make_workspace)"
	run_repos add --yes --url https://github.com/acme/Billing_Service.git
	assert_eq 0 "$RC" "add: $OUT"
	assert_contains "$(cat "$WS/repos.toml")" 'name = "billing_service"'
	assert_contains "$(cat "$WS/repos.toml")" 'path = "repos/billing_service"'
}

# Invalid entries are refused and nothing is written.
test_invalid_entries_refused() {
	WS="$(make_workspace)"
	run_repos add --yes --name api --url git@example.com:o/api.git
	before="$(cat "$WS/repos.toml")"
	for args in "--name api --url git@example.com:o/other.git" \
		"--name kit --url git@example.com:o/kit.git" \
		"--name Bad.Name --url git@example.com:o/x.git" \
		"--name x --url git@example.com:o/x.git --branch-model trunk" \
		"--name y --url git@example.com:o/y.git --ref main"; do
		# shellcheck disable=SC2086
		run_repos add --yes $args
		assert_eq 1 "$RC" "[$args] refused: $OUT"
		assert_contains "$OUT" "Not added" "[$args] message"
	done
	assert_eq "$before" "$(cat "$WS/repos.toml")" "repos.toml unchanged"
}

# The interactive loop reads numbered answers until "no".
test_interactive_add() {
	WS="$(make_workspace)"
	RC=0
	OUT="$(cd "$WS" && printf '%s\n' 1 git@example.com:o/api.git '' '' 1 'Go' 1 git@example.com:o/web.git '' stage 2 '' 2 2 | node scripts/repos.mjs add 2>&1)" || RC=$?
	assert_eq 0 "$RC" "add: $OUT"
	run_repos list
	assert_eq "api	repos/api	git@example.com:o/api.git	dev	main-based
web	repos/web	git@example.com:o/web.git	stage	dev-based" "$OUT" "registered repositories"
	assert_contains "$(cat "$WS/repos.toml")" 'stack = "Go"'
	assert_no_path "$WS/repos/api"
}

# Declining the first question adds nothing.
test_interactive_decline() {
	WS="$(make_workspace)"
	RC=0
	OUT="$(cd "$WS" && printf '2\n' | node scripts/repos.mjs add 2>&1)" || RC=$?
	assert_eq 0 "$RC" "add: $OUT"
	assert_eq "" "$(git -C "$WS" status --porcelain)" "nothing changed"
}

# sync never overwrites a task file that exists.
test_sync_keeps_configured_tasks() {
	WS="$(make_workspace)"
	run_repos add --yes --name api --url git@example.com:o/api.git
	printf '#!/usr/bin/env bash\n#MISE description="mine"\necho mine\n' >"$WS/mise-tasks/api/test"
	run_repos sync
	assert_eq 0 "$RC" "sync: $OUT"
	assert_contains "$(cat "$WS/mise-tasks/api/test")" "echo mine" "task kept"
	run_repos check
	assert_not_contains "$OUT" "api:test" "a configured task is not listed as a stub"
}

# check reports each kind of drift.
test_check_reports_drift() {
	WS="$(make_workspace)"
	run_repos add --yes --name api --url git@example.com:o/api.git
	git -C "$WS" add -A
	git -C "$WS" commit -qm "api" --no-verify
	# A hand edit inside a generated section.
	sed -i 's/| `api` | main-based/| `api` | dev-based/' "$WS/docs/agents/branches.md"
	run_repos check
	assert_eq 1 "$RC" "edited section: $OUT"
	assert_contains "$OUT" "docs/agents/branches.md" "names the file"
	git -C "$WS" checkout -q -- .
	# A missing task file.
	rm "$WS/mise-tasks/api/run"
	run_repos check
	assert_eq 1 "$RC" "missing task: $OUT"
	assert_contains "$OUT" "mise-tasks/api/run" "names the task"
	git -C "$WS" checkout -q -- .
	# A task folder of an unregistered repository.
	mkdir -p "$WS/mise-tasks/old"
	run_repos check
	assert_eq 1 "$RC" "orphan folder: $OUT"
	assert_contains "$OUT" "mise-tasks/old/" "names the folder"
	rmdir "$WS/mise-tasks/old"
	# A broken registry.
	echo 'name = api' >>"$WS/repos.toml"
	run_repos check
	assert_eq 1 "$RC" "broken registry: $OUT"
	assert_contains "$OUT" "repos.toml:" "names the line"
}

# With openspec/ (sdd-kit installed), sync writes the kit clone list and check compares it.
test_kit_clone_list() {
	WS="$(make_workspace)"
	mkdir -p "$WS/openspec"
	# The kit installer's own format, without markers.
	printf '# One clone per line: <path> or <name>=<path>\nrepos/old\n' >"$WS/openspec/clones"
	run_repos add --yes --name api --url git@example.com:o/api.git
	assert_eq 0 "$RC" "add: $OUT"
	assert_eq "repos/api" "$(grep -v '^#' "$WS/openspec/clones" | grep -v '^$')" "kit list"
	assert_contains "$(cat "$WS/openspec/clones")" "# One clone per line" "kit comment kept"
	run_repos check
	assert_eq 0 "$RC" "check: $OUT"
	echo "web=repos/web" >>"$WS/openspec/clones"
	run_repos check
	assert_eq 1 "$RC" "extra kit entry: $OUT"
	assert_contains "$OUT" "repos/web" "names the entry"
}

# Generated text follows the project language.
test_generated_text_language() {
	WS="$(make_workspace)"
	sed -i 's/^language: .*/language: ru/' "$WS/.copier-answers.yml"
	run_repos add --yes --name api --url git@example.com:o/api.git
	assert_contains "$(between "$WS/AGENTS.md" "${AGENTS_COMMANDS[@]}")" "Все тесты" "Russian command table"
	sed -i 's/^language: .*/language: en/' "$WS/.copier-answers.yml"
	run_repos sync
	assert_contains "$(between "$WS/AGENTS.md" "${AGENTS_COMMANDS[@]}")" "All tests" "English command table"
}

# The generated text below is checked in English, whatever the project language.
use_english() { sed -i 's/^language: .*/language: en/' "$1/.copier-answers.yml"; }

# add prints the /bootstrap hint for the new repository.
test_add_prints_bootstrap_hint() {
	WS="$(make_workspace)"
	use_english "$WS"
	run_repos add --yes --name api --url git@example.com:o/api.git
	assert_eq 0 "$RC" "add: $OUT"
	assert_contains "$OUT" "run /bootstrap api" "hint"
}

# set writes optional fields, keeps comments, and sync renders them; an empty value removes one.
test_set_optional_fields() {
	WS="$(make_workspace)"
	use_english "$WS"
	run_repos add --yes --name api --url git@example.com:o/api.git --stack Go
	run_repos add --yes --name web --url git@example.com:o/web.git
	run_repos set api env_file=.env env_example=.env.example "env_notes=DB_HOST=localhost" "test_needs=PostgreSQL" "notes=check runs without a database" rules=CLAUDE.md,.claude/rules/
	assert_eq 0 "$RC" "set: $OUT"
	reg="$(cat "$WS/repos.toml")"
	assert_contains "$reg" 'env_file = ".env"'
	assert_contains "$reg" 'rules = ["CLAUDE.md", ".claude/rules/"]'
	assert_contains "$reg" "# Optional fields" "header comments kept"
	# The field lands in the api entry, before the web entry.
	[ "$(grep -n '^env_file' "$WS/repos.toml" | cut -d: -f1)" -lt "$(grep -n '^name = "web"' "$WS/repos.toml" | cut -d: -f1)" ] || fail "field outside the api entry"
	cmds="$(between "$WS/AGENTS.md" "${AGENTS_COMMANDS[@]}")"
	assert_contains "$cmds" '| Environment | file `repos/api/.env`, example `repos/api/.env.example` |'
	assert_contains "$cmds" 'Before editing a file in `repos/api`, read `repos/api/CLAUDE.md`, `repos/api/.claude/rules/`'
	assert_contains "$cmds" 'Tests need PostgreSQL. check runs without a database'
	run_repos check
	assert_eq 0 "$RC" "check: $OUT"
	run_repos set api notes=
	assert_eq 0 "$RC" "remove: $OUT"
	assert_eq 0 "$(grep -c '^notes' "$WS/repos.toml")" "notes removed"
	# A list may also be written as an array; a malformed array is refused, not stored.
	run_repos set web 'rules=["AGENTS.md", "docs/rules/"]'
	assert_eq 0 "$RC" "set an array: $OUT"
	assert_contains "$(cat "$WS/repos.toml")" 'rules = ["AGENTS.md", "docs/rules/"]' "array stored as a list"
	run_repos set web 'rules=["AGENTS.md",'
	assert_eq 1 "$RC" "malformed array refused: $OUT"
	assert_contains "$(cat "$WS/repos.toml")" 'rules = ["AGENTS.md", "docs/rules/"]' "list unchanged"
	run_repos set api env_file=../secret
	assert_eq 1 "$RC" "outside the clone refused: $OUT"
	run_repos set api unknown=1
	assert_eq 1 "$RC" "unknown field refused: $OUT"
	run_repos set nope notes=x
	assert_eq 1 "$RC" "unknown repository refused: $OUT"
}

# A malformed list field is reported with its line.
test_list_field_must_be_list() {
	WS="$(make_workspace)"
	run_repos add --yes --name api --url git@example.com:o/api.git
	echo 'rules = "CLAUDE.md"' >>"$WS/repos.toml"
	run_repos check
	assert_eq 1 "$RC" "check: $OUT"
	assert_contains "$OUT" "list of strings"
}

# Extra task files appear in the command table with their description.
test_extra_tasks_listed() {
	WS="$(make_workspace)"
	use_english "$WS"
	run_repos add --yes --name api --url git@example.com:o/api.git
	printf '#!/usr/bin/env bash\n#MISE description="api: background task worker (make worker in repos/api)"\nexec make worker\n' >"$WS/mise-tasks/api/worker"
	chmod +x "$WS/mise-tasks/api/worker"
	run_repos check
	assert_eq 1 "$RC" "check sees the new task: $OUT"
	run_repos sync
	assert_contains "$(between "$WS/AGENTS.md" "${AGENTS_COMMANDS[@]}")" '| Background task worker | `mise run api:worker` |'
	run_repos check
	assert_eq 0 "$RC" "check: $OUT"
}

# The environment table is generated only where the markers exist.
test_environment_table() {
	WS="$(make_workspace)"
	use_english "$WS"
	run_repos add --yes --name api --url git@example.com:o/api.git
	# A project generated before the markers existed: sync and check skip the file.
	sed -i '/^<!-- repos:begin:env -->$/,/^<!-- repos:end:env -->$/d' "$WS/docs/agents/environment.md"
	run_repos set api env_file=.env
	assert_eq 0 "$RC" "set without env markers: $OUT"
	printf '\n<!-- repos:begin:env -->\n<!-- repos:end:env -->\n' >>"$WS/docs/agents/environment.md"
	run_repos check
	assert_eq 1 "$RC" "check sees the empty section: $OUT"
	run_repos sync
	assert_contains "$(between "$WS/docs/agents/environment.md" '<!-- repos:begin:env -->' '<!-- repos:end:env -->')" '| `api` | `repos/api/.env` | none | - |'
	run_repos check
	assert_eq 0 "$RC" "check: $OUT"
}

# A stub task fails with a clear message.
test_stub_task_message() {
	WS="$(make_workspace)"
	REMOTE="$(make_stub_remote api)"
	register "$WS" api "$REMOTE" main-based
	clone_into "$WS" repos/api "$REMOTE"
	run_task api:test
	assert_eq 1 "$RC" "stub fails: $OUT"
	assert_contains "$OUT" "api:test: command not configured yet — run /bootstrap in Claude Code or edit mise-tasks/api/test"
}

# The clone commands delegate to the clone with arguments and exit code.
test_configured_tasks_delegate() {
	cloned_workspace
	export STUB_EXIT_API_TEST=3
	run_task api:test app/tests/test_x.py
	assert_eq 3 "$RC" "exit code of the clone's tests: $OUT"
	assert_eq "api-test app/tests/test_x.py pwd=$WS/repos/api" "$(cat "$STUB_LOG")" "api tests call"
}

# A configured task fails before running anything when its clone is missing, and names the fix.
test_configured_task_on_missing_clone() {
	setup_stub_workspace
	clone_into "$WS" repos/api "$API_REMOTE"
	run_task web:test
	assert_eq 1 "$RC" "task fails: $OUT"
	assert_contains "$OUT" "repos/web: missing" "message names the clone"
	assert_contains "$OUT" "mise run clone" "message names the clone command"
	assert_eq "" "$(cat "$STUB_LOG")" "no clone command ran"
}

run_tests
