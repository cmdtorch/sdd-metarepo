#!/usr/bin/env bash
# Renders every example answer file in examples/ into a temporary folder and runs the
# generated project's offline checks there: its lint, its registry check and its tests.
# Needs uv (for uvx copier), mise and git; the generated project's tools come from mise.
#
#   tests/render.sh                  all examples
#   tests/render.sh examples/en.yml  one example
#   KEEP=1 tests/render.sh           keep the rendered folders and print where they are
set -euo pipefail
cd "$(dirname "$0")/.."
TEMPLATE="$PWD"

examples=("$@")
[ "${#examples[@]}" -gt 0 ] || examples=(examples/*.yml)

# The working tree is rendered, uncommitted changes included. With commits, copier is
# pointed at HEAD so it takes the dirty tree on top of it; without any commit it reads
# the folder as it is.
vcs=()
if git -C "$TEMPLATE" rev-parse -q --verify HEAD >/dev/null 2>&1; then
	vcs=(--vcs-ref HEAD)
fi

work="$(mktemp -d)"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$work"' EXIT

failed=()
for example in "${examples[@]}"; do
	name="$(basename "$example" .yml)"
	dst="$work/$name"
	echo "=== $example -> $dst"
	if ! uvx copier copy --quiet --defaults --trust "${vcs[@]}" --data-file "$example" --data run_setup=false "$TEMPLATE" "$dst"; then
		failed+=("$name: copier copy")
		continue
	fi
	(
		cd "$dst"
		export MISE_YES=1
		mise trust --quiet "$dst"
		status=0
		step() { # <what> <command...>
			local what="$1"
			shift
			echo "--- $name: $what"
			if ! "$@"; then
				echo "FAILED: $name: $what"
				status=1
			fi
		}
		# The template's own promises about the generated project.
		template_checks() {
			local ok=0
			[ -d .git ] || { echo "no git repository"; ok=1; }
			[ ! -e openspec ] || { echo "openspec/ must not be in the template"; ok=1; }
			! grep -q openspec mise.toml || { echo "mise.toml pins OpenSpec"; ok=1; }
			! grep -rIl --exclude-dir=.git 'TODO-RU' . >/dev/null || [ "$(sed -n 's/^language: //p' .copier-answers.yml)" = ru ] ||
				{ echo "TODO-RU markers in a non-Russian project"; ok=1; }
			for f in mise-tasks/setup mise-tasks/check scripts/repos.mjs scripts/kit.sh; do
				[ -x "$f" ] || { echo "$f is not executable"; ok=1; }
			done
			return "$ok"
		}
		step "template checks" template_checks
		step "repos.mjs check" node scripts/repos.mjs check
		step "mise run lint" mise run lint
		step "mise run test" mise run test
		exit "$status"
	) || failed+=("$name")
done

echo
if [ "${#failed[@]}" -gt 0 ]; then
	echo "Failed:"
	printf '  %s\n' "${failed[@]}"
	exit 1
fi
[ -z "${KEEP:-}" ] || echo "Rendered projects kept in $work"
echo "All examples rendered and passed: ${#examples[@]}"
