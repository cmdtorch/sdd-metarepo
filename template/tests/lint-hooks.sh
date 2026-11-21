#!/usr/bin/env bash
# Lint of the root texts and agent settings, and the meta-repository git hooks.
source "$META_ROOT/tests/lib.sh"

# Markdown that breaks a rule: a heading without a space after the hash (MD018).
BAD_MD='#Heading without a space

Text.'

commits() { git -C "$1" rev-list --count HEAD; }

test_broken_markdown_in_root() {
	WS="$(make_workspace)"
	mkdir -p "$WS/docs"
	printf '%s\n' "$BAD_MD" >"$WS/docs/broken-note.md"
	run_task lint
	assert_eq 1 "$RC" "lint fails: $OUT"
	assert_contains "$OUT" "docs/broken-note.md" "output names the file"
}

test_clones_are_not_linted() {
	cloned_workspace
	printf '%s\n' "$BAD_MD" >"$WS/repos/web/BROKEN.md"
	printf 'te%s recie%s\n' h ve >"$WS/repos/web/typo.txt"
	printf '# Rules\n\nSee [missing](nowhere.md).\n' >"$WS/repos/web/CLAUDE.md"
	run_task lint
	assert_eq 0 "$RC" "root lint passes: $OUT"
	# No finding points to a file in repos/ (a path like repos/...:line).
	found="$(grep -E '(^|[[:space:]/.])repos/[^[:space:]:]+:[0-9]+' <<<"$OUT" || true)"
	assert_eq "" "$found" "lint findings in the clones"
}

test_forbidden_claude_md() {
	for file in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do
		WS="$(make_workspace)"
		printf '# Rules\n' >"$WS/$file"
		run_task lint
		assert_eq 1 "$RC" "lint with $file fails: $OUT"
		assert_contains "$OUT" "$file" "message names $file"
		rm -rf "$WS"
	done
}

test_every_navigation_link_resolves() {
	links="$(grep -oE '\]\([^)#]+' "$META_ROOT/AGENTS.md" | sed 's/^](//' | grep -vE '^[a-z]+://' || true)"
	[ -n "$links" ] || fail "AGENTS.md has no relative links"
	while IFS= read -r link; do
		[ -e "$META_ROOT/$link" ] || fail "AGENTS.md link points to a missing file: $link"
	done <<<"$links"
	# lint catches a broken link.
	WS="$(make_workspace)"
	printf '\nMore in [the removed document](docs/agents/gone.md).\n' >>"$WS/AGENTS.md"
	run_task lint
	assert_eq 1 "$RC" "lint with a broken link fails: $OUT"
	assert_contains "$OUT" "docs/agents/gone.md" "message names the link"
}

test_invalid_task_blocks_commit() {
	WS="$(make_workspace)"
	(cd "$WS" && hk install --mise >/dev/null 2>&1) || fail "hk install"
	printf '#!/usr/bin/env bash\n#MISE description="Broken task"\nif then fi\n' >"$WS/mise-tasks/broken"
	chmod +x "$WS/mise-tasks/broken"
	git -C "$WS" add mise-tasks/broken
	before="$(commits "$WS")"
	rc=0
	out="$(git -C "$WS" commit -m "add broken task" 2>&1)" || rc=$?
	assert_eq 1 "$rc" "commit rejected: $out"
	assert_eq "$before" "$(commits "$WS")" "no commit created"
	assert_contains "$out" "mise-tasks/broken" "output names the file"
	# The fixed task is committed.
	printf '#!/usr/bin/env bash\n#MISE description="Fixed task"\necho ok\n' >"$WS/mise-tasks/broken"
	git -C "$WS" add mise-tasks/broken
	rc=0
	out="$(git -C "$WS" commit -m "add fixed task" 2>&1)" || rc=$?
	assert_eq 0 "$rc" "the fixed task is committed: $out"
}

test_broken_markdown_blocks_push() {
	WS="$(make_workspace)"
	git init -q --bare "$PWD/meta-remote.git"
	git -C "$WS" remote add origin "$PWD/meta-remote.git"
	git -C "$WS" push -q origin main
	(cd "$WS" && hk install --mise >/dev/null 2>&1) || fail "hk install"
	git -C "$WS" checkout -qb docs/note
	mkdir -p "$WS/docs"
	printf '%s\n' "$BAD_MD" >"$WS/docs/broken-note.md"
	git -C "$WS" add docs/broken-note.md
	git -C "$WS" commit -qm "docs: broken note" --no-verify
	rc=0
	out="$(git -C "$WS" push origin docs/note 2>&1)" || rc=$?
	assert_eq 1 "$rc" "push rejected: $out"
	assert_contains "$out" "docs/broken-note.md" "output names the file"
	assert_eq "" "$(git --git-dir="$PWD/meta-remote.git" branch --list docs/note)" "branch did not reach the remote"
}

# The meta-repository's hooks do not touch the clones' hook setup.
test_clone_hooks_stay_their_own() {
	cloned_workspace
	run_task api:install
	run_task web:install
	snapshot() {
		local c
		for c in api web; do
			echo "$c hooksPath=$(git -C "$WS/repos/$c" config --get core.hooksPath)"
			ls "$WS/repos/$c/.git/hooks" | grep -v '\.sample$' || true
		done
	}
	before="$(snapshot)"
	assert_contains "$before" "api hooksPath=.githooks"
	(cd "$WS" && hk install --mise >/dev/null 2>&1) || fail "hk install"
	assert_eq "$before" "$(snapshot)" "clone hook setup"
	assert_file "$WS/.git/hooks/pre-commit"
}

run_tests
