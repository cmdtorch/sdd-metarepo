#!/usr/bin/env bash
# Machine setup: setup, clone, clones on their rest branch, clone hooks, environment files, pull.
source "$META_ROOT/tests/lib.sh"

# A fresh machine: setup installs the hooks, clones every registered repository and
# runs each clone's install task.
test_fresh_machine() {
	setup_stub_workspace
	run_task setup
	assert_eq 0 "$RC" "setup succeeds: $OUT"
	assert_eq "$API_REMOTE" "$(git -C "$WS/repos/api" remote get-url origin)" "api origin"
	assert_eq "$WEB_REMOTE" "$(git -C "$WS/repos/web" remote get-url origin)" "web origin"
	assert_contains "$(cat "$STUB_LOG")" "api-install  pwd=$WS/repos/api" "api install ran"
	assert_contains "$(cat "$STUB_LOG")" "web-install  pwd=$WS/repos/web" "web install ran"
	# Every root tool is installed: mise sees none missing.
	missing="$(cd "$WS" && mise ls --current --missing 2>&1)"
	assert_eq "" "$missing" "missing tools"
	# The meta-repository's own hooks are installed.
	hooks="$(git -C "$WS" rev-parse --git-path hooks)"
	assert_file "$WS/$hooks/pre-commit"
	assert_file "$WS/$hooks/pre-push"
	assert_contains "$(cat "$WS/$hooks/pre-commit")" "hk" "pre-commit calls hk"
}

# Without a terminal and without repositories, setup does not ask and names add-repo.
test_setup_without_repositories() {
	WS="$(make_workspace)"
	run_task setup </dev/null
	assert_eq 0 "$RC" "setup succeeds: $OUT"
	assert_contains "$OUT" "mise run add-repo" "setup names add-repo"
	assert_contains "$OUT" "SDD_KIT_SKIP" "setup says the kit was skipped"
	assert_contains "$OUT" "/bootstrap" "setup points to /bootstrap"
}

# An install task that is still a stub is skipped with a hint, not a failure.
test_setup_skips_stub_install() {
	WS="$(make_workspace)"
	REMOTE="$(make_stub_remote svc)"
	register "$WS" svc "$REMOTE" dev-based
	run_task setup
	assert_eq 0 "$RC" "setup succeeds: $OUT"
	assert_contains "$OUT" "svc:install: not configured yet" "stub install named"
	assert_eq dev "$(git -C "$WS/repos/svc" branch --show-current)" "clone made"
}

# A fresh clone is on its rest branch.
test_fresh_clone_is_on_rest_branch() {
	setup_stub_workspace
	run_task clone
	assert_eq 0 "$RC" "clone succeeds: $OUT"
	assert_eq dev "$(git -C "$WS/repos/api" branch --show-current)" "api branch"
	assert_eq dev "$(git -C "$WS/repos/web" branch --show-current)" "web branch"
}

# A repeated setup keeps existing clones, their branches, commits and edits.
test_repeated_setup_keeps_clones() {
	setup_stub_workspace
	run_task setup
	assert_eq 0 "$RC" "first setup: $OUT"
	git -C "$WS/repos/api" checkout -qb feature/x
	echo local >"$WS/repos/api/LOCAL"
	git -C "$WS/repos/api" add LOCAL
	git -C "$WS/repos/api" commit -qm "local commit" --no-verify
	api_head="$(git -C "$WS/repos/api" rev-parse HEAD)"
	echo "edited" >>"$WS/repos/web/README.md"
	web_diff="$(git -C "$WS/repos/web" diff)"
	run_task setup
	assert_eq 0 "$RC" "repeated setup: $OUT"
	assert_eq feature/x "$(git -C "$WS/repos/api" branch --show-current)" "api branch"
	assert_eq "$api_head" "$(git -C "$WS/repos/api" rev-parse HEAD)" "api commits"
	assert_eq "$web_diff" "$(git -C "$WS/repos/web" diff)" "web edits"
}

# A clone with local changes is not overwritten.
test_clone_keeps_dirty_clone() {
	setup_stub_workspace
	run_task clone
	echo "my edit" >>"$WS/repos/web/README.md"
	before="$(git -C "$WS/repos/web" status --porcelain)"
	run_task clone
	assert_eq 0 "$RC" "clone: $OUT"
	assert_eq "$before" "$(git -C "$WS/repos/web" status --porcelain)" "clone state"
	assert_contains "$OUT" "repos/web: has uncommitted changes, clone left as is" "output names the clone"
}

# No access to a repository: the clone fails and names the repository.
test_no_access() {
	setup_stub_workspace
	sed -i "s|^url = \"$WEB_REMOTE\"|url = \"git@github.com:example/no-access.git\"|" "$WS/repos.toml"
	(cd "$WS" && node scripts/repos.mjs sync >/dev/null)
	export GIT_SSH_COMMAND='sh -c "echo \"git@github.com: Permission denied (publickey).\" >&2; exit 255"'
	run_task clone
	assert_eq 1 "$RC" "clone fails: $OUT"
	assert_contains "$OUT" "repos/web" "message names the clone"
	assert_contains "$OUT" "git@github.com:example/no-access.git" "message names the repository"
	assert_no_path "$WS/repos/web/.git"
}

# The clone's own hooks run after setup.
test_clone_hooks_after_setup() {
	setup_stub_workspace
	run_task setup
	echo bad >"$WS/repos/api/FORBIDDEN"
	git -C "$WS/repos/api" add FORBIDDEN
	rc=0
	out="$(git -C "$WS/repos/api" commit -m bad 2>&1)" || rc=$?
	assert_eq 1 "$rc" "commit rejected"
	assert_contains "$out" "api hook rejected FORBIDDEN" "api hook rejected it"
}

# Clone changes are invisible to the root git.
test_clone_changes_invisible() {
	setup_stub_workspace
	run_task clone
	echo new >"$WS/repos/api/NEW_FILE"
	status="$(git -C "$WS" status --porcelain --untracked-files=all)"
	assert_not_contains "$status" "repos/" "root git status"
	assert_eq "repos/README.md" "$(git -C "$WS" ls-files repos/)" "tracked in repos/"
}

# setup neither creates nor changes environment files.
test_setup_leaves_env_files() {
	setup_stub_workspace
	run_task clone
	printf 'SECRET=mine\n' >"$WS/repos/api/.env"
	sum="$(sha256sum <"$WS/repos/api/.env")"
	run_task setup
	assert_eq 0 "$RC" "setup: $OUT"
	assert_eq "$sum" "$(sha256sum <"$WS/repos/api/.env")" "api environment file"
	assert_no_path "$WS/repos/web/.env"
}

# --- Updating the meta-repository and the clones ----------------------------

# Both clones on dev and the copy's own bare upstream on main. Sets ROOT_REMOTE.
pulled_workspace() {
	cloned_workspace
	ROOT_REMOTE="$PWD/remotes/root.git"
	git clone -q --bare "$WS" "$ROOT_REMOTE"
	git -C "$WS" remote add origin "$ROOT_REMOTE"
	git -C "$WS" fetch -q origin
	git -C "$WS" branch -q --set-upstream-to=origin/main main
}

tip() { git --git-dir="$1" rev-parse "$2"; }
head_at() { git -C "$1" rev-parse HEAD; }
block() { sed -n "/^$1/,/^\$/p" <<<"$OUT"; }

test_pull_updates_root_and_clones() {
	pulled_workspace
	push_commit "$ROOT_REMOTE" main root.txt "new root"
	push_commit "$API_REMOTE" dev api.txt "new api"
	push_commit "$WEB_REMOTE" dev web.txt "new web"
	run_task pull
	assert_eq 0 "$RC" "pull succeeds: $OUT"
	assert_eq "$(tip "$ROOT_REMOTE" main)" "$(head_at "$WS")" "meta-repository at the tip of main"
	assert_eq "$(tip "$API_REMOTE" dev)" "$(head_at "$WS/repos/api")" "api at the tip of dev"
	assert_eq "$(tip "$WEB_REMOTE" dev)" "$(head_at "$WS/repos/web")" "web at the tip of dev"
	assert_not_contains "$OUT" "Not updated" "no failure list"
	assert_not_contains "$OUT" "No upstream" "no upstream list"
}

# A conflicting clone is left mid-rebase and listed; the others are still updated.
test_pull_clone_conflict() {
	pulled_workspace
	push_commit "$ROOT_REMOTE" main root.txt "new root"
	push_commit "$API_REMOTE" dev api.txt "new api"
	push_commit "$WEB_REMOTE" dev README.md "remote line"
	echo "local line" >"$WS/repos/web/README.md"
	git -C "$WS/repos/web" commit -qam "local change"
	run_task pull
	assert_eq 1 "$RC" "pull fails: $OUT"
	assert_eq "$(tip "$ROOT_REMOTE" main)" "$(head_at "$WS")" "meta-repository updated"
	assert_eq "$(tip "$API_REMOTE" dev)" "$(head_at "$WS/repos/api")" "api updated"
	rebase_dir="$(git -C "$WS/repos/web" rev-parse --git-path rebase-merge)"
	[ -d "$WS/repos/web/$rebase_dir" ] || fail "no rebase in progress in web"
	assert_contains "$(git -C "$WS/repos/web" diff --name-only --diff-filter=U)" "README.md" "conflict in README.md"
	failed="$(block "Not updated, resolve manually:")"
	assert_contains "$failed" "repos/web" "the failure list names web"
	assert_not_contains "$failed" "repos/api" "api is not in the failure list"
	assert_not_contains "$failed" "meta-repository" "the meta-repository is not in the failure list"
}

test_pull_clone_missing() {
	pulled_workspace
	rm -rf "$WS/repos/web"
	push_commit "$ROOT_REMOTE" main root.txt "new root"
	push_commit "$API_REMOTE" dev api.txt "new api"
	run_task pull
	assert_eq 1 "$RC" "pull fails: $OUT"
	assert_eq "$(tip "$ROOT_REMOTE" main)" "$(head_at "$WS")" "meta-repository updated"
	assert_eq "$(tip "$API_REMOTE" dev)" "$(head_at "$WS/repos/api")" "api updated"
	assert_contains "$OUT" "repos/web: missing" "output names the missing clone"
	assert_contains "$(block "Not updated, resolve manually:")" "repos/web (missing)" "the failure list names web"
}

test_pull_branch_without_upstream() {
	pulled_workspace
	git -C "$WS/repos/api" checkout -qb local-only
	api_head="$(head_at "$WS/repos/api")"
	push_commit "$ROOT_REMOTE" main root.txt "new root"
	push_commit "$WEB_REMOTE" dev web.txt "new web"
	run_task pull
	assert_eq 0 "$RC" "pull succeeds: $OUT"
	assert_eq "$(tip "$ROOT_REMOTE" main)" "$(head_at "$WS")" "meta-repository updated"
	assert_eq "$(tip "$WEB_REMOTE" dev)" "$(head_at "$WS/repos/web")" "web updated"
	assert_eq "$api_head" "$(head_at "$WS/repos/api")" "api left as is"
	assert_eq local-only "$(git -C "$WS/repos/api" branch --show-current)" "api branch"
	assert_contains "$(block "No upstream, not updated:")" "repos/api (local-only)" "the upstream list names api"
	assert_not_contains "$OUT" "Not updated, resolve manually" "no failure list"
}

# The meta-repository on a branch without upstream is left alone; the clones are still updated.
test_pull_root_without_upstream() {
	pulled_workspace
	git -C "$WS" checkout -qb local-only
	root_head="$(head_at "$WS")"
	push_commit "$ROOT_REMOTE" main root.txt "new root"
	push_commit "$API_REMOTE" dev api.txt "new api"
	push_commit "$WEB_REMOTE" dev web.txt "new web"
	run_task pull
	assert_eq 0 "$RC" "pull succeeds: $OUT"
	assert_eq "$(tip "$API_REMOTE" dev)" "$(head_at "$WS/repos/api")" "api updated"
	assert_eq "$(tip "$WEB_REMOTE" dev)" "$(head_at "$WS/repos/web")" "web updated"
	assert_eq "$root_head" "$(head_at "$WS")" "meta-repository left as is"
	assert_contains "$(block "No upstream, not updated:")" "meta-repository (local-only)" "the upstream list names the meta-repository"
	assert_not_contains "$OUT" "Not updated, resolve manually" "no failure list"
}

# A conflict in the meta-repository fails the task; the clones are still updated.
test_pull_root_conflict() {
	pulled_workspace
	push_commit "$ROOT_REMOTE" main CONFLICT.txt "remote line"
	echo "local line" >"$WS/CONFLICT.txt"
	git -C "$WS" add CONFLICT.txt
	git -C "$WS" commit -qm "local change" --no-verify
	push_commit "$API_REMOTE" dev api.txt "new api"
	push_commit "$WEB_REMOTE" dev web.txt "new web"
	run_task pull
	assert_eq 1 "$RC" "pull fails: $OUT"
	assert_eq "$(tip "$API_REMOTE" dev)" "$(head_at "$WS/repos/api")" "api updated"
	assert_eq "$(tip "$WEB_REMOTE" dev)" "$(head_at "$WS/repos/web")" "web updated"
	assert_contains "$(git -C "$WS" diff --name-only --diff-filter=U)" "CONFLICT.txt" "conflict in the meta-repository"
	failed="$(block "Not updated, resolve manually:")"
	assert_contains "$failed" "meta-repository" "the failure list names the meta-repository"
	assert_not_contains "$failed" "repos/" "no clone in the failure list"
}

test_pull_root_with_local_changes() {
	pulled_workspace
	push_commit "$ROOT_REMOTE" main root.txt "new root"
	echo "local edit" >>"$WS/GLOSSARY.md"
	diff_before="$(git -C "$WS" diff)"
	run_task pull
	assert_eq 0 "$RC" "pull succeeds: $OUT"
	assert_eq "$(tip "$ROOT_REMOTE" main)" "$(head_at "$WS")" "meta-repository at the tip of main"
	assert_eq "$diff_before" "$(git -C "$WS" diff)" "uncommitted changes kept"
	assert_eq "" "$(git -C "$WS" stash list)" "no leftover stash"
}

run_tests
