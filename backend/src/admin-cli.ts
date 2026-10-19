/**
 * Creates one of the first admins. Run it on a trusted machine with database access:
 *
 *   npm run admin:create -- alice@example.ng
 *
 * It prints a one-time password and an authenticator secret. Hand them over in person or through a
 * password manager, never by SMS or chat. It refuses to run once two admins exist: from then on,
 * new admins are added through the two-person approval flow.
 */
import { loadConfig } from './config/env.js';
import { createPool, migrate } from './db/migrate.js';
import { FieldCrypto } from './lib/field-crypto.js';
import { PgAudit } from './modules/audit/pg-audit.js';
import { PgAdminActions, PgAdminStore } from './modules/admin/pg-admin-store.js';
import { AdminService, MIN_ACTIVE_ADMINS } from './modules/admin/service.js';

const email = process.argv[2];
if (!email) {
  console.error('usage: npm run admin:create -- <email>');
  process.exit(1);
}
const env = loadConfig();
if (env.STORE !== 'postgres' || !env.DATABASE_URL || !env.DATA_KEY || !env.PHONE_HMAC_KEY || !env.ADMIN_JWT_SECRET) {
  console.error('needs STORE=postgres, DATABASE_URL, DATA_KEY, PHONE_HMAC_KEY and ADMIN_JWT_SECRET');
  process.exit(1);
}
const pool = createPool(env.DATABASE_URL);
await migrate(pool);
const store = new PgAdminStore(pool);
if ((await store.countActiveAdmins()) >= MIN_ACTIVE_ADMINS) {
  console.error(`${MIN_ACTIVE_ADMINS} admins already exist. Add more through the approval flow (admin_add).`);
  await pool.end();
  process.exit(1);
}
const svc = new AdminService(store, new PgAdminActions(pool), new PgAudit(pool), new FieldCrypto(env.DATA_KEY, env.PHONE_HMAC_KEY), env.ADMIN_JWT_SECRET);
const p = await svc.provision(email, 'bootstrap-cli');
console.log(`\nAdmin created: ${p.email}\nPassword (shown once): ${p.password}\nAuthenticator secret: ${p.totpSecret}\nAdd to your authenticator app with this link:\n${p.otpauthUri}\n`);
await pool.end();
