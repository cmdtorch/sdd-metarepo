# Shared clone helpers for mise tasks. Sourced from mise-tasks/*:
#
#   source "$MISE_CONFIG_ROOT/scripts/clones.sh"
#
# The clone list comes from [bootstrap.repos] in mise.toml, which `mise run repos:sync` generates
# from repos.toml, not from the repos/ folder, so a missing clone shows up as missing.

# Clone state as JSON from mise: path, URL, state.
clones_status_json() {
	mise bootstrap repos status --json
}

# Paths of the declared clones, one per line: repos/api.
declared_clones() {
	clones_status_json | node -e '
		let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
			for (const r of JSON.parse(s).repos) console.log(r.path_raw);
		});'
}

# Lines "<path> <url> <ref> <state>", one per clone. mise states:
# current (on the listed ref), differs (on another branch or commit), dirty
# (has local changes), missing (no clone) and others.
clones_states() {
	clones_status_json | node -e '
		let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
			for (const r of JSON.parse(s).repos) console.log(r.path_raw, r.url, r.ref, r.state);
		});'
}

# Names of the registered repositories from repos.toml, one per line: api.
repo_names() {
	node "$MISE_CONFIG_ROOT/scripts/repos.mjs" list | cut -f1
}

# Stops the task if the clone is missing: require_clone repos/api
require_clone() {
	if [ ! -d "$1/.git" ]; then
		echo "$1: missing, the clone does not exist. Create it with: mise run clone" >&2
		exit 1
	fi
}

# True while a task file is still the stub written by `mise run repos:sync`: is_stub mise-tasks/api/install
is_stub() {
	grep -q '^# repos:stub' "$1"
}

# Ends a stub task: not_configured api:test
not_configured() {
	local task="$1"
	echo "$task: command not configured yet — run /bootstrap in Claude Code or edit mise-tasks/${task%%:*}/${task#*:}" >&2
	exit 1
}
