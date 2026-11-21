#!/usr/bin/env bash
# The single check command: a step per clone, code-rules, repos.
source "$META_ROOT/tests/lib.sh"

# The final output table with collapsed spaces: "api ok".
result_table() { echo "$OUT" | sed -n '/^STEP/,$p' | grep -v '^\[' | awk 'NF { $1 = $1; print }'; }

test_everything_passes() {
	cloned_workspace
	run_task check
	assert_eq 0 "$RC" "check: $OUT"
	assert_eq "STEP RESULT
api ok
web ok
code-rules ok
repos ok" "$(result_table)" "result table"
}

test_without_repositories() {
	WS="$(make_workspace)"
	run_task check
	assert_eq 0 "$RC" "check: $OUT"
	assert_eq "STEP RESULT
code-rules ok
repos ok" "$(result_table)" "result table"
}

test_one_repository_fails() {
	cloned_workspace
	export STUB_EXIT_WEB_CHECK=1
	run_task check
	assert_eq 1 "$RC" "check fails: $OUT"
	assert_eq "api-check  pwd=$WS/repos/api
web-check  pwd=$WS/repos/web" "$(cat "$STUB_LOG")" "both clone checks ran"
	assert_contains "$(result_table)" "web FAIL" "web row"
	assert_contains "$(result_table)" "api ok" "api row"
}

test_no_tests_are_run() {
	cloned_workspace
	export STUB_EXIT_API_TEST=1 STUB_EXIT_WEB_TEST=1
	run_task check
	assert_eq 0 "$RC" "check: $OUT"
	assert_not_contains "$(cat "$STUB_LOG")" "-test" "tests did not run"
	assert_eq 2 "$(wc -l <"$STUB_LOG" | tr -d ' ')" "only the two clone checks ran"
}

test_clone_missing() {
	setup_stub_workspace
	clone_into "$WS" repos/web "$WEB_REMOTE"
	run_task check
	assert_eq 1 "$RC" "check fails: $OUT"
	assert_contains "$OUT" "repos/api: missing" "message names the missing clone"
	assert_contains "$(result_table)" "api FAIL" "api row"
	assert_contains "$(result_table)" "web ok" "web row"
}

test_stub_task_fails_with_hint() {
	WS="$(make_workspace)"
	REMOTE="$(make_stub_remote svc)"
	register "$WS" svc "$REMOTE" main-based
	clone_into "$WS" repos/svc "$REMOTE"
	run_task check
	assert_eq 1 "$RC" "check fails: $OUT"
	assert_contains "$OUT" "svc:check: command not configured yet" "stub message"
	assert_contains "$OUT" "/bootstrap" "stub names /bootstrap"
	assert_contains "$(result_table)" "svc FAIL" "svc row"
	assert_contains "$(result_table)" "repos ok" "registry row"
}

test_no_rules_defined() {
	cloned_workspace
	assert_eq "" "$(find "$WS/ast-grep/rules" -name '*.yml')" "the copy has no rules"
	run_task check
	assert_eq 0 "$RC" "check: $OUT"
	assert_contains "$OUT" "no rules" "the rules step reports there are no rules"
	assert_contains "$(result_table)" "code-rules ok" "rules row"
}

test_rule_finds_violation() {
	cloned_workspace
	cat >"$WS/ast-grep/rules/no-print-py.yml" <<'YML'
id: no-print-py
language: python
severity: error
message: print in application code
rule:
  pattern: print($$$ARGS)
YML
	cat >"$WS/ast-grep/rule-tests/no-print-py-test.yml" <<'YML'
id: no-print-py
valid:
  - logger.info("x")
  - pprint_value(1)
invalid:
  - print("x")
  - print(1, 2)
YML
	mkdir -p "$WS/repos/api/app"
	echo 'print("debug")' >"$WS/repos/api/app/views.py"
	run_task check
	assert_eq 1 "$RC" "check fails: $OUT"
	assert_contains "$OUT" "no-print-py" "output names the rule"
	assert_contains "$OUT" "repos/api/app/views.py" "output names the file"
	assert_contains "$(result_table)" "code-rules FAIL" "rules row"
}

test_registry_drift_fails() {
	cloned_workspace
	sed -i '/^# repos:end/i "repos/extra" = { url = "git@example.com:org/extra.git", ref = "dev" }' "$WS/mise.toml"
	run_task check
	assert_eq 1 "$RC" "check fails: $OUT"
	assert_contains "$OUT" "mise.toml" "output names mise.toml"
	assert_contains "$(result_table)" "repos FAIL" "registry row"
}

run_tests
