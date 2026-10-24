import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * A guard, not a proof: it fails the moment anyone builds SQL out of text. Every value that comes from a person must
 * reach the database as a bound parameter ($1, $2, ...). The few places that put fixed fragments of SQL together are
 * listed here after review. A new one fails this test until someone has checked it and added it.
 */
const SRC = fileURLToPath(new URL('../src/', import.meta.url));

function tsFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? tsFiles(p) : p.endsWith('.ts') ? [p] : [];
  });
}
const rel = (p: string) => relative(SRC, p).replaceAll('\\', '/');
const SQL_WORDS = /\b(SELECT|INSERT INTO|UPDATE|DELETE FROM|WHERE|ORDER BY|LIMIT)\b/;
const TEMPLATE = /`((?:[^`\\]|\\.)*)`/gs;

/** Reviewed: every ${} below is a fixed fragment written in our own code, never request data. */
const REVIEWED_INTERPOLATIONS: Record<string, string[][]> = {
  'modules/dispatch/pg-directory.ts': [['PgDirectory.SELECT', 'PgDirectory.RANK'], ['PgDirectory.SELECT']], // static column list / ranking
  'modules/inbox/pg-inbox.ts': [['insert', 'refresh'], ['insert', 'refresh']], // static INSERT and ON CONFLICT text
  'modules/sos/pg-store.ts': [['sql'], ['sql']], // "col = $n" pairs; column names come only from the fixed COLS map
};

/** Reviewed: query() calls whose first argument is a variable (built from the fragments above, or a shipped file). */
const REVIEWED_VARIABLE_QUERIES = new Set(['db/migrate.ts: sql', 'modules/inbox/pg-inbox.ts: sql']);

describe('SQL is never built from text', () => {
  const files = tsFiles(SRC);

  it('only the reviewed template literals put anything inside SQL', () => {
    const found: Record<string, string[][]> = {};
    for (const f of files) {
      for (const m of readFileSync(f, 'utf8').matchAll(TEMPLATE)) {
        const body = m[1]!;
        if (!SQL_WORDS.test(body) || !body.includes('${')) continue;
        (found[rel(f)] ??= []).push([...body.matchAll(/\$\{([^}]*)\}/g)].map((x) => x[1]!.trim()));
      }
    }
    expect(found).toEqual(REVIEWED_INTERPOLATIONS);
  });

  it('only the reviewed query() calls take a variable instead of a literal', () => {
    const found = new Set<string>();
    for (const f of files) {
      for (const m of readFileSync(f, 'utf8').matchAll(/\.query(?:<[^>]*>)?\(\s*([^\s`'"][^,)]*)/g)) found.add(`${rel(f)}: ${m[1]!.trim()}`);
    }
    expect(found).toEqual(REVIEWED_VARIABLE_QUERIES);
  });

  it('nothing is added onto a SQL string with +', () => {
    for (const f of files) {
      expect(/\.query(?:<[^>]*>)?\(\s*['"`][^'"`]*['"`]\s*\+/.test(readFileSync(f, 'utf8')), rel(f)).toBe(false);
    }
  });

  it('the reviewed fragments really are fixed text', () => {
    const dir = readFileSync(join(SRC, 'modules/dispatch/pg-directory.ts'), 'utf8');
    for (const name of ['SELECT', 'RANK']) {
      const m = new RegExp(`static\\s+(?:readonly\\s+)?${name}\\s*=\\s*([\`'"])([\\s\\S]*?)\\1\\s*;`).exec(dir);
      expect(m, `PgDirectory.${name}`).not.toBeNull();
      expect(m![2]!.includes('${')).toBe(false);
    }
    const inbox = readFileSync(join(SRC, 'modules/inbox/pg-inbox.ts'), 'utf8');
    for (const name of ['insert', 'refresh']) {
      const m = new RegExp(`const\\s+${name}\\s*=\\s*\`([\\s\\S]*?)\`;`).exec(inbox);
      expect(m, `inbox ${name}`).not.toBeNull();
      expect(m![1]!.includes('${')).toBe(false);
    }
  });

  it('the SOS update only ever uses column names from its fixed map', () => {
    const store = readFileSync(join(SRC, 'modules/sos/pg-store.ts'), 'utf8');
    expect(store).toContain('Object.hasOwn(COLS, k)');
    expect(store).toMatch(/\$\$\{firstParam \+ values\.length - 1\}/); // values are always numbered parameters
  });
});
