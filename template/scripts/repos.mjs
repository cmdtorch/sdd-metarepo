#!/usr/bin/env node
// repos.mjs — the repository registry of the meta-repository. Plain Node 24, no packages.
//
//   node scripts/repos.mjs add [--name <name>] [--url <url>] [--ref <branch>]
//                              [--branch-model main-based|dev-based] [--stack <text>] [--yes]
//                              [--clone | --no-clone]
//   node scripts/repos.mjs set <name> key=value ...   (optional fields below; an empty value removes one)
//   node scripts/repos.mjs sync
//   node scripts/repos.mjs check
//   node scripts/repos.mjs list      (tab-separated: name path url ref branch_model, one repository per line)
//
// repos.toml in the root is the source of truth. `sync` regenerates everything that lists the
// repositories, between marker comments, and leaves the rest of each file alone:
//   mise.toml               [bootstrap.repos]                     # repos:begin / # repos:end
//   openspec/clones         the sdd-kit clone list (only when openspec/ exists)
//   AGENTS.md               command tables and branch rules        <!-- repos:begin:commands -->, :branches
//   docs/agents/branches.md the per-repository table              <!-- repos:begin --> / <!-- repos:end -->
//   repos/README.md         the clone table                       <!-- repos:begin --> / <!-- repos:end -->
//   docs/agents/environment.md  the environment file table       <!-- repos:begin:env --> (only when the markers exist)
// and creates the task stubs mise-tasks/<name>/{test,check,run,install} when they are missing. A stub
// fails with "command not configured yet" until /bootstrap or a developer writes the clone's own command.
// Generated text follows the project language (`language` in .copier-answers.yml).
//
// Optional per-repository fields, written by /bootstrap or by hand (paths relative to the clone):
//   env_file, env_example   the environment file the application reads and its example
//   env_notes               what differs locally (environment table)
//   test_needs              what the clone's tests need, e.g. "PostgreSQL, the backend running"
//   notes                   anything else agents must know about the commands
//   rules = ["CLAUDE.md", ".claude/rules/"]   the clone's files agents read before editing it
// A clone's extra tasks (any file in mise-tasks/<name>/ besides the four standard ones) are listed in
// its command table with the text of their `#MISE description="<name>: <text>"` line.
//
// `check` verifies that repos.toml, the mise.toml block, openspec/clones, the task folders and the
// generated sections agree; `mise run check` runs it.
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REGISTRY = 'repos.toml';
const MODELS = ['main-based', 'dev-based'];
const TASKS = ['test', 'check', 'run', 'install'];
const NAME = /^[a-z0-9][a-z0-9_-]*$/;
// Names taken by the meta-repository's own tasks (mise-tasks/<name>/) or reserved by sdd-kit.
const RESERVED = new Set(['root', 'kit', 'repos', 'e2e', 'setup', 'clone', 'pull', 'status', 'check', 'lint', 'test', 'add-repo']);
const STUB_MARK = '# repos:stub';
// Optional string fields of a [[repo]] entry, in the order `add` writes them.
const OPTIONAL = ['env_file', 'env_example', 'env_notes', 'test_needs', 'notes'];
// Optional fields holding a list of strings.
const LISTS = ['rules'];

// --- Strings ---------------------------------------------------------------------------

const STRINGS = {
  en: {
    commandsEmpty: 'No repositories yet. Add one with `mise run add-repo`; it creates the `mise run <name>:*` tasks.',
    commandsIntro: (r) => `\`${r.path}\`${r.stack ? `, ${md(r.stack)}` : ''}; branch model \`${r.branch_model}\` ([docs/agents/branches.md](docs/agents/branches.md)).`,
    commandsHead: ['What', 'Command'],
    commandRows: (n) => [
      ['One test file', `\`mise run ${n}:test <path to test file>\``],
      ['All tests', `\`mise run ${n}:test\``],
      ['Quality checks', `\`mise run ${n}:check\``],
      ['Run the application', `\`mise run ${n}:run\``],
      ['Dependencies and hooks', `\`mise run ${n}:install\``],
    ],
    commandsRules: (r, files) => `Before editing a file in \`${r.path}\`, read ${files.join(', ')}, whichever exist.`,
    envLabel: 'Environment',
    envValue: (file, example) => (example ? `file ${file}, example ${example}` : `file ${file}, no example`),
    testNeeds: (r) => `Tests need ${prose(r.test_needs).replace(/\.$/, '')}.`,
    envHead: ['Clone', 'File', 'Example', 'Notes'],
    noExample: 'none',
    branchesEmpty: 'No repositories yet; each repository added with `mise run add-repo` gets its rule here.',
    branchMain: (r, p) =>
      `\`${r.name}\` (main-based): a \`${p.feature}<name>\` or \`${p.bugfix}<ticket-or-name>\` branch is created from an updated \`main\`. ` +
      `It reaches \`${r.ref}\` for QA only by a pull request, and after QA approves, its own pull request goes to \`main\`. ` +
      `\`${r.ref}\` is never merged into \`main\` or into a work branch. ` +
      `Conflicts with \`${r.ref}\` go through a merge branch \`merge/<name>-into-${r.ref}\`; fixes after review or QA go on the work branch.`,
    branchDev: (r, p) =>
      `\`${r.name}\` (dev-based): a \`${p.feature}<name>\` or \`${p.bugfix}<ticket-or-name>\` branch is created from an updated \`${r.ref}\`. ` +
      `Its pull request goes to \`${r.ref}\`. \`main\` receives only merges of \`${r.ref}\`.`,
    tableEmpty: 'No repositories yet. `mise run add-repo` adds a row for each repository.',
    tableHead: ['Repository', 'Branch model', 'Rests on', 'Work branch from', 'Pull requests'],
    prMain: (r) => `into \`${r.ref}\` for QA, then its own into \`main\``,
    prDev: (r) => `into \`${r.ref}\``,
    reposEmpty: 'No repositories yet. Add one with `mise run add-repo`.',
    reposHead: ['Clone', 'Repository', 'Rests on', 'Branch model', 'Stack'],
    // prompts
    askAdd: 'Add a repository?',
    askAddMore: 'Add another repository?',
    yes: 'yes',
    no: 'no',
    askUrl: (org) => `Git URL of the repository${org ? ` (or a name for git@github.com:${org}/<name>.git)` : ''}: `,
    askName: 'Name (folder repos/<name>, tasks mise run <name>:*)',
    askRef: 'Branch the clone rests on (the test server branch)',
    askModel: 'Branch model:',
    modelMain: 'main-based: work branch from main, pull request to the rest branch for QA, its own pull request to main after QA',
    modelDev: 'dev-based: work branch from the rest branch, pull request to it, main receives only its merges',
    askStack: 'Stack, a free-text hint for agents (for example "Go, PostgreSQL")',
    choose: 'Choose',
    added: (r) => `Added ${r.name} (${r.path}, ${r.branch_model}).`,
    askClone: 'Clone the new repositories now?',
    nothingAdded: 'No repository added.',
    bootstrapHint: (names) =>
      `Next: start Claude Code in the root and run /bootstrap${names.length === 1 ? ` ${names[0]}` : ''} to configure the commands of ${names.join(', ')}.`,
  },
  ru: {
    commandsEmpty: 'Репозиториев пока нет. Добавьте первый командой `mise run add-repo`; она создаст задачи `mise run <имя>:*`.',
    commandsIntro: (r) => `\`${r.path}\`${r.stack ? `, ${md(r.stack)}` : ''}; модель веток \`${r.branch_model}\` ([docs/agents/branches.md](docs/agents/branches.md)).`,
    commandsHead: ['Что', 'Команда'],
    commandRows: (n) => [
      ['Один файл тестов', `\`mise run ${n}:test <путь к файлу тестов>\``],
      ['Все тесты', `\`mise run ${n}:test\``],
      ['Проверки качества', `\`mise run ${n}:check\``],
      ['Запуск приложения', `\`mise run ${n}:run\``],
      ['Зависимости и хуки', `\`mise run ${n}:install\``],
    ],
    commandsRules: (r, files) => `Перед правкой файла в \`${r.path}\` прочитайте ${files.join(', ')}, те из них, что существуют.`,
    envLabel: 'Окружение',
    envValue: (file, example) => (example ? `файл ${file}, пример ${example}` : `файл ${file}, примера нет`),
    testNeeds: (r) => `Для тестов нужно: ${prose(r.test_needs).replace(/\.$/, '')}.`,
    envHead: ['Клон', 'Файл', 'Пример', 'Заметки'],
    noExample: 'нет',
    branchesEmpty: 'Репозиториев пока нет; каждый репозиторий, добавленный через `mise run add-repo`, получит здесь своё правило.',
    branchMain: (r, p) =>
      `\`${r.name}\` (main-based): ветка \`${p.feature}<имя>\` или \`${p.bugfix}<задача-или-имя>\` создаётся от обновлённой \`main\`. ` +
      `В \`${r.ref}\` для QA она попадает только через pull request, а после одобрения QA её собственный pull request идёт в \`main\`. ` +
      `\`${r.ref}\` никогда не сливается в \`main\` или в рабочую ветку. ` +
      `Конфликты с \`${r.ref}\` решаются в ветке слияния \`merge/<имя>-into-${r.ref}\`; исправления после ревью или QA идут в рабочую ветку.`,
    branchDev: (r, p) =>
      `\`${r.name}\` (dev-based): ветка \`${p.feature}<имя>\` или \`${p.bugfix}<задача-или-имя>\` создаётся от обновлённой \`${r.ref}\`. ` +
      `Её pull request идёт в \`${r.ref}\`. \`main\` получает только слияния \`${r.ref}\`.`,
    tableEmpty: 'Репозиториев пока нет. `mise run add-repo` добавит строку для каждого репозитория.',
    tableHead: ['Репозиторий', 'Модель веток', 'Ветка покоя', 'Рабочая ветка от', 'Pull request'],
    prMain: (r) => `в \`${r.ref}\` для QA, затем собственный в \`main\``,
    prDev: (r) => `в \`${r.ref}\``,
    reposEmpty: 'Репозиториев пока нет. Добавьте первый командой `mise run add-repo`.',
    reposHead: ['Клон', 'Репозиторий', 'Ветка покоя', 'Модель веток', 'Стек'],
    askAdd: 'Добавить репозиторий?',
    askAddMore: 'Добавить ещё один репозиторий?',
    yes: 'да',
    no: 'нет',
    askUrl: (org) => `Git URL репозитория${org ? ` (или имя для git@github.com:${org}/<имя>.git)` : ''}: `,
    askName: 'Имя (папка repos/<имя>, задачи mise run <имя>:*)',
    askRef: 'Ветка покоя: на ней клон стоит между задачами (ветка тестового сервера)',
    askModel: 'Модель веток:',
    modelMain: 'main-based: рабочая ветка от main, pull request в ветку покоя для QA, после QA собственный pull request в main',
    modelDev: 'dev-based: рабочая ветка от ветки покоя, pull request в неё, main получает только её слияния',
    askStack: 'Стек, свободная подсказка для агентов (например "Go, PostgreSQL")',
    choose: 'Выберите',
    added: (r) => `Добавлен ${r.name} (${r.path}, ${r.branch_model}).`,
    askClone: 'Склонировать новые репозитории сейчас?',
    nothingAdded: 'Ни один репозиторий не добавлен.',
    bootstrapHint: (names) =>
      `Дальше: запустите Claude Code в корне и выполните /bootstrap${names.length === 1 ? ` ${names[0]}` : ''}, чтобы настроить команды ${names.join(', ')}.`,
  },
};

/** Free text safe inside a Markdown table cell. */
function md(text) {
  return String(text).replace(/\|/g, '\\|').replace(/\s+/g, ' ').trim();
}

/** Free prose from repos.toml for the docs: md() with bare URLs as autolinks (rumdl MD034). */
function prose(text) {
  return md(text).replace(/(^|[\s(])(https?:\/\/[^\s<>()`|]+?)([.,;:]?(?=\s|$|\)))/g, '$1<$2>$3');
}

// --- Project settings ------------------------------------------------------------------

/** The copier answers as a flat object of strings. */
function answers() {
  const text = readText(join(ROOT, '.copier-answers.yml')) || '';
  const out = {};
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2');
  }
  return out;
}

function settings() {
  const a = answers();
  const language = STRINGS[a.language] ? a.language : 'en';
  return {
    language,
    t: STRINGS[language],
    org: a.github_org || '',
    prefixes: { feature: a.feature_prefix || 'feature/', bugfix: a.bugfix_prefix || 'bugfix/' },
  };
}

// --- Registry --------------------------------------------------------------------------

function readText(p) {
  try {
    return readFileSync(p, 'utf8');
  } catch {
    return null;
  }
}

/** A TOML basic string value, or null when the text is not one. */
function tomlString(raw) {
  const m = raw.match(/^"((?:[^"\\]|\\.)*)"\s*(#.*)?$/);
  if (!m) return null;
  return m[1].replace(/\\(["\\nt])/g, (_, c) => ({ n: '\n', t: '\t' })[c] ?? c);
}

/** A single-line TOML array of basic strings (`["a", "b"]`), or null when the text is not one. */
function tomlStringArray(raw) {
  const m = raw.match(/^\[(.*)\]\s*(#.*)?$/);
  if (!m) return null;
  const out = [];
  let rest = m[1].trim();
  while (rest) {
    const item = rest.match(/^"((?:[^"\\]|\\.)*)"\s*(,\s*)?/);
    if (!item) return null;
    out.push(tomlString(`"${item[1]}"`));
    rest = rest.slice(item[0].length);
    if (rest && !item[2]) return null;
  }
  return out;
}

const quote = (s) => `"${String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

/**
 * Parses repos.toml: only `[[repo]]` tables with `key = "string"` lines and comments.
 * Returns { repos, errors } with errors as "repos.toml:<line>: <message>".
 */
export function parseRegistry(text) {
  const repos = [];
  const errors = [];
  let cur = null;
  String(text ?? '')
    .split(/\r?\n/)
    .forEach((raw, idx) => {
      const line = raw.trim();
      const at = `${REGISTRY}:${idx + 1}`;
      if (!line || line.startsWith('#')) return;
      if (/^\[\[\s*repo\s*\]\]\s*(#.*)?$/.test(line)) {
        cur = { line: idx + 1 };
        repos.push(cur);
        return;
      }
      const kv = line.match(/^([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(.*)$/);
      if (!kv || !cur) {
        errors.push(`${at}: expected [[repo]] or key = "value"`);
        return;
      }
      if (LISTS.includes(kv[1])) {
        const list = tomlStringArray(kv[2]);
        if (list === null) errors.push(`${at}: the value of ${kv[1]} must be a list of strings on one line, ["a", "b"]`);
        else cur[kv[1]] = list;
        return;
      }
      const value = tomlString(kv[2]);
      if (value === null) errors.push(`${at}: the value of ${kv[1]} must be a "string"`);
      else cur[kv[1]] = value;
    });
  return { repos, errors };
}

/** Why a clone URL is malformed, or '' when it looks right: a URL pasted twice has two schemes or user@host parts. */
export function urlProblem(url) {
  if (/\s/.test(url)) return `url \`${url}\`: has spaces`;
  if ((url.match(/[A-Za-z][A-Za-z0-9+.-]*:\/\/|[\w.-]+@[\w.-]+:/g) ?? []).length > 1) return `url \`${url}\`: looks like two URLs glued together`;
  return '';
}

/** Problems of one repository entry, given the entries before it. */
export function validateRepo(r, others = []) {
  const problems = [];
  if (!r.name) problems.push('name is missing');
  else if (!NAME.test(r.name)) problems.push(`name \`${r.name}\`: use lower case letters, digits, '-' and '_'`);
  else if (RESERVED.has(r.name)) problems.push(`name \`${r.name}\` is taken by a meta-repository task or sdd-kit`);
  if (r.name && r.path !== `repos/${r.name}`) problems.push(`path must be repos/${r.name}, not ${r.path ?? '(missing)'}`);
  if (!r.url) problems.push('url is missing');
  else if (urlProblem(r.url)) problems.push(urlProblem(r.url));
  if (!r.ref) problems.push('ref is missing');
  else if (!/^[A-Za-z0-9._/-]+$/.test(r.ref) || r.ref === 'main') problems.push(`ref \`${r.ref}\`: give the branch the clone rests on, other than main`);
  if (!MODELS.includes(r.branch_model)) problems.push(`branch_model must be ${MODELS.join(' or ')}, not ${r.branch_model ?? '(missing)'}`);
  if (others.some((o) => o.name === r.name)) problems.push(`name \`${r.name}\` is already registered`);
  const insideClone = (p) => p && !p.startsWith('/') && !p.split('/').includes('..');
  for (const key of ['env_file', 'env_example']) {
    if (r[key] && !insideClone(r[key])) problems.push(`${key} \`${r[key]}\`: give a path inside the clone, relative to repos/${r.name}`);
  }
  for (const p of r.rules ?? []) {
    if (!insideClone(p)) problems.push(`rules entry \`${p}\`: give a path inside the clone, relative to repos/${r.name}`);
  }
  return problems;
}

function loadRegistry() {
  const text = readText(join(ROOT, REGISTRY));
  if (text === null) return { text: null, repos: [], errors: [`${REGISTRY}: file is missing`] };
  const { repos, errors } = parseRegistry(text);
  repos.forEach((r, i) => {
    for (const p of validateRepo(r, repos.slice(0, i))) errors.push(`${REGISTRY}:${r.line}: ${p}`);
  });
  return { text, repos, errors };
}

function registryEntry(r) {
  const lines = ['[[repo]]'];
  for (const key of ['name', 'path', 'url', 'ref', 'branch_model', 'stack']) lines.push(`${key} = ${quote(r[key] ?? '')}`);
  for (const key of OPTIONAL) if (r[key]) lines.push(`${key} = ${quote(r[key])}`);
  for (const key of LISTS) if (r[key]?.length) lines.push(`${key} = [${r[key].map(quote).join(', ')}]`);
  return lines.join('\n');
}

function appendToRegistry(r) {
  const p = join(ROOT, REGISTRY);
  const text = readText(p) ?? '';
  const sep = text === '' ? '' : text.endsWith('\n\n') ? '' : text.endsWith('\n') ? '\n' : '\n\n';
  writeFileSync(p, `${text}${sep}${registryEntry(r)}\n`);
}

// --- Generated text --------------------------------------------------------------------

const table = (head, rows) => [`| ${head.join(' | ')} |`, `| ${head.map(() => '---').join(' | ')} |`, ...rows.map((r) => `| ${r.join(' | ')} |`)].join('\n');

function miseBlock(repos) {
  return ['[bootstrap.repos]', ...repos.map((r) => `${quote(r.path)} = { url = ${quote(r.url)}, ref = ${quote(r.ref)} }`)].join('\n');
}

function clonesBlock(repos) {
  return repos.map((r) => r.path).join('\n');
}

/** A path inside a clone as inline code from the root: repos/api/.env. */
const inClone = (r, p) => `\`${r.path}/${String(p).replace(/^\.\//, '')}\``;

/**
 * A clone's extra tasks: every executable file in mise-tasks/<name>/ besides the standard four,
 * as { task, what } with `what` from its `#MISE description="<name>: <text>"` line.
 */
function extraTasks(r) {
  let files = [];
  try {
    files = readdirSync(join(ROOT, 'mise-tasks', r.name), { withFileTypes: true })
      .filter((d) => d.isFile() && !TASKS.includes(d.name) && !d.name.includes('.'))
      .map((d) => d.name)
      .sort();
  } catch {
    /* no task folder yet */
  }
  return files.map((task) => {
    const text = readText(join(ROOT, 'mise-tasks', r.name, task)) || '';
    const desc = (text.match(/^#MISE description="(.*)"\s*$/m) || [])[1] || task;
    const what = md(desc.replace(new RegExp(`^${r.name}:\\s*`, 'i'), '').replace(/\s*\([^)]*\)\s*$/, ''));
    return { task, what: what.charAt(0).toUpperCase() + what.slice(1) };
  });
}

function commandsBlock(repos, s) {
  if (!repos.length) return s.t.commandsEmpty;
  return repos
    .map((r) => {
      const rows = [...s.t.commandRows(r.name), ...extraTasks(r).map((x) => [x.what, `\`mise run ${r.name}:${x.task}\``])];
      if (r.env_file) rows.push([s.t.envLabel, s.t.envValue(inClone(r, r.env_file), r.env_example ? inClone(r, r.env_example) : '')]);
      const out = [`### ${r.name}`, '', s.t.commandsIntro(r)];
      if (r.rules?.length) out.push('', s.t.commandsRules(r, r.rules.map((p) => inClone(r, p))));
      out.push('', table(s.t.commandsHead, rows));
      const after = [r.test_needs ? s.t.testNeeds(r) : '', r.notes ? prose(r.notes) : ''].filter(Boolean).join(' ');
      if (after) out.push('', after);
      return out.join('\n');
    })
    .join('\n\n');
}

function envTableBlock(repos, s) {
  const rows = repos
    .filter((r) => r.env_file || r.env_notes)
    .map((r) => [`\`${r.name}\``, r.env_file ? inClone(r, r.env_file) : '-', r.env_example ? inClone(r, r.env_example) : s.t.noExample, r.env_notes ? prose(r.env_notes) : '-']);
  return table(s.t.envHead, rows);
}

function branchesBlock(repos, s) {
  if (!repos.length) return s.t.branchesEmpty;
  return repos.map((r) => `- ${r.branch_model === 'main-based' ? s.t.branchMain(r, s.prefixes) : s.t.branchDev(r, s.prefixes)}`).join('\n');
}

function branchTableBlock(repos, s) {
  if (!repos.length) return s.t.tableEmpty;
  return table(
    s.t.tableHead,
    repos.map((r) => {
      const main = r.branch_model === 'main-based';
      return [`\`${r.name}\``, r.branch_model, `\`${r.ref}\``, main ? '`origin/main`' : `\`origin/${r.ref}\``, main ? s.t.prMain(r) : s.t.prDev(r)];
    }),
  );
}

function reposTableBlock(repos, s) {
  if (!repos.length) return s.t.reposEmpty;
  return table(
    s.t.reposHead,
    repos.map((r) => [`\`${r.path}\``, `\`${md(r.url)}\``, `\`${r.ref}\``, r.branch_model, r.stack ? md(r.stack) : '-']),
  );
}

/** Every generated section: file, marker pair, body and whether the file is optional. */
function sections(repos, s) {
  const html = (id) => (id ? [`<!-- repos:begin:${id} -->`, `<!-- repos:end:${id} -->`] : ['<!-- repos:begin -->', '<!-- repos:end -->']);
  const out = [
    { file: 'mise.toml', markers: ['# repos:begin', '# repos:end'], body: miseBlock(repos), pad: false },
    { file: 'AGENTS.md', markers: html('commands'), body: commandsBlock(repos, s), pad: true },
    { file: 'AGENTS.md', markers: html('branches'), body: branchesBlock(repos, s), pad: true },
    { file: 'docs/agents/branches.md', markers: html(), body: branchTableBlock(repos, s), pad: true },
    { file: 'repos/README.md', markers: html(), body: reposTableBlock(repos, s), pad: true },
    // Optional: written only when the file has the markers (a project generated before they existed has none).
    { file: 'docs/agents/environment.md', markers: html('env'), body: envTableBlock(repos, s), pad: true, optional: true },
  ];
  if (existsSync(join(ROOT, 'openspec'))) {
    out.push({ file: 'openspec/clones', markers: ['# repos:begin (generated from repos.toml by mise run repos:sync)', '# repos:end'], body: clonesBlock(repos), pad: false, clones: true });
  }
  return out;
}

/** The text with the section between the markers replaced, or null when the markers are missing. */
function replaceSection(text, { markers: [begin, end], body, pad }) {
  const lines = text.split('\n');
  const b = lines.findIndex((l) => l.trim() === begin);
  const e = lines.findIndex((l, i) => i > b && l.trim() === end);
  if (b < 0 || e < 0) return null;
  const inner = pad ? ['', ...(body ? body.split('\n') : []), ''] : body ? body.split('\n') : [];
  return [...lines.slice(0, b + 1), ...inner, ...lines.slice(e)].join('\n');
}

/**
 * openspec/clones without markers (written by the sdd-kit installer): its entry lines are dropped and
 * the marker section is appended, comments are kept.
 */
function adoptClones(text, section) {
  const kept = text.split('\n').filter((l) => !l.trim() || l.trim().startsWith('#'));
  while (kept.length && !kept[kept.length - 1].trim()) kept.pop();
  return [...kept, section.markers[0], section.markers[1], ''].join('\n');
}

function stub(repo, task) {
  const what = {
    test: 'tests, optionally one test file',
    check: 'linters and type checks',
    run: 'start the application',
    install: 'install dependencies and git hooks',
  }[task];
  return `#!/usr/bin/env bash
#MISE description="${repo.name}: ${what} (not configured yet)"
${STUB_MARK}: generated by \`mise run repos:sync\`. Replace the last line with the clone's own
# command, for example \`exec npm test -- "$@"\`, update the description and delete these comments.
set -euo pipefail
source "$MISE_CONFIG_ROOT/scripts/clones.sh"
require_clone ${repo.path}
cd ${repo.path}
not_configured ${repo.name}:${task}
`;
}

// --- Commands --------------------------------------------------------------------------

function sync({ quiet = false } = {}) {
  const s = settings();
  const { repos, errors } = loadRegistry();
  if (errors.length) {
    console.error(`Fix repos.toml first:\n${errors.map((e) => `  ${e}`).join('\n')}`);
    return 1;
  }
  const changed = [];
  const missing = [];
  const texts = new Map();
  for (const sec of sections(repos, s)) {
    const p = join(ROOT, sec.file);
    let text = texts.get(sec.file) ?? readText(p);
    if (text === null && sec.clones) text = '';
    if (text === null && sec.optional) continue;
    if (text === null) {
      missing.push(`${sec.file}: file is missing`);
      continue;
    }
    let next = replaceSection(text, sec);
    if (next === null && sec.clones) next = replaceSection(adoptClones(text, sec), sec);
    if (next === null && sec.optional) continue;
    if (next === null) {
      missing.push(`${sec.file}: no ${sec.markers[0]} ... ${sec.markers[1]} markers; restore them and run again`);
      continue;
    }
    texts.set(sec.file, next);
  }
  for (const [file, text] of texts) {
    const p = join(ROOT, file);
    if (readText(p) !== text) {
      writeFileSync(p, text);
      changed.push(file);
    }
  }
  for (const r of repos) {
    for (const task of TASKS) {
      const p = join(ROOT, 'mise-tasks', r.name, task);
      if (existsSync(p)) continue;
      mkdirSync(dirname(p), { recursive: true });
      writeFileSync(p, stub(r, task));
      chmodSync(p, 0o755);
      changed.push(`mise-tasks/${r.name}/${task}`);
    }
  }
  if (!quiet) console.log(changed.length ? `Updated:\n${changed.map((c) => `  ${c}`).join('\n')}` : 'Everything is up to date.');
  for (const m of missing) console.error(m);
  return missing.length ? 1 : 0;
}

/** Entries of openspec/clones as paths (`<name>=<path>` keeps the path). */
function kitClones(text) {
  return text
    .split('\n')
    .map((l) => l.replace(/(^|\s)#.*$/, '').trim())
    .filter(Boolean)
    .map((l) => (l.includes('=') ? l.slice(l.indexOf('=') + 1).trim() : l));
}

function check() {
  const s = settings();
  const { repos, errors } = loadRegistry();
  const problems = [...errors];
  const notes = [];
  if (!errors.length) {
    for (const sec of sections(repos, s)) {
      const text = readText(join(ROOT, sec.file));
      if (sec.clones) {
        const have = text === null ? [] : kitClones(text).sort();
        const want = repos.map((r) => r.path).sort();
        const onlyKit = have.filter((p) => !want.includes(p));
        const onlyReg = want.filter((p) => !have.includes(p));
        if (onlyReg.length) problems.push(`openspec/clones: missing ${onlyReg.join(', ')}; run mise run repos:sync`);
        if (onlyKit.length) problems.push(`openspec/clones: not in repos.toml: ${onlyKit.join(', ')}; add them with mise run add-repo or remove them`);
        continue;
      }
      if (text === null) {
        if (!sec.optional) problems.push(`${sec.file}: file is missing`);
        continue;
      }
      const next = replaceSection(text, sec);
      if (next === null && sec.optional) continue;
      if (next === null) problems.push(`${sec.file}: no ${sec.markers[0]} ... ${sec.markers[1]} markers`);
      else if (next !== text) problems.push(`${sec.file}: the ${sec.markers[0]} section is out of date; run mise run repos:sync`);
    }
    for (const r of repos) {
      for (const task of TASKS) {
        const p = join(ROOT, 'mise-tasks', r.name, task);
        let ok = false;
        try {
          ok = statSync(p).isFile() && (statSync(p).mode & 0o111) !== 0;
        } catch {
          /* missing */
        }
        if (!ok) problems.push(`mise-tasks/${r.name}/${task}: missing or not executable; run mise run repos:sync`);
        else if ((readText(p) || '').includes(STUB_MARK)) notes.push(`${r.name}:${task}`);
      }
    }
    const own = new Set([...RESERVED, ...repos.map((r) => r.name)]);
    let dirs = [];
    try {
      dirs = readdirSync(join(ROOT, 'mise-tasks'), { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
    } catch {
      /* no tasks */
    }
    for (const d of dirs) if (!own.has(d)) problems.push(`mise-tasks/${d}/: task folder of a repository that is not in repos.toml; remove it or register the repository`);
  }
  if (notes.length) console.log(`Not configured yet (run /bootstrap in Claude Code or edit the task files): ${notes.join(', ')}`);
  if (problems.length) {
    console.log(`The repository registry and the files generated from it disagree:\n${problems.map((p) => `  ${p}`).join('\n')}`);
    return 1;
  }
  console.log(`repos.toml, mise.toml, ${existsSync(join(ROOT, 'openspec')) ? 'openspec/clones, ' : ''}the task folders and the docs agree (${repos.length} ${repos.length === 1 ? 'repository' : 'repositories'}).`);
  return 0;
}

/**
 * Sets optional fields of one entry in repos.toml, keeping every other line and comment:
 *   set <name> env_file=.envs/.env.dev rules=CLAUDE.md,.claude/rules/ notes=
 * An empty value removes the field; a list field takes comma-separated items.
 */
function set(flags) {
  const [, name, ...pairs] = flags._;
  const { text, repos, errors } = loadRegistry();
  if (errors.length) {
    console.error(`Fix repos.toml first:\n${errors.map((e) => `  ${e}`).join('\n')}`);
    return 1;
  }
  const repo = repos.find((r) => r.name === name);
  if (!repo || !pairs.length) {
    console.error(repo ? 'Give at least one key=value.' : `No repository \`${name ?? ''}\` in repos.toml.`);
    return 1;
  }
  const updates = {};
  for (const pair of pairs) {
    const eq = pair.indexOf('=');
    const key = eq < 0 ? pair : pair.slice(0, eq);
    if (eq < 0 || ![...OPTIONAL, ...LISTS, 'stack'].includes(key)) {
      console.error(`Not set: ${pair}; settable fields: ${[...OPTIONAL, ...LISTS, 'stack'].join(', ')} (key=value)`);
      return 1;
    }
    const value = pair.slice(eq + 1).trim();
    if (!LISTS.includes(key)) {
      updates[key] = value;
      continue;
    }
    // A list is comma-separated paths, or a JSON/TOML array of strings: ["CLAUDE.md", ".claude/rules/"].
    if (value.startsWith('[')) {
      let list = null;
      try {
        list = JSON.parse(value);
      } catch {
        /* reported below */
      }
      if (!Array.isArray(list) || list.some((v) => typeof v !== 'string')) {
        console.error(`Not set: ${pair}; write ${key} as comma-separated paths or as ["a", "b"]`);
        return 1;
      }
      updates[key] = list.map((v) => v.trim()).filter(Boolean);
    } else {
      updates[key] = value.split(',').map((v) => v.trim()).filter(Boolean);
    }
  }
  const next = { ...repo, ...updates };
  const problems = validateRepo(next, repos.filter((r) => r !== repo));
  if (problems.length) {
    console.error(`Not set: ${problems.join('; ')}`);
    return 1;
  }
  const lines = text.split('\n');
  // The entry runs from its [[repo]] line to the next table header or the end of the file.
  const start = repo.line - 1;
  let end = lines.findIndex((l, i) => i > start && /^\s*\[/.test(l));
  if (end < 0) end = lines.length;
  for (const [key, value] of Object.entries(updates)) {
    const at = lines.findIndex((l, i) => i > start && i < end && new RegExp(`^\\s*${key}\\s*=`).test(l));
    const empty = Array.isArray(value) ? !value.length : !value;
    const line = Array.isArray(value) ? `${key} = [${value.map(quote).join(', ')}]` : `${key} = ${quote(value)}`;
    if (at >= 0 && empty) {
      lines.splice(at, 1);
      end--;
    } else if (at >= 0) lines[at] = line;
    else if (!empty) {
      // After the entry's last key line, before trailing blank lines and comments.
      let last = end - 1;
      while (last > start && !/^\s*[A-Za-z_]/.test(lines[last])) last--;
      lines.splice(last + 1, 0, line);
      end++;
    }
  }
  writeFileSync(join(ROOT, REGISTRY), lines.join('\n'));
  return sync();
}

function list() {
  const { repos, errors } = loadRegistry();
  if (errors.length) {
    console.error(errors.join('\n'));
    return 1;
  }
  for (const r of repos) console.log([r.name, r.path, r.url, r.ref, r.branch_model].join('\t'));
  return 0;
}

/** Name from a URL: git@github.com:acme/api.git → api. */
export function nameFromUrl(url) {
  const last = String(url).trim().replace(/\/+$/, '').split(/[/:]/).pop() || '';
  return last
    .replace(/\.git$/, '')
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/^[-_]+|-+$/g, '');
}

/** A bare name or owner/name becomes a GitHub SSH URL; anything else is kept. */
export function expandUrl(input, org) {
  const v = String(input).trim();
  if (/^[A-Za-z0-9._-]+$/.test(v) && org) return `git@github.com:${org}/${v.replace(/\.git$/, '')}.git`;
  if (/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(v) && !v.startsWith('.')) return `git@github.com:${v.replace(/\.git$/, '')}.git`;
  return v;
}

/** Line reader that works for a terminal and for piped answers; null at the end of input. */
function lineReader() {
  // A terminal puts readline in raw mode, which turns off the terminal's own echo, so
  // readline needs the output stream to echo what is typed and to end the line on Enter.
  const tty = Boolean(process.stdin.isTTY);
  const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: tty });
  const queue = [];
  const waiting = [];
  let closed = false;
  rl.on('line', (l) => (waiting.length ? waiting.shift()(l) : queue.push(l)));
  rl.on('close', () => {
    closed = true;
    while (waiting.length) waiting.shift()(null);
  });
  return {
    ask(question) {
      if (closed) {
        process.stdout.write(`${question}\n`);
        return Promise.resolve(null);
      }
      // readline redraws its prompt while the line is edited, so the last line of the
      // question is the prompt and the lines above it are printed once.
      const cut = question.lastIndexOf('\n') + 1;
      if (cut) process.stdout.write(question.slice(0, cut));
      rl.setPrompt(question.slice(cut));
      rl.prompt();
      if (queue.length) return Promise.resolve(queue.shift());
      return new Promise((r) => waiting.push(r));
    },
    close: () => rl.close(),
  };
}

class EndOfInput extends Error {}

async function prompt(io, question, def = '') {
  const a = await io.ask(def ? `${question} [${def}]: ` : `${question}: `);
  if (a === null) throw new EndOfInput();
  return a.trim() || def;
}

async function yesNo(io, t, question, defYes) {
  for (;;) {
    const a = await io.ask(`${question} 1) ${t.yes} 2) ${t.no} [${defYes ? 1 : 2}]: `);
    if (a === null) throw new EndOfInput();
    const v = a.trim().toLowerCase();
    if (!v) return defYes;
    if (v === '1' || v === t.yes || v === 'y' || v === 'yes') return true;
    if (v === '2' || v === t.no || v === 'n' || v === 'no') return false;
  }
}

async function chooseModel(io, t, def) {
  for (;;) {
    console.log(`${t.askModel}\n  1) ${t.modelMain}\n  2) ${t.modelDev}`);
    const a = await io.ask(`${t.choose} [${def === 'dev-based' ? 2 : 1}]: `);
    if (a === null) throw new EndOfInput();
    const v = a.trim();
    if (!v) return def;
    if (v === '1' || v === 'main-based') return 'main-based';
    if (v === '2' || v === 'dev-based') return 'dev-based';
  }
}

async function askRepo(io, s, known) {
  for (;;) {
    let url = '';
    for (;;) {
      url = expandUrl(await prompt(io, s.t.askUrl(s.org).replace(/: $/, '')), s.org);
      if (!url) continue;
      const problem = urlProblem(url);
      if (!problem) break;
      console.log(`  ${problem}`);
    }
    let name = '';
    for (;;) {
      name = await prompt(io, s.t.askName, nameFromUrl(url));
      const problems = validateRepo({ name, path: `repos/${name}`, url, ref: 'dev', branch_model: 'main-based' }, known);
      if (!problems.length) break;
      console.log(`  ${problems.join('; ')}`);
    }
    let ref = '';
    for (;;) {
      ref = await prompt(io, s.t.askRef, 'dev');
      const problems = validateRepo({ name, path: `repos/${name}`, url, ref, branch_model: 'main-based' }, []);
      if (!problems.length) break;
      console.log(`  ${problems.join('; ')}`);
    }
    const branch_model = await chooseModel(io, s.t, 'main-based');
    const stack = await prompt(io, s.t.askStack);
    return { name, path: `repos/${name}`, url, ref, branch_model, stack };
  }
}

function runMise(...args) {
  const r = spawnSync('mise', args, { cwd: ROOT, stdio: 'inherit' });
  return r.status ?? 1;
}

async function add(flags) {
  const s = settings();
  const { repos, errors } = loadRegistry();
  if (errors.length) {
    console.error(`Fix repos.toml first:\n${errors.map((e) => `  ${e}`).join('\n')}`);
    return 1;
  }
  const added = [];
  let cloneNow = Boolean(flags.clone);
  if (flags.yes) {
    const url = expandUrl(flags.url ?? '', s.org);
    const name = flags.name || nameFromUrl(url);
    const r = { name, path: `repos/${name}`, url, ref: flags.ref || 'dev', branch_model: flags['branch-model'] || 'main-based', stack: flags.stack || '' };
    const problems = validateRepo(r, repos);
    if (problems.length) {
      console.error(`Not added: ${problems.join('; ')}`);
      return 1;
    }
    appendToRegistry(r);
    added.push(r);
    console.log(s.t.added(r));
  } else {
    const io = lineReader();
    try {
      let more = await yesNo(io, s.t, s.t.askAdd, true);
      while (more) {
        const r = await askRepo(io, s, [...repos, ...added]);
        appendToRegistry(r);
        added.push(r);
        console.log(s.t.added(r));
        more = await yesNo(io, s.t, s.t.askAddMore, false);
      }
      if (added.length && !flags.clone && !flags['no-clone']) cloneNow = await yesNo(io, s.t, s.t.askClone, true);
    } catch (e) {
      if (!(e instanceof EndOfInput)) throw e;
      cloneNow = Boolean(flags.clone);
    } finally {
      io.close();
    }
  }
  if (!added.length) {
    console.log(s.t.nothingAdded);
    return 0;
  }
  // sync also rewrites openspec/clones when sdd-kit is installed (openspec/ exists).
  const rc = sync();
  if (rc !== 0) return rc;
  const cloned = cloneNow ? runMise('run', 'clone') : 0;
  console.log(`\n${s.t.bootstrapHint(added.map((r) => r.name))}`);
  return cloned;
}

function parseFlags(argv) {
  const flags = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) {
      flags._.push(a);
      continue;
    }
    const eq = a.indexOf('=');
    const key = a.slice(2, eq < 0 ? undefined : eq);
    if (eq >= 0) flags[key] = a.slice(eq + 1);
    else if (['yes', 'clone', 'no-clone', 'help'].includes(key)) flags[key] = true;
    else flags[key] = argv[++i] ?? '';
  }
  return flags;
}

const USAGE = `Usage: node scripts/repos.mjs <add|set|sync|check|list> [options]

  add     add repositories to repos.toml (asks in a terminal), then sync
          --name <name> --url <url> --ref <branch> --branch-model main-based|dev-based
          --stack <text> --yes (no questions, one repository from the flags)
          --clone (clone afterwards without asking) --no-clone (do not offer to clone)
  set     set optional fields of one repository, then sync:
          set <name> key=value ... (env_file, env_example, env_notes, test_needs, notes, stack,
          rules=<path>,<path>; paths relative to the clone; an empty value removes the field)
  sync    regenerate the sections and task stubs that list the repositories
  check   verify that repos.toml and the generated files agree
  list    print the repositories: name, path, url, ref, branch_model (tab-separated)`;

async function main() {
  const flags = parseFlags(process.argv.slice(2));
  const cmd = flags._[0];
  if (flags.help || !cmd) {
    console.log(USAGE);
    return cmd || flags.help ? 0 : 1;
  }
  if (cmd === 'add') return add(flags);
  if (cmd === 'sync') return sync();
  if (cmd === 'check') return check();
  if (cmd === 'list') return list();
  if (cmd === 'set') return set(flags);
  console.error(`Unknown command: ${cmd}\n\n${USAGE}`);
  return 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((code) => (process.exitCode = code));
}
