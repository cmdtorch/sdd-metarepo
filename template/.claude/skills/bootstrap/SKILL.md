---
name: bootstrap
description: AI onboarding of this meta-repository, run after `mise run setup`. Reads each clone in repos/ and, with the developer's confirmation, writes its mise tasks, command table, environment notes, OpenSpec context and project tools. Use on "/bootstrap" with or without a repository name, "set up the meta-repo", "onboard repositories", "configure a new repo", or when `mise run check` lists tasks that are not configured yet.
argument-hint: "[repository name]"
---

# Bootstrap the meta-repository

`mise run add-repo` registers a repository and creates its task stubs `mise-tasks/<name>/{test,check,run,install}`, which fail with "command not configured yet". This skill reads each clone, proposes its real commands and facts, and writes them after the developer confirms.

Argument: an optional repository name from `repos.toml` (`/bootstrap api`, printed by `add-repo`). Without it, onboard every repository that still has a stub task.

## Ground rules

- Talk to the developer in the project language (`language` in `.copier-answers.yml`: `en` English, `ru` Russian) and write every document in it. Follow the language rules in `AGENTS.md`: code identifiers, file and command names stay in English, and files managed by sdd-kit are never edited.
- Never invent a command. Every proposed command comes from a file you read in the clone (name the file), or from the developer's answer. When nothing is found, ask.
- Never create, change or delete an environment file, in the root or in a clone. Developers write them (`docs/agents/environment.md`). You may record which file is needed and show the `cp` command for the developer to run.
- Change nothing inside a clone. A desirable clone change (a missing `.env.example`, a broken script) goes into `docs/clone-backlog.md`.
- Never edit between `repos:begin` / `repos:end` markers by hand: change `repos.toml` (with `node scripts/repos.mjs set`) or the task files and run `node scripts/repos.mjs sync`. Never edit inside the sdd-kit block of `openspec/config.yaml` or the kit's own files.
- Commit only when agent commit is enabled for this developer (`docs/agents/agent-settings.md`), never on `main`.
- Idempotent: a repository whose four standard tasks are all configured is skipped unless the developer named it. Before overwriting a configured task, show the current command and ask.

## 1. Preconditions

Run from the root of the meta-repository (the folder with `AGENTS.md`, `repos.toml` and `mise.toml`); if not, stop and say so.

1. Read `.copier-answers.yml` (`project_name`, `language`, `tracker`, `github_org`, `feature_prefix`, `bugfix_prefix`, `agent_git_default`, `e2e`) and `repos.toml`.
2. Run `node scripts/repos.mjs check`. It names the stub tasks ("Not configured yet: ...") and any drift; on drift run `node scripts/repos.mjs sync` first.
3. `repos.toml` has no `[[repo]]` entry: `mise run add-repo` is interactive, so ask the developer instead with AskUserQuestion for each repository: the git URL (or a bare name for `git@github.com:<github_org>/<name>.git`), the name (default from the URL), the rest branch (default `dev`, never `main`), the branch model (`main-based` or `dev-based`, explained in `docs/agents/branches.md`) and a short stack hint. Then run `node scripts/repos.mjs add --yes --name <name> --url <url> --ref <ref> --branch-model <model> --stack "<stack>" --clone` once per repository. Alternatively the developer runs `mise run add-repo` in a terminal and calls `/bootstrap` again.
4. A registered clone is missing (`mise run status` shows `missing`): run `mise run clone`. If cloning fails (access), report it and continue with the clones that exist.
5. `openspec/tooling/kit.json` is missing (sdd-kit not installed): offer `mise run kit:install` (needs the network). Without the kit, skip the OpenSpec steps (5 and 6 below) and list them as remaining.

Pick the repositories: the argument if given (it must be in `repos.toml`), otherwise every repository with at least one task file still containing `# repos:stub`. If none is left, say that everything is configured, offer to reconfigure a named repository, and go to step 9.

## 2. Read the clone

For each chosen repository, read what exists in `repos/<name>/`, without running anything that changes it:

- Rules and docs: `AGENTS.md`, `CLAUDE.md` (may exist only on this machine, not in git), `.claude/rules/`, `README*`, `CONTRIBUTING*`, `docs/` entry pages.
- Task runners and manifests: `package.json` (`scripts`, `packageManager`, lock file: `package-lock.json` npm, `pnpm-lock.yaml` pnpm, `yarn.lock` yarn, `bun.lockb` bun), `pyproject.toml` (`[tool.*]` sections, `uv.lock`, `poetry.lock`), `requirements*.txt`, `Makefile`, `justfile`, `mise.toml` / `.mise.toml` and `mise-tasks/`, `Taskfile.yml`, `go.mod`, `Cargo.toml`, `composer.json`, `Gemfile`, `build.gradle*` / `pom.xml`, `manage.py`.
- Environment: `docker-compose*.yml` / `compose*.yml`, `Dockerfile`, `.env.example`, `.env.sample`, `.envs/`, `.env*.example`, settings code that reads environment variables (to find the file name the application loads).
- CI: `.github/workflows/*.yml`, `.gitlab-ci.yml`, `bitbucket-pipelines.yml`. CI steps show the commands the team trusts and the services tests need (a `services: postgres` block, a started dev server).
- Git hooks: `.husky/`, `.pre-commit-config.yaml`, `hk.pkl`, `lefthook.yml`, `.githooks/` with `core.hooksPath`, a `prepare` script.

Determine, each with the file it came from:

| Item | What to find |
| --- | --- |
| Stack | languages, frameworks, database, package manager |
| test | all tests, and how one test file is passed (the argument goes through as `"$@"`) |
| check | lint, format check and type check that run without a database or a running app; tests are not part of check |
| run | start the application for local development |
| install | dependencies and git hooks (for example `npm install` with husky's `prepare`, or `uv sync` then `uv run pre-commit install`) |
| Extra tasks | a background worker, migrations, a second app, code generation: only what developers run often |
| Environment | the file the application reads when run from its folder, its example, values that differ locally |
| Test prerequisites | database, cache, a running application or backend, browsers to install |
| Clone rules | the clone's files an agent must read before editing it |

When the clone has its own task runner (mise, make, just, npm scripts), prefer calling that over repeating its internals: `exec mise run test "$@"`, `exec make lint`, `exec npm run lint`.

## 3. Confirm with the developer

Ask per repository in one batch with AskUserQuestion (up to four questions per call; two calls if needed): `test`, `check`, `run`, `install`, then extra tasks, environment and test prerequisites. For each question:

- The first option is the detected command, labelled "(Recommended)", with its source file in the description. Other options are other grounded candidates (a CI step, a different script). Leave free input to the built-in "Other" choice; do not add made-up alternatives.
- When nothing was found, ask an open question with the options "I'll type the command" and "Leave it unconfigured for now". A task left unconfigured stays a stub and is listed at the end.
- Show the command exactly as it will run from `repos/<name>/`.

## 4. Write the tasks

Replace each confirmed stub in `mise-tasks/<name>/` with this pattern (the one in `mise-tasks/README.md`), deleting the `# repos:stub` comment lines:

```bash
#!/usr/bin/env bash
#MISE description="api: tests, optionally one test file (npm test in repos/api)"
set -euo pipefail
source "$MISE_CONFIG_ROOT/scripts/clones.sh"
require_clone repos/api
cd repos/api
exec npm test -- "$@"
```

- Keep `#MISE description="<name>: <what> (<clone command> in repos/<name>)"`. The four standard tasks keep the stub's English wording for `<what>`.
- Pass `"$@"` to the command that takes arguments. Use `exec` for the last command; earlier commands of a multi-step task (install: dependencies, then hooks) run without `exec`.
- An extra task is a new file `mise-tasks/<name>/<task>` (lower case, no extension) with the same pattern. Its description text after the `<name>:` prefix and before the parentheses becomes its row in the `AGENTS.md` command table, so write it in the project language, starting with what it does: `api: Background task worker (make worker in repos/api)`.
- Make every task file executable (`chmod +x`), then run `bash -n` on it and `mise tasks validate --errors-only`.
- Offer to run `mise run <name>:install` and then `mise run <name>:check` to prove the commands work. Install changes the clone's dependency folders, so ask first. A check failure that also happens on the clone's rest branch goes into `docs/clone-backlog.md`; it is not fixed here.

## 5. Record the facts in repos.toml

The generated sections read optional fields of the `[[repo]]` entry. Write them with `node scripts/repos.mjs set`, which validates them, keeps comments and runs `sync`:

```bash
node scripts/repos.mjs set api env_file=.env env_example=.env.example \
  "env_notes=DB_HOST=localhost when the database runs on your machine" \
  "test_needs=PostgreSQL" "notes=check runs without a database" \
  rules=CLAUDE.md,.claude/rules/,README.md
```

| Field | Shown in |
| --- | --- |
| `env_file`, `env_example` (paths inside the clone) | the Environment row of the clone's command table in `AGENTS.md`, and the table in `docs/agents/environment.md` |
| `env_notes` | the Notes column in `docs/agents/environment.md` |
| `test_needs` | a sentence under the clone's command table |
| `notes` | a sentence under the clone's command table |
| `rules` (paths inside the clone, comma-separated) | "Before editing a file in `repos/<name>`, read ..." above the command table |
| `stack` | the command table intro and `repos/README.md`, if the detected stack is better than the hint given at `add-repo` |

Write field values in the project language (paths and commands stay as they are). An empty value (`notes=`) removes a field. For `rules`, list only files that exist in the clone, its `CLAUDE.md` included when present on this machine.

## 6. Environment, OpenSpec and project tools

**`docs/agents/environment.md`.** `sync` fills its per-clone table between `<!-- repos:begin:env -->` and `<!-- repos:end:env -->`. If the file has no such markers, wrap the existing table (header included) with them, each marker on its own line with a blank line around it, and run `node scripts/repos.mjs sync`. Explanations that do not fit a table cell (how the application picks the file, the `cp` command, which values to get from the team) go under a heading per clone outside the markers. A clone without an example file gets an entry in `docs/clone-backlog.md`.

**`openspec/project-tools`** (sdd-kit project file; skip without the kit). One line per command-line tool the project's checks and tests need, in the form `<command> — <what needs it>`, for example:

```text
mise — tests, quality checks, starting the applications
uv — api tests and checks
npm — web checks, E2E
```

Read the format section in `openspec/protocols/apply.md` when it exists and follow it over this example. Derive the list from the confirmed tasks, show it, and write the file only after the developer confirms. Then run `node openspec/tooling/bin/doctor.mjs`, which checks that the tools are available.

**`openspec/config.yaml` `context`.** The kit keeps its own text in the `context: |` block between the lines `# >>> sdd-kit >>>` and `# <<< sdd-kit <<<`; those lines are part of the YAML text, not comments. Add the project's lines inside the same `context: |` block, above `# >>> sdd-kit >>>`, with the same indentation, and never touch the kit's lines. Without a `context:` key, add `context: |` with the project lines. Keep it to what an agent cannot infer from the code, about ten lines, in the project language:

- what the project is, in one sentence (ask the developer for it);
- each clone: `repos/<name>`, its role and stack;
- where specs live: OpenSpec changes and specs in the root `openspec/`, never in a clone's own `openspec/`;
- constraints across clones the developer confirms (for example "the web app talks to the API only through its REST endpoints").

Show the lines before writing them.

## 7. Glossary and checks (only on agreement)

**`GLOSSARY.md`.** Ask whether to draft it. If yes, propose up to fifteen domain terms found in the clones (model, entity and table names, enum values, route names, words the README defines), each with a one-line definition grounded in the code and the file it came from. Let the developer remove or correct terms, then write them in the file's existing format and the project language. Unclear terms go to the developer as questions, not guesses.

**ast-grep rules.** Offer at most three candidate rules, each based on a convention you observed in the code (with two or three example locations) that the clone's own linter does not already check. Create a rule only after the developer picks it, by following the `add-ast-grep-rule` skill.

## 8. Clone rules

The `rules` field (step 5) is how agents learn which clone docs to read: `sync` writes it into each clone's section of `AGENTS.md`. Tell the developer which files were recorded per clone, and that a clone's `CLAUDE.md` absent from git exists only on machines that have it.

## 9. Finish

1. Run `node scripts/repos.mjs sync`, then `mise run lint`, `mise run test` and `mise run check`. Fix what fails in the meta-repository files you changed. A clone's own check failure that already exists on its rest branch goes into `docs/clone-backlog.md`. Run `node openspec/tooling/bin/doctor.mjs` when it exists.
2. Summarize per repository: tasks configured (with the commands), extra tasks, fields recorded, documents changed, and what remains manual:
   - environment files the developer must create (with the `cp` command from the example),
   - tasks left unconfigured, and clone issues recorded in `docs/clone-backlog.md`,
   - steps skipped (no sdd-kit, a missing clone).
3. Commit only if agent commit is enabled: on a working branch from an updated `main` (for example `<feature_prefix>bootstrap`), with a Conventional Commits message and no Claude attribution. Otherwise list the changed files and suggest the message, for example `chore: configure repository commands and docs with /bootstrap`.
