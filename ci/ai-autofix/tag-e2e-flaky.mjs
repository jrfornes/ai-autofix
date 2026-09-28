#!/usr/bin/env node
/**
 * Edit one leaf it()/it.only() to add tags: ['@flaky'].
 * Usage: node tag-e2e-flaky.mjs <file> <title>
 * Exit: 0 modified, 2 no-op/abort (no edit), 1 hard error
 */
import { readFileSync, writeFileSync } from 'node:fs';

const FLAKY = '@flaky';

function log(msg) {
  process.stderr.write(`[tag-e2e-flaky] ${msg}\n`);
}

function isIdentBoundary(ch) {
  return ch === undefined || !/[A-Za-z0-9_$]/.test(ch);
}

function skipWs(src, i) {
  while (i < src.length && /[\s]/.test(src[i])) i++;
  return i;
}

function skipLineComment(src, i) {
  while (i < src.length && src[i] !== '\n') i++;
  return i;
}

function skipBlockComment(src, i) {
  const end = src.indexOf('*/', i + 2);
  return end < 0 ? src.length : end + 2;
}

function parseString(src, i) {
  const quote = src[i];
  if (quote !== "'" && quote !== '"' && quote !== '`') return null;
  let j = i + 1;
  let value = '';
  while (j < src.length) {
    const c = src[j];
    if (quote === '`' && c === '$' && src[j + 1] === '{') {
      return { kind: 'template', end: -1 };
    }
    if (c === '\\') {
      if (j + 1 >= src.length) return null;
      const n = src[j + 1];
      const map = { n: '\n', r: '\r', t: '\t', '0': '\0' };
      value += map[n] ?? n;
      j += 2;
      continue;
    }
    if (c === quote) {
      return { kind: quote === '`' ? 'template' : 'string', value, start: i, end: j + 1 };
    }
    if (quote !== '`' && c === '\n') return null;
    value += c;
    j++;
  }
  return null;
}

function skipStringOrTemplate(src, i) {
  const quote = src[i];
  let j = i + 1;
  while (j < src.length) {
    const c = src[j];
    if (c === '\\') {
      j += 2;
      continue;
    }
    if (quote === '`' && c === '$' && src[j + 1] === '{') {
      j += 2;
      let depth = 1;
      while (j < src.length && depth > 0) {
        if (src[j] === "'" || src[j] === '"' || src[j] === '`') {
          const nested = skipStringOrTemplate(src, j);
          j = nested;
          continue;
        }
        if (src[j] === '{') depth++;
        else if (src[j] === '}') depth--;
        j++;
      }
      continue;
    }
    if (c === quote) return j + 1;
    j++;
  }
  return src.length;
}

function skipBalanced(src, i, open, close) {
  if (src[i] !== open) return i;
  let depth = 0;
  let j = i;
  while (j < src.length) {
    const c = src[j];
    if (c === '/' && src[j + 1] === '/') {
      j = skipLineComment(src, j);
      continue;
    }
    if (c === '/' && src[j + 1] === '*') {
      j = skipBlockComment(src, j);
      continue;
    }
    if (c === "'" || c === '"' || c === '`') {
      j = skipStringOrTemplate(src, j);
      continue;
    }
    if (c === open) depth++;
    else if (c === close) {
      depth--;
      if (depth === 0) return j + 1;
    }
    j++;
  }
  return src.length;
}

function findTagsArray(optionsSrc) {
  let i = 0;
  while (i < optionsSrc.length) {
    const c = optionsSrc[i];
    if (c === '/' && optionsSrc[i + 1] === '/') {
      i = skipLineComment(optionsSrc, i);
      continue;
    }
    if (c === '/' && optionsSrc[i + 1] === '*') {
      i = skipBlockComment(optionsSrc, i);
      continue;
    }
    if (c === "'" || c === '"' || c === '`') {
      i = skipStringOrTemplate(optionsSrc, i);
      continue;
    }
    if (
      optionsSrc.startsWith('tags', i) &&
      isIdentBoundary(optionsSrc[i - 1]) &&
      isIdentBoundary(optionsSrc[i + 4])
    ) {
      let j = skipWs(optionsSrc, i + 4);
      if (optionsSrc[j] !== ':') {
        i++;
        continue;
      }
      j = skipWs(optionsSrc, j + 1);
      if (optionsSrc[j] !== '[') {
        i++;
        continue;
      }
      const arrStart = j;
      const arrEnd = skipBalanced(optionsSrc, j, '[', ']');
      const body = optionsSrc.slice(arrStart, arrEnd);
      const hasFlaky =
        body.includes(`'${FLAKY}'`) ||
        body.includes(`"${FLAKY}"`) ||
        body.includes(`\`${FLAKY}\``);
      return { arrStart, arrEnd, hasFlaky, body };
    }
    i++;
  }
  return null;
}

function findItCalls(src) {
  const calls = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      i = skipLineComment(src, i);
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      i = skipBlockComment(src, i);
      continue;
    }
    if (c === "'" || c === '"' || c === '`') {
      i = skipStringOrTemplate(src, i);
      continue;
    }

    if (
      src.startsWith('it', i) &&
      isIdentBoundary(src[i - 1]) &&
      isIdentBoundary(src[i + 2])
    ) {
      const callStart = i;
      let p = i + 2;
      let kind = 'it';
      if (src.startsWith('.only', p) && isIdentBoundary(src[p + 5])) {
        kind = 'only';
        p += 5;
      } else if (src.startsWith('.skip', p) && isIdentBoundary(src[p + 5])) {
        kind = 'skip';
        p += 5;
      }
      p = skipWs(src, p);
      if (src[p] !== '(') {
        i++;
        continue;
      }
      const openParen = p;
      p = skipWs(src, p + 1);

      let title = null;
      let titleIsTemplate = false;
      if (src[p] === "'" || src[p] === '"' || src[p] === '`') {
        const str = parseString(src, p);
        if (!str || str.kind === 'template' || str.end < 0) {
          titleIsTemplate = true;
          p = skipStringOrTemplate(src, p);
        } else {
          title = str.value;
          p = str.end;
        }
      } else {
        i = openParen + 1;
        continue;
      }

      p = skipWs(src, p);
      if (src[p] !== ',') {
        i = openParen + 1;
        continue;
      }
      const afterTitleComma = p;
      p = skipWs(src, p + 1);

      let options = null;
      if (src[p] === '{') {
        const optStart = p;
        const optEnd = skipBalanced(src, p, '{', '}');
        const optionsSrc = src.slice(optStart, optEnd);
        options = {
          start: optStart,
          end: optEnd,
          tags: findTagsArray(optionsSrc),
        };
        p = skipWs(src, optEnd);
        if (src[p] === ',') p = skipWs(src, p + 1);
      }

      calls.push({
        callStart,
        openParen,
        kind,
        title,
        titleIsTemplate,
        afterTitleComma,
        options,
      });
      i = openParen + 1;
      continue;
    }
    i++;
  }
  return calls;
}

function insertFlakyIntoTags(optionsSrc, tags) {
  const inner = optionsSrc.slice(tags.arrStart + 1, tags.arrEnd - 1).trim();
  if (!inner) {
    return optionsSrc.slice(0, tags.arrStart) + `['${FLAKY}']` + optionsSrc.slice(tags.arrEnd);
  }
  const before = optionsSrc.slice(0, tags.arrEnd - 1);
  const after = optionsSrc.slice(tags.arrEnd - 1);
  const needsComma = !inner.endsWith(',');
  return before + (needsComma ? `, '${FLAKY}'` : ` '${FLAKY}'`) + after;
}

function addTagsToOptions(optionsSrc) {
  const inner = optionsSrc.slice(1, optionsSrc.length - 1).trim();
  if (!inner) return `{ tags: ['${FLAKY}'] }`;
  return `{ tags: ['${FLAKY}'], ${inner} }`;
}

function applyTag(src, call) {
  let out = src;
  let options = call.options;
  let afterTitleComma = call.afterTitleComma;

  if (call.kind === 'only') {
    out = out.slice(0, call.callStart) + 'it' + out.slice(call.callStart + 'it.only'.length);
    const delta = 'it'.length - 'it.only'.length;
    afterTitleComma += delta;
    if (options) {
      options = {
        ...options,
        start: options.start + delta,
        end: options.end + delta,
      };
    }
  }

  if (options) {
    if (options.tags?.hasFlaky) return { src: out, changed: false };
    const slice = out.slice(options.start, options.end);
    const newOptions = options.tags
      ? insertFlakyIntoTags(slice, options.tags)
      : addTagsToOptions(slice);
    out = out.slice(0, options.start) + newOptions + out.slice(options.end);
    return { src: out, changed: true };
  }

  const insertAt = afterTitleComma + 1;
  out = out.slice(0, insertAt) + ` { tags: ['${FLAKY}'] },` + out.slice(insertAt);
  return { src: out, changed: true };
}

function main() {
  const file = process.argv[2];
  const title = process.argv[3];
  if (!file || title === undefined) {
    log('usage: tag-e2e-flaky.mjs <file> <title>');
    process.exit(1);
  }

  let src;
  try {
    src = readFileSync(file, 'utf8');
  } catch {
    log(`cannot read ${file}`);
    process.exit(1);
  }

  const calls = findItCalls(src);

  if (calls.some((c) => c.kind === 'skip' && c.title === title)) {
    log('abort: matching it.skip for title');
    process.exit(2);
  }

  const stringMatches = calls.filter(
    (c) => (c.kind === 'it' || c.kind === 'only') && !c.titleIsTemplate && c.title === title
  );

  if (stringMatches.length === 0) {
    if (calls.some((c) => (c.kind === 'it' || c.kind === 'only') && c.titleIsTemplate)) {
      log('abort: template-literal title (or no string match)');
    } else {
      log('abort: 0 matching it()/it.only()');
    }
    process.exit(2);
  }
  if (stringMatches.length > 1) {
    log(`abort: ${stringMatches.length} matching it()/it.only() for title`);
    process.exit(2);
  }

  const call = stringMatches[0];
  if (call.options?.tags?.hasFlaky) {
    log('already tagged @flaky; no-op');
    process.exit(2);
  }

  const { src: next, changed } = applyTag(src, call);
  if (!changed) {
    log('already tagged @flaky; no-op');
    process.exit(2);
  }

  writeFileSync(file, next, 'utf8');
  log(`tagged ${file}`);
  process.exit(0);
}

main();
