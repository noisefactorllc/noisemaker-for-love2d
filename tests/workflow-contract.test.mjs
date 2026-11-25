// The 2.x branch's workflow contract.
//
// The test jobs run on every push to 2.x, and every release, notice or
// dispatch job runs only for main. A job runs only for main when its condition
// names refs/heads/main or a workflow_run head branch of main, or when every
// trigger of its workflow is a schedule (which runs only from the default
// branch) or a push or workflow_run filtered to main alone.
//
// Reads the YAML text: the repository has no YAML parser.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const WORKFLOWS = new URL('../.github/workflows/', import.meta.url);

// Workflows whose jobs are test jobs, and must run on every 2.x push.
const TEST_WORKFLOWS = ['ci.yml'];
// Workflows whose jobs release, notify or dispatch, and must run only for main.
const RELEASE_WORKFLOWS = ['export-kit.yml'];

const MAIN_ONLY_CONDITIONS = [
  /github\.ref\s*==\s*'refs\/heads\/main'/,
  /github\.event\.workflow_run\.head_branch\s*==\s*'main'/,
];

const unquote = (s) => s.replace(/^['"]+|['"]+$/g, '');

function partition(text, sep) {
  const at = text.indexOf(sep);
  return at < 0 ? [text, ''] : [text.slice(0, at), text.slice(at + sep.length)];
}

// Each meaningful line as [indent, text], without full-line or trailing comments.
function readLines(name) {
  const lines = [];
  for (let raw of readFileSync(new URL(name, WORKFLOWS), 'utf8').split(/\r?\n/)) {
    raw = raw.replace(/\s+#[^'"]*$/, '');
    if (raw.trim() && !raw.trimStart().startsWith('#')) {
      lines.push([raw.length - raw.replace(/^ +/, '').length, raw.trim()]);
    }
  }
  return lines;
}

// [key, value, index] for each key one level below lines[start].
function children(lines, start, indent) {
  const found = [];
  let child = null;
  for (let index = start + 1; index < lines.length; index++) {
    const [depth, text] = lines[index];
    if (depth <= indent) break;
    if (child === null) child = depth;
    if (depth === child && !text.startsWith('- ')) {
      const [key, value] = partition(text, ':');
      found.push([unquote(key.trim()), value.trim(), index]);
    }
  }
  return found;
}

// The scalar at lines[index]: inline, or a folded or literal block.
function block(lines, index) {
  const [depth, text] = lines[index];
  const value = partition(text, ':')[1].trim();
  if (!['>', '|'].includes(value.slice(0, 1))) return value;
  const parts = [];
  for (let later = index + 1; later < lines.length; later++) {
    if (lines[later][0] <= depth) break;
    parts.push(lines[later][1]);
  }
  return parts.join(' ');
}

function top(lines, key) {
  const index = lines.findIndex(
    ([depth, text]) => depth === 0 && unquote(partition(text, ':')[0].trim()) === key,
  );
  if (index < 0) throw new assert.AssertionError({ message: `no top-level ${key}` });
  return index;
}

// Each trigger mapped to its branch filter (null when it has none).
function triggers(name) {
  const lines = readLines(name);
  const start = top(lines, 'on');
  const result = {};
  for (const [event, , index] of children(lines, start, 0)) {
    let branches = null;
    for (const [key, inline, child] of children(lines, index, lines[index][0])) {
      if (key !== 'branches') continue;
      if (inline.startsWith('[')) {
        branches = inline
          .replace(/^[[\]]+|[[\]]+$/g, '')
          .split(',')
          .filter((b) => b.trim())
          .map((b) => unquote(b.trim()));
      } else {
        branches = [];
        for (let later = child + 1; later < lines.length; later++) {
          const [depth, text] = lines[later];
          if (depth <= lines[child][0] && !text.startsWith('- ')) break;
          if (text.startsWith('- ')) branches.push(unquote(text.slice(2).trim()));
        }
      }
    }
    result[event] = branches;
  }
  return result;
}

// Each job mapped to its condition ('' when it has none).
function jobs(name) {
  const lines = readLines(name);
  const start = top(lines, 'jobs');
  const result = {};
  for (const [job, , index] of children(lines, start, 0)) {
    let condition = '';
    for (const [key, , child] of children(lines, index, lines[index][0])) {
      if (key === 'if') condition = block(lines, child);
    }
    result[job] = condition;
  }
  return result;
}

function runsOnlyForMain(name, condition) {
  // A condition with an alternative can hold outside main, so only the
  // triggers can make such a job main-only.
  if (!condition.includes('||') && MAIN_ONLY_CONDITIONS.some((pattern) => pattern.test(condition))) {
    return true;
  }
  for (const [event, branches] of Object.entries(triggers(name))) {
    if (event === 'schedule') continue;
    if (
      (event === 'push' || event === 'workflow_run') &&
      branches?.length === 1 &&
      branches[0] === 'main'
    ) {
      continue;
    }
    return false;
  }
  return true;
}

for (const name of TEST_WORKFLOWS) {
  test(`the test jobs of ${name} run on every 2.x push`, () => {
    const found = triggers(name);
    // A push trigger with no branch filter runs on every branch.
    assert.ok(
      'push' in found && (found.push === null || found.push.includes('2.x')),
      `${name} does not run on a 2.x push`,
    );
    for (const [job, condition] of Object.entries(jobs(name))) {
      assert.ok(
        !condition.includes('refs/heads/main') || condition.includes('refs/heads/2.x'),
        `${name} job ${job} runs only for main: ${condition}`,
      );
    }
  });
}

for (const name of RELEASE_WORKFLOWS) {
  test(`every release, notice or dispatch job of ${name} runs only for main`, () => {
    const found = jobs(name);
    assert.ok(Object.keys(found).length, `${name} has no jobs`);
    for (const [job, condition] of Object.entries(found)) {
      assert.ok(runsOnlyForMain(name, condition), `${name} job ${job} can run outside main`);
    }
  });
}

test('the contract reader finds every workflow trigger and job', () => {
  for (const name of [...TEST_WORKFLOWS, ...RELEASE_WORKFLOWS]) {
    assert.ok(Object.keys(triggers(name)).length, `no triggers read from ${name}`);
    assert.ok(Object.keys(jobs(name)).length, `no jobs read from ${name}`);
  }
  assert.ok('dispatch' in jobs('export-kit.yml'));
  assert.ok('qualify' in jobs('ci.yml'));
  assert.ok('push' in triggers('ci.yml'));
});
