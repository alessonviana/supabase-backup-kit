# supabase-backup-kit

Reusable, encrypted **backup / restore / verify** pipeline for **Supabase Postgres
on the free tier** (no PITR, no managed backups), driven entirely by **GitHub
Actions**. Built to be dropped into any project in minutes.

- 🔒 **Encrypted at rest** with [age](https://github.com/FiloSottile/age) (asymmetric, so the backup job never holds the private key)
- 🗓️ **Daily backups** stored as GitHub Actions artifacts (auto-expiring = free cleanup)
- 🌍 **Optional off-site copy** to any S3-compatible bucket with Object Lock (free tiers: Backblaze B2 / Cloudflare R2) — see [Off-site copy](docs/OFF-SITE.md)
- ♻️ **Disaster recovery** via a guarded manual workflow (typed confirmation + dry-run)
- ✅ **Monthly restore test** into an ephemeral Postgres (*a backup is only good if it restores*)
- 📦 **Public & generic**: zero secrets or project values live here

> Why GitHub Actions + artifacts? The scheduler, compute and storage are all free
> within the GitHub plan, there's no extra service to run, and `retention-days`
> makes cleanup automatic. See [Limitations](#limitations).

## How it works

![How supabase-backup-kit works](assets/supabase-backup-kit.png)

This kit is **not vendored into your project**; your private repo only holds thin
workflow files that reference the actions remotely (`uses: alessonviana/supabase-backup-kit/<action>@v1`).
GitHub fetches the kit at run time; your secrets never leave your repo.

`backup.sh` runs `supabase db dump` three times (roles → schema → data),
concatenates, `gzip`s and `age`-encrypts into `PREFIX-<UTC>.sql.gz.age`, which is
uploaded as an artifact with a retention window. Restore/verify decrypt with the
private key.

## Requirements

- A Supabase project (any tier).
- The **pooler (session mode) connection string**: GitHub runners are IPv4 and
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
> private key, backups are unrecoverable; that is the whole point of encryption.

**3. Copy the three workflows** from [`examples/`](examples/) into your repo's
`.github/workflows/`, set the cron times, and pin `@v1` to your chosen ref. Done.

## Configuration via repository Variables (optional)

The example workflows read these **optional** repository Variables and fall back to
sensible defaults when they are unset, so you can tune behavior without editing YAML:

| Variable | Drives | Default |
|----------|--------|---------|
| `BACKUP_PREFIX` | backup artifact name (and the verify lookup) | `my-project` |
| `BACKUP_RETENTION_DAYS` | how long artifacts are kept (max 90) | `7` |
| `VERIFY_EXPECTED_TABLES` | tables the verify job asserts exist | (per project) |
| `VERIFY_NONEMPTY_TABLES` | tables that must have at least one row | (empty) |
| `BACKUP_S3_BUCKET` | off-site bucket (empty = off-site disabled) | (empty) |
| `BACKUP_S3_ENDPOINT` | S3 endpoint (empty = AWS S3) | (empty) |
| `BACKUP_S3_REGION` | off-site region (`auto` for R2) | `auto` |
| `BACKUP_S3_PREFIX` | key prefix inside the bucket | (empty) |

> The off-site copy also needs two **secrets** (`BACKUP_S3_ACCESS_KEY_ID`,
> `BACKUP_S3_SECRET_ACCESS_KEY`). It is fully optional. See [Off-site copy](docs/OFF-SITE.md).
>
> **The schedule is the one thing Variables cannot drive.** GitHub does not allow
> expressions in `on.schedule.cron`, so the backup time and the verify day/frequency
> live as literal `cron` lines in each workflow. Editing that one line is the
> per-project schedule knob (e.g. `0 7 * * 6` for every Saturday at 07:00 UTC).

## The three actions

### `backup`: daily encrypted backup
```yaml
- uses: alessonviana/supabase-backup-kit/backup@v1
  with:
    supabase_db_url: ${{ secrets.SUPABASE_DB_URL }}
    age_recipient:   ${{ vars.AGE_PUBLIC_KEY }}
    backup_prefix:   my-project
    retention_days:  7
```

### `verify`: restore into ephemeral Postgres + smoke checks
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

### `restore`: disaster recovery (guarded, manual)
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
  `upload-artifact` step for an upload to object storage (e.g. **Cloudflare R2**);
  the dump/encryption logic is unchanged.
- **GitHub artifacts are ephemeral and deletable.** Anyone with `actions: write`
  (or the account itself) can delete them, and they auto-expire. For resilience
  against account compromise / ransomware, enable the optional immutable
  [off-site copy](docs/OFF-SITE.md) (free tiers: Backblaze B2 / Cloudflare R2).
- **Verify uses a vanilla Postgres.** `bootstrap-roles.sql` stubs common Supabase
  roles/extensions; extend it if your schema needs more (postgis, pg_trgm, …).

## Development

`.github/workflows/ci.yml` runs `shellcheck` + `actionlint` on every push/PR.
See [SECURITY.md](SECURITY.md) for the security model.

## License

[MIT](LICENSE).
