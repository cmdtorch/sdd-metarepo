#!/usr/bin/env bash
# The state of the clones: status.
source "$META_ROOT/tests/lib.sh"

has_row() { grep -qxF -- "$2" <<<"$1" || fail "$3: no row [$2] in the table:
$1"; }

test_status_two_clones() {
	cloned_workspace
	git -C "$WS/repos/web" checkout -qb feature/x
	echo a >>"$WS/repos/web/README.md"
	echo b >"$WS/repos/web/NEW"
	run_task status
	assert_eq 0 "$RC" "status: $OUT"
	table="$(echo "$OUT" | awk 'NF { $1 = $1; print }')"
	has_row "$table" "api dev 0" "api row"
	has_row "$table" "web feature/x 2" "web row"
}

test_status_missing_clone() {
	setup_stub_workspace
	clone_into "$WS" repos/api "$API_REMOTE"
	run_task status
	table="$(echo "$OUT" | awk 'NF { $1 = $1; print }')"
	has_row "$table" "api dev 0" "api row"
	has_row "$table" "web missing -" "web marked as missing"
}

test_status_without_repositories() {
	WS="$(make_workspace)"
	run_task status
	assert_eq 0 "$RC" "status: $OUT"
	assert_eq "REPO BRANCH CHANGED" "$(echo "$OUT" | awk 'NF { $1 = $1; print }')" "header only"
}

run_tests
