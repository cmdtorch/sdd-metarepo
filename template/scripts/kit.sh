#!/usr/bin/env bash
# Installs or updates sdd-kit (OpenSpec with clarifying questions, traceability and test review).
#
#   scripts/kit.sh install      the version already installed, else the latest release
#   scripts/kit.sh update       the latest release
#   scripts/kit.sh latest-tag   print the latest release tag
#
# SDD_KIT_REF=<tag> picks a version for install and update. The template ships no kit files and no
# OpenSpec pin: the kit's installer reports the OpenSpec version it needs, `mise use` pins it in
# mise.toml, and the installer writes openspec/, the kit hooks in .claude/settings.json and the
# .gitignore lines. Everything it writes is committed, so the team shares one kit version and an
# update arrives through a pull request (docs/agents/tooling.md).
set -euo pipefail
cd "$(dirname "$0")/.."

KIT_GIT="${SDD_KIT_GIT:-https://github.com/cmdtorch/sdd_kit.git}"
KIT_NPX="${SDD_KIT_NPX:-github:cmdtorch/sdd_kit}"

# Highest release tag by semantic version, pre-releases (v1.2.0-beta.1) left out.
latest_tag() {
	git ls-remote --tags --refs "$KIT_GIT" |
		sed 's#.*refs/tags/##' |
		grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' |
		sort -V |
		tail -1
}

# The installed kit version as a tag (v0.4.0), empty when the kit is not installed.
installed_tag() {
	[ -f openspec/tooling/kit.json ] || return 0
	node -e 'const k = require(process.argv[1]); console.log(`v${k.kitVersion}`)' "$PWD/openspec/tooling/kit.json"
}

# The language of clarifying questions from the project language in .copier-answers.yml.
questions_language() {
	case "$(sed -nE 's/^language:[[:space:]]*["'\'']?([a-z]+).*/\1/p' .copier-answers.yml 2>/dev/null)" in
	ru) echo Russian ;;
	*) echo English ;;
	esac
}

cmd="${1:-}"
case "$cmd" in
latest-tag)
	latest_tag
	exit 0
	;;
install | update) ;;
*)
	echo "Usage: scripts/kit.sh <install|update|latest-tag>" >&2
	exit 2
	;;
esac

ref="${SDD_KIT_REF:-}"
if [ -z "$ref" ] && [ "$cmd" = install ]; then
	ref="$(installed_tag)"
fi
if [ -z "$ref" ]; then
	ref="$(latest_tag)" || true
	if [ -z "$ref" ]; then
		echo "Cannot find an sdd-kit release in $KIT_GIT. Check the network, or set SDD_KIT_REF=<tag>." >&2
		exit 1
	fi
fi

version="$(npx -y "$KIT_NPX#$ref" --version)"
openspec_version="$(sed -nE 's/.*\(OpenSpec ([^)]+)\).*/\1/p' <<<"$version")"
if [ -z "$openspec_version" ]; then
	echo "sdd-kit $ref did not report its OpenSpec version (got: $version)" >&2
	exit 1
fi
echo "== $version"

# Pin the OpenSpec CLI the kit needs; the installer refuses any other version.
mise use "npm:@fission-ai/openspec@$openspec_version"

entries="$(node scripts/repos.mjs list | cut -f2 | paste -sd, -)"
mise exec -- npx -y "$KIT_NPX#$ref" "$cmd" --yes "--metarepo=$entries" --questions-language "$(questions_language)"

# The installer merges entries into openspec/clones; sync puts them under the generated markers.
node scripts/repos.mjs sync

if [ -f openspec/tooling/bin/doctor.mjs ]; then
	echo "== node openspec/tooling/bin/doctor.mjs"
	mise exec -- node openspec/tooling/bin/doctor.mjs || echo "The health check reported problems; see above."
fi
echo
echo "Commit the kit files: openspec/, .claude/, .gitignore, mise.toml, and mise.lock and .mise/ when present (see docs/agents/tooling.md)."
