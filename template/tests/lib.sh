#!/usr/bin/env bash
# Shared helpers for the meta-repository tests. Sourced from tests/*.sh:
#
#   source "$META_ROOT/tests/lib.sh"
#   test_something() { ... }
#   run_tests
#
# `mise run test` sets META_ROOT (the meta-repository root) and TEST_TMP (the
# test file's temporary folder, removed after the file). Each test_* function
# runs in its own subshell with its own folder inside TEST_TMP.

set -uo pipefail

: "${META_ROOT:?run the tests with mise run test}"
: "${TEST_TMP:?run the tests with mise run test}"

# Tests must not depend on the developer's global git and mise settings.
export GIT_CONFIG_GLOBAL="$TEST_TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name "Test"
git config --file "$GIT_CONFIG_GLOBAL" user.email "test@example.com"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false
# mise configs in the test temporary folders are trusted without writing to
# the machine's mise state.
export MISE_TRUSTED_CONFIG_PATHS="$TEST_TMP"
export MISE_STATE_DIR="$TEST_TMP/mise-state"
export MISE_YES=1
export MISE_QUIET=1
# setup never installs sdd-kit in the tests: that needs the network,
export SDD_KIT_SKIP=1
# nor writes mise.lock: resolving checksums needs the network too.
export MISE_LOCK_SKIP=1

_fail_count=0

fail() {
	echo "    FAIL: $*" >&2
	return 1
}

assert_eq() { # <expected> <actual> [description]
	[ "$1" = "$2" ] || fail "${3:-values differ}: expected [$1], got [$2]"
}

assert_contains() { # <text> <substring> [description]
	case "$1" in
	*"$2"*) ;;
	*) fail "${3:-missing substring}: [$2] not found in output:
$1" ;;
	esac
}

assert_not_contains() { # <text> <substring> [description]
	case "$1" in
	*"$2"*) fail "${3:-unexpected substring}: [$2] found in output:
$1" ;;
	*) ;;
	esac
}

assert_file() { [ -f "$1" ] || fail "no file $1"; }
assert_no_path() { [ ! -e "$1" ] || fail "path exists but should not: $1"; }

# A command's exit code without triggering set -e: rc=$(exit_code cmd args...)
exit_code() {
	"$@" >/dev/null 2>&1
	echo $?
}

# A bare remote repository with branches main and dev, one commit on each.
# make_remote <name> -> prints the path to the bare repository.
make_remote() {
	local name="$1" work="$PWD/src-$1-$RANDOM" bare="$PWD/remotes/$1.git"
	mkdir -p "$PWD/remotes"
	git init -q "$work"
	echo "# $name" >"$work/README.md"
	git -C "$work" add README.md
	git -C "$work" commit -qm "init $name"
	git -C "$work" checkout -qb dev
	echo "dev" >"$work/DEV"
	git -C "$work" add DEV
	git -C "$work" commit -qm "dev of $name"
	git clone -q --bare "$work" "$bare"
	rm -rf "$work"
	echo "$bare"
}

# Push a commit to a remote branch: push_commit <bare> <branch> <file> <text>
push_commit() {
	local bare="$1" branch="$2" file="$3" text="$4" work="$TEST_TMP/push-$RANDOM"
	git clone -q --branch "$branch" "$bare" "$work"
	mkdir -p "$(dirname "$work/$file")"
	printf '%s\n' "$text" >"$work/$file"
	git -C "$work" add "$file"
	git -C "$work" commit -qm "change $file"
	git -C "$work" push -q origin "$branch"
	rm -rf "$work"
}

# A copy of the meta-repository in the current test folder: all root files except
# OpenSpec changes (the clones are in .gitignore anyway), with its own git on main.
# The copy starts with an empty registry, whatever the project has registered: the
# tests register their own stand-in repositories.
# make_workspace -> prints the path to the copy.
make_workspace() {
	local ws="$PWD/ws" name
	mkdir -p "$ws"
	(
		cd "$META_ROOT" || exit 1
		git ls-files -co --exclude-standard -z |
			grep -zv -e '^openspec/changes/' |
			xargs -0 cp --parents -t "$ws"
	)
	for name in $(cd "$ws" && node scripts/repos.mjs list | cut -f1); do
		rm -rf "${ws:?}/mise-tasks/$name"
	done
	awk '/^\[\[[[:space:]]*repo[[:space:]]*\]\]/ { exit } { print }' "$META_ROOT/repos.toml" >"$ws/repos.toml"
	(cd "$ws" && node scripts/repos.mjs sync >/dev/null) || fail "sync of the empty registry in the copy"
	git -C "$ws" init -q
	git -C "$ws" add -A
	git -C "$ws" commit -qm "workspace" --no-verify
	echo "$ws"
}

# Clone a remote into the copy's clone on branch dev, as mise does.
clone_into() { # <ws> <clone path> <bare>
	git clone -q --branch dev "$3" "$1/$2"
}

run_tests() {
	local fn dir rc
	for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
		dir="$TEST_TMP/$fn"
		mkdir -p "$dir"
		(
			set -e
			cd "$dir"
			"$fn"
		)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			echo "  ok   $fn"
		else
			echo "  FAIL $fn"
			_fail_count=$((_fail_count + 1))
		fi
	done
	[ "$_fail_count" -eq 0 ]
}

# --- Stand-in clones -----------------------------------------------------------
#
# A stand-in repository has a stub command .stub/task.sh: it writes a line
# "<name> <args> pwd=<folder>" to $STUB_LOG and exits with the code from
# STUB_EXIT_<NAME> (api-test -> STUB_EXIT_API_TEST), 0 by default. Its pre-commit
# hook in .githooks rejects the file FORBIDDEN; the clone's install task turns the
# hooks on, as a real repository's install command would.

# make_stub_remote <name> -> path to the bare stand-in repository
make_stub_remote() {
	local name="$1" bare work
	bare="$(make_remote "$name")"
	work="$TEST_TMP/$name-src-$RANDOM"
	git clone -q --branch dev "$bare" "$work"
	mkdir -p "$work/.stub" "$work/.githooks"
	cat >"$work/.stub/task.sh" <<'STUB'
#!/usr/bin/env bash
name="$1"
shift
echo "$name $* pwd=$PWD" >>"${STUB_LOG:-/dev/null}"
var="STUB_EXIT_$(echo "$name" | tr 'a-z-' 'A-Z_')"
exit "${!var:-0}"
STUB
	cat >"$work/.githooks/pre-commit" <<HOOK
#!/usr/bin/env bash
if git diff --cached --name-only | grep -qx FORBIDDEN; then
	echo "$name hook rejected FORBIDDEN" >&2
	exit 1
fi
HOOK
	chmod +x "$work/.stub/task.sh" "$work/.githooks/pre-commit"
	echo "EXAMPLE=1" >"$work/.env.example"
	printf '.env\n' >"$work/.gitignore"
	git -C "$work" add -A
	git -C "$work" commit -qm "$name stub"
	git -C "$work" push -q origin dev
	rm -rf "$work"
	echo "$bare"
}

# Register a repository in the copy without questions:
# register <ws> <name> <url> <branch model>
register() {
	(cd "$1" && node scripts/repos.mjs add --yes --name "$2" --url "$3" --branch-model "$4" --stack "stub") >/dev/null
}

# Replace a clone's generated task stubs with commands that call its stand-in:
# configure_tasks <ws> <name>
configure_tasks() {
	local ws="$1" name="$2" task
	for task in test check run; do
		cat >"$ws/mise-tasks/$name/$task" <<TASK
#!/usr/bin/env bash
#MISE description="$name: $task (stand-in)"
set -euo pipefail
source "\$MISE_CONFIG_ROOT/scripts/clones.sh"
require_clone repos/$name
cd repos/$name
exec bash .stub/task.sh $name-$task "\$@"
TASK
	done
	cat >"$ws/mise-tasks/$name/install" <<TASK
#!/usr/bin/env bash
#MISE description="$name: install (stand-in)"
set -euo pipefail
source "\$MISE_CONFIG_ROOT/scripts/clones.sh"
require_clone repos/$name
cd repos/$name
git config core.hooksPath .githooks
exec bash .stub/task.sh $name-install "\$@"
TASK
	chmod +x "$ws/mise-tasks/$name/"*
}

# A copy of the meta-repository with two registered stand-in clones, not cloned:
# api (main-based) and web (dev-based), their tasks configured.
# Sets WS, API_REMOTE, WEB_REMOTE and STUB_LOG.
setup_stub_workspace() {
	WS="$(make_workspace)"
	API_REMOTE="$(make_stub_remote api)"
	WEB_REMOTE="$(make_stub_remote web)"
	register "$WS" api "$API_REMOTE" main-based
	register "$WS" web "$WEB_REMOTE" dev-based
	configure_tasks "$WS" api
	configure_tasks "$WS" web
	git -C "$WS" add -A
	git -C "$WS" commit -qm "stand-in repositories" --no-verify
	export STUB_LOG="$PWD/stub.log"
	: >"$STUB_LOG"
}

# The same copy with both clones on dev.
cloned_workspace() {
	setup_stub_workspace
	clone_into "$WS" repos/api "$API_REMOTE"
	clone_into "$WS" repos/web "$WEB_REMOTE"
}

# Run a mise task in the copy: all output in $OUT, the exit code in $RC.
run_task() {
	RC=0
	OUT="$(cd "$WS" && mise run "$@" 2>&1)" || RC=$?
}

# Run the registry script in the copy: all output in $OUT, the exit code in $RC.
run_repos() {
	RC=0
	OUT="$(cd "$WS" && node scripts/repos.mjs "$@" 2>&1)" || RC=$?
}

# A Markdown section from its heading to the next heading of the same level:
# section <file> "## Heading"
section() {
	awk -v h="$2" '
		BEGIN { lvl = length(h) - length(substr(h, index(h, " "))) }
		index($0, h) == 1 { on = 1; print; next }
		on && /^#+ / { l = index($0, " ") - 1; if (l <= lvl) exit }
		on { print }' "$1"
}

# The text between two marker lines of a file: between <file> <begin> <end>
between() {
	awk -v b="$2" -v e="$3" '$0 == e { on = 0 } on { print } $0 == b { on = 1 }' "$1"
}
