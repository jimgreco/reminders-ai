import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

// Applies db/*.sql in order, once each, as the migrator role.
// Usage: MIGRATION_DATABASE_URL=postgres://reminders_ai_migrator@.../reminders_ai node src/migrate.js

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "db");

export async function migrate(connectionString) {
  const client = new pg.Client({ connectionString });
  await client.connect();
  try {
    // Production connects as the migration login and assumes the nonlogin
    // owner, so every object is owned by reminders_ai_owner, never by a login role.
    const role = process.env.MIGRATION_ROLE;
    if (role) {
      if (!/^[a-z][a-z0-9_]{0,62}$/.test(role)) throw new Error("MIGRATION_ROLE is not a valid role name");
      await client.query(`SET ROLE "${role}"`);
    }
    if (process.env.DATABASE_URL && process.env.MIGRATION_DATABASE_URL) {
      // Never run with both credentials loaded: the runtime must not hold migration access.
      throw new Error("unset DATABASE_URL before migrating");
    }
    await client.query("SELECT pg_advisory_lock(hashtext('reminders-ai-migrate'))");
    await client.query(`CREATE TABLE IF NOT EXISTS app_schema_versions (
      name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
    const files = (await fs.readdir(dir)).filter((f) => /^\d{3}_.+\.sql$/.test(f)).sort();
    const { rows } = await client.query("SELECT name FROM app_schema_versions");
    const applied = new Set(rows.map((r) => r.name));
    const ran = [];
    for (const file of files) {
      if (applied.has(file)) continue;
      const sql = await fs.readFile(path.join(dir, file), "utf8");
      await client.query("BEGIN");
      try {
        await client.query(sql);
        await client.query("INSERT INTO app_schema_versions (name) VALUES ($1)", [file]);
        await client.query("COMMIT");
        ran.push(file);
      } catch (error) {
        await client.query("ROLLBACK");
        throw new Error(`${file}: ${error.message}`);
      }
    }
    return ran;
  } finally {
    await client.end();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const url = process.env.MIGRATION_DATABASE_URL;
  if (!url) {
    console.error("MIGRATION_DATABASE_URL is required");
    process.exit(2);
  }
  migrate(url)
    .then((ran) => console.log(ran.length ? `applied ${ran.join(", ")}` : "schema up to date"))
    .catch((error) => {
      console.error(`migration failed: ${error.message}`);
      process.exit(1);
    });
}
