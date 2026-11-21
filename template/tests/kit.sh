#!/usr/bin/env bash
# sdd-kit installation: picking the release, offline against a local tag list.
source "$META_ROOT/tests/lib.sh"

# A bare repository with the given tags: make_tagged_remote <tag>...
make_tagged_remote() {
	local work="$PWD/kit-src" bare="$PWD/kit.git" tag
	git init -q "$work"
	git -C "$work" commit -q --allow-empty -m kit
	for tag in "$@"; do git -C "$work" tag "$tag"; done
	git clone -q --bare "$work" "$bare"
	echo "$bare"
}

# The highest release wins by semantic version; pre-releases are left out.
test_latest_tag() {
	remote="$(make_tagged_remote v0.2.0 v0.4.0 v0.10.0 v0.11.0-beta.1 not-a-version)"
	out="$(SDD_KIT_GIT="$remote" "$META_ROOT/scripts/kit.sh" latest-tag)"
	assert_eq v0.10.0 "$out" "latest tag"
}

# No release at all: update stops with a clear message before running anything.
test_no_release() {
	WS="$(make_workspace)"
	remote="$(make_tagged_remote v1.0.0-rc.1)"
	rc=0
	out="$(cd "$WS" && SDD_KIT_GIT="$remote" SDD_KIT_REF= scripts/kit.sh update 2>&1)" || rc=$?
	assert_eq 1 "$rc" "update fails: $out"
	assert_contains "$out" "Cannot find an sdd-kit release" "message"
	assert_contains "$out" "SDD_KIT_REF" "message names the override"
	assert_eq "" "$(git -C "$WS" status --porcelain)" "nothing changed"
}

run_tests
