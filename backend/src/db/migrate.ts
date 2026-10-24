import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

export function createPool(databaseUrl: string): pg.Pool {
  // bigint columns hold epoch-ms values, which fit safely in a JS number.
  pg.types.setTypeParser(20, (v) => Number(v));
  const pool = new pg.Pool({
    connectionString: databaseUrl,
    max: 10,
    connectionTimeoutMillis: 10_000,
    idleTimeoutMillis: 30_000,
    // A request that runs far longer than any real one is stuck; stop it instead of piling up connections.
    statement_timeout: 20_000,
  });
  // The database can restart (maintenance, a failover). An idle connection that drops then emits an error, and an
  // unhandled one would stop the whole server. The pool replaces the connection by itself; just note it.
  pool.on('error', (err) => console.error('database connection dropped:', err instanceof Error ? err.message : 'unknown'));
  return pool;
}

/** Applies *.sql files in order, each in its own transaction, recording what ran. */
export async function migrate(pool: pg.Pool, dir = new URL('./migrations/', import.meta.url)): Promise<string[]> {
  await pool.query(
    'CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())',
  );
  const done = new Set((await pool.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name as string));
  const files = (await readdir(dir)).filter((f) => f.endsWith('.sql')).sort();
  const applied: string[] = [];
  for (const f of files) {
    if (done.has(f)) continue;
    const sql = await readFile(new URL(f, dir), 'utf8');
    const c = await pool.connect();
    try {
      await c.query('BEGIN');
      await c.query(sql);
      await c.query('INSERT INTO schema_migrations(name) VALUES ($1)', [f]);
      await c.query('COMMIT');
      applied.push(f);
    } catch (err) {
      await c.query('ROLLBACK');
      throw err;
    } finally {
      c.release();
    }
  }
  return applied;
}

// `npm run migrate` (dev) / `npm run migrate:prod`
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const url = process.env.DATABASE_URL;
  if (!url) {
    console.error('DATABASE_URL is required');
    process.exit(1);
  }
  const pool = createPool(url);
  migrate(pool)
    .then((a) => console.log(a.length ? `applied: ${a.join(', ')}` : 'up to date'))
    .catch((e) => {
      console.error('migration failed:', e instanceof Error ? e.message : e);
      process.exitCode = 1;
    })
    .finally(() => pool.end());
}
