#!/usr/bin/env node
// agent-git-guard — PreToolUse hook (Bash) of the meta-repository, plain Node with no packages.
//
// An agent started in the root may commit and push only after the developer opts in personally, in the `env`
// of `.claude/settings.local.json` (git-ignored):
//   METAREPO_AGENT_COMMIT=1  allows `git commit`
//   METAREPO_AGENT_PUSH=1    allows `git push`
// Only the hook's own process environment counts: a variable written inside the command does not reach it.
// Whatever the settings, a commit while the target repository is on `main` and a push whose target is `main`
// are refused. This holds for every clone in repos/ and for the meta-repository itself
// (docs/adr/0004-agent-commit-push-opt-in.md).
//
// Claude attribution is refused in `git commit` and in `gh pr create|edit|comment|review`: the text of
// -m/--message/--trailer/--author, --title/-t, --body/-b and the file of -F/--file/--body-file is checked for
// a `Generated with Claude Code` line, a `Co-Authored-By:` line naming Claude or anthropic.com, and the words
// Claude or Anthropic (any case) once CLAUDE.md, CLAUDE.local.md, `.claude/` paths and `Claude Code` are
// removed. A commit that would open an editor and `gh pr create --fill` are refused, since their text is not
// visible. The permission refusals come first, then attribution, then the `main` rules.
//
// Merging stays with the developer: `gh pr merge` is refused in every repository, and `git merge` is refused
// while the target repository is on `main`, on `dev` or on the clone's rest branch (`ref` in repos.toml),
// whatever the settings.
//
// The refusal messages name the branch to start from. They read repos.toml, found in the target directory or
// above it: a main-based clone starts from `origin/main`, a dev-based clone from `origin/<ref>`, the
// meta-repository from `main` (docs/agents/branches.md).
//
// The target repository is found from `git -C <dir>`, a preceding `cd <dir>` and the session directory. The
// check reads the command text, so a commit run from inside a script, or a comment made through `gh api`, is
// not seen; the clones' own hooks and the branch rules stay the backstop.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const SETTINGS = '.claude/settings.local.json';
const WRAPPERS = new Set(['env', 'command', 'exec', 'nohup', 'time', 'nice', 'timeout']);
const HEREDOC = /^<<(-?)[ \t]*(['"]?)([^\s'"<>|&;()]+)\2/;

/** Index after the heredoc body that starts after the newline at or after `from`; `body` is its text. */
function heredocBody(s, from, delim, strip) {
  let i = s.indexOf('\n', from);
  if (i < 0) return { end: s.length, body: '' };
  i++;
  const lines = [];
  while (i < s.length) {
    let j = s.indexOf('\n', i);
    if (j < 0) j = s.length;
    const line = s.slice(i, j);
    i = j + 1;
    if ((strip ? line.replace(/^\t+/, '') : line) === delim) return { end: Math.min(i, s.length), body: lines.join('\n') };
    lines.push(line);
  }
  return { end: s.length, body: lines.join('\n') };
}

/** Index after the `$( … )` that starts at `i`, with nested quotes, substitutions and heredocs. */
function skipSubst(s, i) {
  let depth = 1;
  i += 2;
  while (i < s.length && depth > 0) {
    const c = s[i];
    if (c === '\\') i += 2;
    else if (c === "'") {
      const j = s.indexOf("'", i + 1);
      i = j < 0 ? s.length : j + 1;
    } else if (c === '"') i = doubleQuoted(s, i).end;
    else if (s.startsWith('$(', i)) i = skipSubst(s, i);
    else if (s.startsWith('<<', i) && !s.startsWith('<<<', i) && HEREDOC.test(s.slice(i))) {
      const m = s.slice(i).match(HEREDOC);
      i = heredocBody(s, i + m[0].length, m[3], m[1] === '-').end;
    } else {
      if (c === '(') depth++;
      else if (c === ')') depth--;
      i++;
    }
  }
  return i;
}

/** The value of the double-quoted string that starts at `i` and the index after it. */
function doubleQuoted(s, i) {
  let value = '';
  i++;
  while (i < s.length && s[i] !== '"') {
    if (s[i] === '\\' && '$`"\\\n'.includes(s[i + 1] ?? '')) {
      if (s[i + 1] !== '\n') value += s[i + 1];
      i += 2;
    } else if (s.startsWith('$(', i)) {
      const j = skipSubst(s, i);
      value += s.slice(i, j);
      i = j;
    } else value += s[i++];
  }
  return { value, end: i + 1 };
}

/**
 * Parts of a command line, split at unquoted `&&`, `||`, `;`, `|`, `&` and newlines. Each part has its words
 * with the quotes removed and `stdin`, the text of a heredoc it reads.
 */
function commandParts(command) {
  const s = String(command);
  const parts = [];
  const pending = [];
  let part = { words: [], stdin: '' };
  let cur = null;
  const pushWord = () => {
    if (cur !== null) part.words.push(cur);
    cur = null;
  };
  const endPart = () => {
    pushWord();
    if (part.words.length) parts.push(part);
    part = { words: [], stdin: '' };
  };
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === ' ' || c === '\t' || c === '\r') {
      pushWord();
      i++;
    } else if (c === '\n') {
      endPart();
      i++;
      for (const h of pending.splice(0)) {
        const { end, body } = heredocBody(s, i - 1, h.delim, h.strip);
        h.part.stdin = body;
        i = end;
      }
    } else if (c === '#' && cur === null) {
      const j = s.indexOf('\n', i);
      i = j < 0 ? s.length : j;
    } else if (c === '\\') {
      if (s[i + 1] !== '\n') cur = (cur ?? '') + (s[i + 1] ?? '');
      i += 2;
    } else if (c === "'") {
      const j = s.indexOf("'", i + 1);
      cur = (cur ?? '') + s.slice(i + 1, j < 0 ? s.length : j);
      i = j < 0 ? s.length : j + 1;
    } else if (c === '"') {
      const { value, end } = doubleQuoted(s, i);
      cur = (cur ?? '') + value;
      i = end;
    } else if (s.startsWith('$(', i)) {
      const j = skipSubst(s, i);
      cur = (cur ?? '') + s.slice(i, j);
      i = j;
    } else if (c === '`') {
      const j = s.indexOf('`', i + 1);
      cur = (cur ?? '') + s.slice(i, j < 0 ? s.length : j + 1);
      i = j < 0 ? s.length : j + 1;
    } else if (s.startsWith('<<', i) && !s.startsWith('<<<', i) && HEREDOC.test(s.slice(i))) {
      pushWord();
      const m = s.slice(i).match(HEREDOC);
      pending.push({ part, delim: m[3], strip: m[1] === '-' });
      i += m[0].length;
    } else if (s.startsWith('&&', i) || s.startsWith('||', i)) {
      endPart();
      i += 2;
    } else if (c === ';' || c === '|' || (c === '&' && !/[<>]/.test(s[i - 1] ?? '') && s[i + 1] !== '>')) {
      endPart();
      i++;
    } else {
      cur = (cur ?? '') + c;
      i++;
    }
  }
  endPart();
  return parts;
}

/** Words of one part with leading VAR=value and wrappers (env, exec, …) dropped. */
function words(w) {
  let i = 0;
  while (i < w.length) {
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w[i])) i++;
    else if (WRAPPERS.has(w[i])) {
      i++;
      while (i < w.length && (w[i].startsWith('-') || /^\d+[smhd]?$/.test(w[i]))) i++;
    } else break;
  }
  return w.slice(i);
}

/** git's global options before the subcommand: the directory from `-C` and the subcommand with its args. */
function gitCall(args, cwd) {
  let dir = cwd;
  let i = 0;
  while (i < args.length && args[i].startsWith('-')) {
    if (args[i] === '-C') {
      dir = path.resolve(dir, args[i + 1] || '.');
      i += 2;
    } else if (args[i] === '-c' || args[i] === '--git-dir' || args[i] === '--work-tree' || args[i] === '--namespace') {
      i += 2;
    } else i++;
  }
  return { dir, sub: args[i], rest: args.slice(i + 1) };
}

function git(dir, ...args) {
  try {
    return execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

// --- Repository registry -----------------------------------------------------------

/** The `[[repo]]` entries of the nearest repos.toml at or above `dir`, with the meta-repository root. */
function registry(dir) {
  for (let d = dir; ; d = path.dirname(d)) {
    let text = null;
    try {
      text = readFileSync(path.join(d, 'repos.toml'), 'utf8');
    } catch {
      /* not here */
    }
    if (text !== null) {
      const repos = [];
      for (const raw of text.split(/\r?\n/)) {
        const line = raw.trim();
        if (/^\[\[\s*repo\s*\]\]/.test(line)) repos.push({});
        const kv = line.match(/^([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*"((?:[^"\\]|\\.)*)"/);
        if (kv && repos.length) repos[repos.length - 1][kv[1]] = kv[2].replace(/\\(.)/g, '$1');
      }
      return { root: d, repos };
    }
    if (path.dirname(d) === d) return { root: null, repos: [] };
  }
}

/** Where the target repository stands: { kind: 'meta' | 'clone' | 'other', repo }. */
function placeOf(dir) {
  const top = git(dir, 'rev-parse', '--show-toplevel') || dir;
  const { root, repos } = registry(top);
  if (!root) return { kind: 'other' };
  if (path.resolve(top) === path.resolve(root)) return { kind: 'meta' };
  const repo = repos.find((r) => r.path && path.resolve(root, r.path) === path.resolve(top));
  return repo ? { kind: 'clone', repo } : { kind: 'other' };
}

/** The sentence that names the branch a work branch starts from. */
function startHint(dir) {
  const place = placeOf(dir);
  if (place.kind === 'meta') return 'Create a work branch from `main` (docs/agents/branches.md).';
  if (place.kind === 'clone') {
    const { name, branch_model: model, ref = 'dev' } = place.repo;
    const from = model === 'dev-based' ? `origin/${ref}` : 'origin/main';
    return `Create a work branch first: ${name} is ${model || 'main-based'}, so it starts from \`${from}\` (docs/agents/branches.md).`;
  }
  return 'Create a work branch first, from the base its branch model names: `origin/main` for a main-based clone, its rest branch for a dev-based clone, `main` in the meta-repository (docs/agents/branches.md).';
}

const branchName = (ref) => ref.replace(/^\+/, '').replace(/^refs\/heads\//, '');

/** Why a push targets `main`, or null. */
function pushToMain(dir, rest) {
  if (rest.some((a) => a === '--all' || a === '--mirror')) return 'it pushes every branch, `main` included';
  const positional = rest.filter((a) => !a.startsWith('-'));
  const refspecs = positional.slice(1);
  if (refspecs.length > 0) {
    for (const spec of refspecs) {
      const dst = spec.includes(':') ? spec.slice(spec.indexOf(':') + 1) : spec;
      const target = dst === 'HEAD' || dst === '' ? git(dir, 'branch', '--show-current') : dst;
      if (branchName(target) === 'main') return `its refspec \`${spec}\` targets \`main\``;
    }
    return null;
  }
  const current = git(dir, 'branch', '--show-current');
  if (current === 'main') return 'it pushes the current branch `main`';
  const upstream = git(dir, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}');
  if (upstream && upstream.replace(/^[^/]+\//, '') === 'main') return `the current branch \`${current}\` pushes to its upstream \`${upstream}\``;
  return null;
}

// --- Attribution -------------------------------------------------------------------

const ATTRIBUTION = 'Claude attribution is not allowed in commits and pull requests';
const ALLOWED_NOTE = 'CLAUDE.md, CLAUDE.local.md, paths with .claude/ and the name Claude Code are allowed (docs/agents/agent-settings.md)';

/** What attribution the text contains, described for the refusal, or null. */
function attributionFound(text) {
  for (const line of text.split(/\r?\n/)) {
    if (/generated\s+with\s+\[?\s*claude\s+code/i.test(line)) return 'the line `Generated with Claude Code`';
  }
  for (const line of text.split(/\r?\n/)) {
    if (/^\s*co-authored-by:.*(claude|anthropic)/i.test(line)) return 'a `Co-Authored-By` line naming Claude or anthropic.com';
  }
  const cleaned = text
    .replace(/\S*\.claude\/\S*/gi, ' ')
    .replace(/\S*claude(\.local)?\.md/gi, ' ')
    .replace(/claude\s+code/gi, ' ');
  const word = cleaned.match(/(?<![a-z])(claude|anthropic)(?![a-z])/i);
  return word ? `the word \`${word[0]}\`` : null;
}

/** The text of the given inline values and files, or a refusal when a file cannot be read. */
function collectText(texts, files, dir, part, command) {
  const all = [...texts];
  for (const f of files) {
    if (f === '-') {
      all.push(part.stdin || String(command));
      continue;
    }
    const file = path.resolve(dir, f);
    try {
      all.push(readFileSync(file, 'utf8'));
    } catch {
      return { refusal: `Cannot read ${file} to check it for Claude attribution. Write the text into a readable file or pass it inline.` };
    }
  }
  return { text: all.join('\n') };
}

function attributionRefusal(what, texts, files, dir, part, command) {
  const { text, refusal } = collectText(texts, files, dir, part, command);
  if (refusal) return refusal;
  const found = attributionFound(text);
  return found ? `${ATTRIBUTION}: the ${what} has ${found}. Remove it and run the command again; ${ALLOWED_NOTE}.` : null;
}

/** The attribution refusal for `git commit <rest>`, or null. */
function commitAttribution(dir, rest, part, command) {
  const texts = [];
  const files = [];
  let reuse = false;
  for (let k = 0; k < rest.length; k++) {
    const a = rest[k];
    if (a === '--') break;
    const long = a.match(/^(--[a-z-]+)=(.*)$/s);
    const [name, attached] = long ? [long[1], long[2]] : [a, undefined];
    const value = () => (attached !== undefined ? attached : (rest[++k] ?? ''));
    if (name === '--message' || name === '--trailer' || name === '--author') texts.push(value());
    else if (name === '--file') files.push(value());
    else if (name === '--reuse-message') {
      value();
      reuse = true;
    } else if (name === '--no-edit') reuse = true;
    else if (name === '--reedit-message' || name === '--template' || name === '--date' || name === '--cleanup') value();
    else if (/^-[a-zA-Z]/.test(a) && !a.startsWith('--')) {
      for (let c = 1; c < a.length; c++) {
        const ch = a[c];
        if (!'mFCct'.includes(ch)) continue;
        const v = c + 1 < a.length ? a.slice(c + 1) : (rest[++k] ?? '');
        if (ch === 'm') texts.push(v);
        else if (ch === 'F') files.push(v);
        else if (ch === 'C') reuse = true;
        break;
      }
    }
  }
  if (texts.length === 0 && files.length === 0 && !reuse) {
    return `This commit would open an editor for the message, so its text cannot be checked for Claude attribution. Give the message with \`-m\` or \`-F <file>\`.`;
  }
  return attributionRefusal('commit message', texts, files, dir, part, command);
}

/** The refusal for `gh pr <sub> <rest>`, or null. */
function ghPrRefusal(sub, rest, dir, part, command) {
  if (sub === 'merge') {
    return 'Merging a pull request is not allowed for the agent: the developer merges pull requests by hand. Report the pull request link instead (docs/agents/branches.md).';
  }
  if (!['create', 'edit', 'comment', 'review'].includes(sub)) return null;
  const texts = [];
  const files = [];
  for (let k = 0; k < rest.length; k++) {
    const a = rest[k];
    const long = a.match(/^(--[a-z-]+)=(.*)$/s);
    const [name, attached] = long ? [long[1], long[2]] : [a, undefined];
    const value = () => (attached !== undefined ? attached : (rest[++k] ?? ''));
    if (name === '--title' || name === '-t' || name === '--body' || name === '-b') texts.push(value());
    else if (name === '--body-file' || name === '-F') files.push(value());
    else if (sub === 'create' && (name === '-f' || name === '--fill' || name === '--fill-first' || name === '--fill-verbose')) {
      return `\`gh pr ${sub} ${name}\` fills the text in automatically from the commits, so it cannot be checked for Claude attribution; \`--fill\`, \`--fill-first\` and \`--fill-verbose\` are refused. Give \`--title\` and \`--body\` or \`--body-file\`.`;
    } else if ((sub === 'create' || sub === 'comment') && ['-e', '--editor', '-w', '--web'].includes(name)) {
      return `\`gh pr ${sub} ${name}\` writes the text outside the command, so it cannot be checked for Claude attribution. Give \`--title\` and \`--body\` or \`--body-file\`.`;
    }
  }
  return attributionRefusal('pull request text', texts, files, dir, part, command);
}

// --- Decision ----------------------------------------------------------------------

/** The reason to refuse one git call, or null. */
function refusal({ dir, sub, rest }, env, part, command) {
  if (sub === 'commit') {
    if (env.METAREPO_AGENT_COMMIT !== '1') {
      return `Agent commits are disabled in ${dir}. A developer enables them personally with "METAREPO_AGENT_COMMIT": "1" in the "env" of ${SETTINGS}; until then ask the developer to commit.`;
    }
    const attribution = commitAttribution(dir, rest, part, command);
    if (attribution) return attribution;
    if (git(dir, 'branch', '--show-current') === 'main') {
      return `Committing on \`main\` is never allowed (${dir} is on main). ${startHint(dir)}`;
    }
  }
  if (sub === 'push') {
    if (env.METAREPO_AGENT_PUSH !== '1') {
      return `Agent pushes are disabled in ${dir}. A developer enables them personally with "METAREPO_AGENT_PUSH": "1" in the "env" of ${SETTINGS}; METAREPO_AGENT_COMMIT does not allow pushes. Until then ask the developer to push.`;
    }
    const why = pushToMain(dir, rest);
    if (why) return `Pushing to \`main\` is never allowed: ${why}. Push a work branch and open a pull request.`;
  }
  if (sub === 'merge' && !rest.some((a) => a === '--abort' || a === '--quit')) {
    const current = git(dir, 'branch', '--show-current');
    const place = placeOf(dir);
    const rest = place.kind === 'clone' ? place.repo.ref || 'dev' : 'dev';
    if (current === 'dev' || current === 'main' || current === rest) {
      return `Merging into \`${current}\` is not allowed for the agent (${dir} is on ${current}): the developer merges by hand. Open a pull request instead; in a main-based clone, resolve conflicts with \`${rest}\` on a merge branch merge/<name>-into-${rest} (docs/agents/branches.md).`;
    }
  }
  return null;
}

/** The reason to refuse a whole command line run from `cwd`, or null. */
export function decide(command, cwd, env = process.env) {
  let dir = cwd;
  for (const part of commandParts(command)) {
    const w = words(part.words);
    if (w[0] === 'cd') {
      dir = path.resolve(dir, w[1] || env.HOME || dir);
      continue;
    }
    const tool = path.basename(w[0] || '');
    let reason = null;
    if (tool === 'git') reason = refusal(gitCall(w.slice(1), dir), env, part, command);
    else if (tool === 'gh' && w[1] === 'pr') reason = ghPrRefusal(w[2], w.slice(3), dir, part, command);
    if (reason) return reason;
  }
  return null;
}

function main() {
  let input;
  try {
    input = JSON.parse(readFileSync(0, 'utf8') || '{}');
  } catch {
    return;
  }
  if (input.tool_name !== 'Bash') return;
  const command = input.tool_input?.command || '';
  const cwd = input.cwd || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const reason = decide(command, cwd);
  if (!reason) return;
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
    }),
  );
}

main();
