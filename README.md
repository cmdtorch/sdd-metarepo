# sdd-metarepo

A [Copier](https://copier.readthedocs.io) template for AI meta-repositories: one root repository from which a team works across several application repositories with one agent (Claude Code), one [OpenSpec](https://github.com/Fission-AI/OpenSpec) with [sdd-kit](https://github.com/cmdtorch/sdd_kit), one set of agent rules and one set of checks. The application repositories stay as they are; the meta-repository clones them into `repos/` and holds everything around them: `AGENTS.md`, decisions, branch rules, mise tasks, git hooks, an agent git guard, lint and tests.

## Quick start

You need only [mise](https://mise.jdx.dev) and git: mise fetches [uv](https://docs.astral.sh/uv/) into its cache, and uv runs Copier with its own Python.

```sh
mise x uv@latest -- uvx copier copy --trust gh:cmdtorch/sdd-metarepo my-meta
```

`--trust` is needed because the template runs tasks after copying. The wizard asks only project-level questions (below). With the last answer left at yes, it then runs `mise trust` and `mise run setup` in the new folder, and `setup`:

1. installs the root tools from `mise.toml` and the meta-repository's git hooks (`hk install --mise`);
2. installs sdd-kit with `mise run kit:install`, which also pins the OpenSpec version the kit needs, and writes `mise.lock` (exact tool versions and checksums, committed) when it is missing;
3. when `repos.toml` is empty and the terminal is interactive, runs the repository wizard (`mise run add-repo`): URL, name, rest branch, branch model and stack, in a loop;
4. clones every repository into `repos/<name>` on its rest branch;
5. runs each clone's `install` task, skipping tasks that are still stubs.

Then start Claude Code in the new folder and run `/bootstrap`, the AI onboarding. It reads each clone, configures its mise tasks (replacing the generated stubs `mise-tasks/<name>/{test,check,run,install}` with the clone's own commands), fills in the docs (command tables, environment notes, glossary) and the OpenSpec context, and asks questions with options where the clone leaves something open. `/bootstrap <name>` onboards one repository added later.

Commit the result in the new project, sdd-kit files included, on a branch with a pull request.

## Questions

| Question | Values | Used for |
| --- | --- | --- |
| `project_name` | text | README, `AGENTS.md`, docs |
| `project_slug` | derived from the name | folder name in the docs and the clone URL in the README |
| `github_org` | text | the README's clone URL; `add-repo` expands a bare name to `git@github.com:<org>/<name>.git` |
| `language` | `en` English, `ru` Русский | the language of the docs, task descriptions in chat, commits and pull requests, and of the text `repos:sync` generates; sdd-kit's `--questions-language`. OpenSpec artifacts follow sdd-kit: written in English, with clarifying questions in the project language. Code identifiers and sdd-kit files stay English |
| `tracker` | `jira`, `linear`, `github`, `none` | the tracker section of `AGENTS.md` and `docs/agents/ticket-workflow.md` (read-only tracker, question format, pull request titles); omitted for `none` |
| `agent_git_default` | `off` (default), `on` | whether the agent may commit and push by default; each developer can override it in `.claude/settings.local.json`. The agent never commits or pushes to `main` either way |
| `e2e` | yes (default), no | the end-to-end section of `AGENTS.md` and the `e2e/README.md` placeholder |
| `feature_prefix`, `bugfix_prefix` | `feature/`, `bugfix/` | branch names in the docs and in the generated branch rules |
| `run_setup` | yes (default), no | run `mise trust` and `mise run setup` right after copying |

Repositories are not asked by Copier: they are added after generation, so they can be added the same way later.

## Later: updates and more repositories

| What | Command, in the generated project |
| --- | --- |
| Template improvements | `mise x uv@latest -- uvx copier update --trust`; answers are in `.copier-answers.yml`. `repos.toml`, `GLOSSARY.md` and `docs/clone-backlog.md` belong to the project and are never overwritten |
| sdd-kit | `mise run kit:update` (latest release) or `SDD_KIT_REF=v0.5.0 mise run kit:install` |
| Another repository | `mise run add-repo`, or edit `repos.toml` and run `mise run repos:sync` |

## How the generated project works

### Repository registry

`repos.toml` is the only list of repositories. Each `[[repo]]` has `name`, `path` (`repos/<name>`), `url`, `ref` (the branch the clone rests on, default `dev`), `branch_model` and `stack` (free text for agents), plus optional fields that `/bootstrap` fills in: `env_file`, `env_example`, `env_notes`, `test_needs`, `notes` and `rules` (the clone's files agents read before editing it). The two branch models:

- `main-based`: a work branch starts from `main`, reaches `dev` for QA by pull request, and after QA its own pull request goes to `main`; `dev` is never merged into `main`. Conflicts with `dev` go through `merge/<name>-into-dev`.
- `dev-based`: a work branch starts from `dev` and its pull request goes to `dev`; `main` receives only merges of `dev`.

`scripts/repos.mjs` (Node 24, no packages) has five commands:

- `add`: interactive with numbered choices, or `--yes` with `--name --url --ref --branch-model --stack`; validates, appends to `repos.toml`, runs `sync`, offers to clone (`--clone`, `--no-clone`).
- `set`: `set <name> key=value ...` sets the optional fields of one entry (`env_file`, `env_example`, `env_notes`, `test_needs`, `notes`, `rules`, `stack`; an empty value removes one) and runs `sync`; `/bootstrap` uses it.
- `sync`: regenerates, between marker comments, `[bootstrap.repos]` in `mise.toml` (`# repos:begin`/`# repos:end`), `openspec/clones` when `openspec/` exists, the command tables (`<!-- repos:begin:commands -->`) and branch rules (`<!-- repos:begin:branches -->`) in `AGENTS.md`, the table in `docs/agents/branches.md` and in `repos/README.md` (`<!-- repos:begin -->`), the environment table in `docs/agents/environment.md` (`<!-- repos:begin:env -->`), all in the project language; and creates missing task stubs.
- `check`: fails when `repos.toml`, the `mise.toml` block, `openspec/clones`, the task folders and the generated sections disagree; `mise run check` runs it.
- `list`: tab-separated repositories, for the shell tasks.

### sdd-kit

The template contains no sdd-kit files and no OpenSpec pin. `scripts/kit.sh` (behind `mise run kit:install` and `kit:update`) resolves the highest release tag of `cmdtorch/sdd_kit` with `git ls-remote` (no pre-releases; `SDD_KIT_REF` overrides; `install` keeps an already installed version), reads the OpenSpec version from `npx github:cmdtorch/sdd_kit#<tag> --version`, pins it with `mise use "npm:@fission-ai/openspec@<version>"`, runs the installer with `--yes --metarepo <clones from repos.toml> --questions-language <English|Russian>`, re-syncs `openspec/clones` and runs the kit's doctor. The installer merges its hooks into `.claude/settings.json` and its lines into `.gitignore`. The kit's files are committed in the generated project: the whole team gets one kit version without installing anything, and an update is a reviewable pull request.

### Agent guard

`.claude/hooks/agent-git-guard.mjs` refuses agent commits and pushes unless `METAREPO_AGENT_COMMIT=1` / `METAREPO_AGENT_PUSH=1` are in the session environment (the shared default comes from `agent_git_default`), always refuses commits on and pushes to `main`, refuses `gh pr merge` and `git merge` on `main`, `dev` or a clone's rest branch, and refuses Claude attribution in commit and pull request texts. Its refusals name the base branch from the clone's branch model in `repos.toml`.

## Template layout

```text
copier.yml               questions, tasks, Copier settings
template/                the generated meta-repository (rendered with the .jinja suffix)
examples/en.yml, ru.yml  answer files for the render test
tests/render.sh          renders each example and runs the generated project's checks
.github/workflows/       CI running tests/render.sh
```

## For maintainers

### Testing

```sh
tests/render.sh                    # every example
tests/render.sh examples/ru.yml    # one example
KEEP=1 tests/render.sh             # keep the rendered projects
```

For each example it renders the working tree (uncommitted changes included) with `run_setup=false`, then, in the rendered project, checks the template's own promises (no `openspec/`, no OpenSpec pin, executable scripts), runs `node scripts/repos.mjs check`, `mise run lint` and `mise run test`. The generated tests need no clones, no sdd-kit and no network: they build stand-in repositories in temporary folders, and every test copy starts from an empty registry, so the same tests keep passing in a real project after repositories and the kit are added.

### Languages

Every human-facing document is a `.jinja` file whose whole body (front matter excluded) is one conditional:

```jinja
{% if language == 'ru' -%}
<!-- TODO-RU -->

English text, to be translated
{% else -%}
English text
{% endif -%}
```

The Russian branches are still English with a `<!-- TODO-RU -->` line; translating a file means replacing its Russian branch and removing that line. Keep these in step:

- the empty-section lines inside the marker comments in the Russian branches of `AGENTS.md`, `docs/agents/branches.md` and `repos/README.md` must equal the Russian strings in `scripts/repos.mjs` (`STRINGS.ru`), otherwise `repos.mjs check` fails on a fresh render;
- marker comments themselves are never translated;
- sdd-kit managed files are never translated.

Code, comments in scripts and configs, and test messages stay English.

### Conventions

- Shell tasks in `template/mise-tasks/` are plain files without `.jinja`, so `${#array[@]}` and similar never meet Jinja. Only files that need answers carry the suffix.
- The template's ignore file is `template/.gitignore.jinja`: a real `.gitignore` there would hide `template/repos/README.md.jinja` from git and from Copier.
- `hk.pkl` keeps hk's own `{{files}}` placeholder, so it has no `.jinja` suffix.
