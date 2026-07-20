# supabase-backup-kit

Reusable, encrypted **backup / restore / verify** pipeline for **Supabase Postgres
on the free tier** (no PITR, no managed backups), driven entirely by **GitHub
Actions**. Built to be dropped into any project in minutes.

- 🔒 **Encrypted at rest** with [age](https://github.com/FiloSottile/age) (asymmetric — the backup job never holds the private key)
- 🗓️ **Daily backups** stored as GitHub Actions artifacts (auto-expiring = free cleanup)
- ♻️ **Disaster recovery** via a guarded manual workflow (typed confirmation + dry-run)
- ✅ **Monthly restore test** into an ephemeral Postgres — *a backup is only good if it restores*
- 📦 **Public & generic** — zero secrets or project values live here

> Why GitHub Actions + artifacts? The scheduler, compute and storage are all free
> within the GitHub plan, there's no extra service to run, and `retention-days`
> makes cleanup automatic. See [Limitations](#limitations).

## How it works

```
        ┌─────────────────────── this kit (public) ───────────────────────┐
        │  backup/  restore/  verify/  (composite actions)                 │
        │  scripts/ backup.sh restore.sh verify.sh bootstrap-roles.sql     │
        └──────────────────────────────────────────────────────────────────┘
                                   ▲ uses: owner/supabase-backup-kit/<action>@v1
                                   │
  ┌──────────────── your PRIVATE project repo ─────────────────┐
  │ .github/workflows/                                         │
  │   supabase-backup-daily.yml   (cron)  → backup            │  artifacts stored
  │   supabase-backup-verify.yml  (cron)  → verify            │  in YOUR repo
  │   supabase-restore.yml     (manual)   → restore (DR)      │
  │ secrets: SUPABASE_DB_URL, AGE_SECRET_KEY, RESTORE_*_DB_URL │
  │ vars:    AGE_PUBLIC_KEY                                    │
  └───────────────────────────────────────────────────────────┘
```

`backup.sh` runs `supabase db dump` three times (roles → schema → data),
concatenates, `gzip`s and `age`-encrypts into `PREFIX-<UTC>.sql.gz.age`, which is
uploaded as an artifact with a retention window. Restore/verify decrypt with the
private key.

## Requirements

- A Supabase project (any tier).
- The **pooler (session mode) connection string** — GitHub runners are IPv4 and
  Supabase direct connections are IPv6-only, so the pooler is mandatory:
  `postgresql://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres`
  (Supabase Dashboard → Project Settings → Database → *Connection string* → **Session pooler**).
- An age key pair (below).

## Quick start (add to a project)

**1. Generate an age key pair** (once per project; keep the private key safe):

```bash
age-keygen -o age-key.txt
# Public key printed as: "Public key: age1........"
```

**2. Add repository secrets & variables** (Settings → Secrets and variables → Actions):

| Name | Kind | Value |
|------|------|-------|
| `SUPABASE_DB_URL` | secret | session-pooler connection string |
| `AGE_PUBLIC_KEY` | variable | the `age1...` public key |
| `AGE_SECRET_KEY` | secret | full contents of `age-key.txt` (the `AGE-SECRET-KEY-...` line) |
| `RESTORE_STAGING_DB_URL` | secret | pooler URL of a staging/throwaway DB (for DR tests) |
| `RESTORE_PROD_DB_URL` | secret | pooler URL of production (used only by the guarded restore) |

> Store `age-key.txt` **offline as well** (password manager / vault). Without the
> private key, backups are unrecoverable — that is the whole point of encryption.

**3. Copy the three workflows** from [`examples/`](examples/) into your repo's
`.github/workflows/`, edit the `backup_prefix`, `expected_tables`, cron times, and
pin `@v1` to your chosen ref. Done.

## The three actions

### `backup` — daily encrypted backup
```yaml
- uses: alessonviana/supabase-backup-kit/backup@v1
  with:
    supabase_db_url: ${{ secrets.SUPABASE_DB_URL }}
    age_recipient:   ${{ vars.AGE_PUBLIC_KEY }}
    backup_prefix:   my-project
    retention_days:  7
```

### `verify` — restore into ephemeral Postgres + smoke checks
Requires a `postgres` **service container** in the calling job (see the example).
```yaml
- uses: alessonviana/supabase-backup-kit/verify@v1
  with:
    backup_file:     ./verify-in/<name>.sql.gz.age
    age_identity:    ${{ secrets.AGE_SECRET_KEY }}
    pg_url:          postgresql://postgres:postgres@localhost:5432/verify
    expected_tables: "sales products"
    nonempty_tables: ""     # optional
```

### `restore` — disaster recovery (guarded, manual)
```yaml
- uses: alessonviana/supabase-backup-kit/restore@v1
  with:
    backup_file:           ./restore-in/<name>.sql.gz.age
    age_identity:          ${{ secrets.AGE_SECRET_KEY }}
    restore_target_db_url: ${{ secrets.RESTORE_STAGING_DB_URL }}
    dry_run:               true    # false to actually write
```

## Restore locally (fallback if CI is down)

```bash
# needs: age, gzip, psql
age -d -i age-key.txt backup.sql.gz.age | gunzip > backup.sql
psql "$RESTORE_TARGET_DB_URL" -v ON_ERROR_STOP=1 -f backup.sql
```

## Limitations

- **Artifact retention ≤ 90 days** and counts against the repo's Actions storage
  quota (500 MB on Free). Fine for small DBs. For long-term retention, swap the
  `upload-artifact` step for an upload to object storage (e.g. **Cloudflare R2**) —
  the dump/encryption logic is unchanged.
- **GitHub is a single storage location.** For a real off-site copy, periodically
  download the latest `.age` to a separate vault, or move to R2/S3.
- **Verify uses a vanilla Postgres.** `bootstrap-roles.sql` stubs common Supabase
  roles/extensions; extend it if your schema needs more (postgis, pg_trgm, …).

## Development

`.github/workflows/ci.yml` runs `shellcheck` + `actionlint` on every push/PR.
See [SECURITY.md](SECURITY.md) for the security model.

## License

[MIT](LICENSE).
