# Off-site copy (optional)

By default a backup lives **only** as a GitHub Actions artifact. That is convenient
but it is **not** a tamper-proof vault:

- Artifacts are **deletable** by anyone with `actions: write` on the repo (a leaked
  PAT, a malicious workflow, or the account/org itself).
- Artifacts **auto-expire** (`retention_days`, max 90). They are ephemeral by design.

So against a **compromised GitHub account** or **ransomware**, the GitHub copy alone
is not enough. What *does* protect you is a second copy that is:

1. **Off GitHub**, a separate storage provider / account.
2. **Immutable**, Object Lock / WORM, so it cannot be deleted or overwritten before
   its retention expires, *even by the account owner*.
3. **Written with a delete-less key**, the backup job can only add objects, never
   remove them.

This is entirely **opt-in**: leave `s3_bucket` empty and nothing changes. Set it and
every daily backup also gets copied to your bucket. The upload uses the S3 API, so it
works the same on free and paid providers, you only swap the endpoint.

> The backup is already `age`-encrypted before it leaves the runner, so the off-site
> provider only ever sees an opaque `*.sql.gz.age` blob. It never holds the age
> private key and cannot read your data.

---

## Free + immutable options

Both have a genuinely free tier **and** support Object Lock, which is exactly what you
need for ransomware resilience.

### Backblaze B2 (10 GB free, Object Lock), recommended free option

1. Create a B2 account → **Buckets → Create a Bucket**.
   - Files in this bucket are: **Private**
   - **Object Lock: Enable** (this is the immutability switch, it can only be set at
     creation on some UIs; enable it now).
2. After creation, set a **default retention** on the bucket (e.g. 30 days, *Governance*
   or *Compliance* mode). Every uploaded object inherits it and cannot be deleted until
   it expires.
3. **Application Keys → Add a New Application Key**:
   - Restrict to the bucket above.
   - Capabilities: **`writeFiles` and `listBuckets`/`listFiles` only, do NOT grant
     `deleteFiles`.** This is the write-only key.
4. Note your S3 endpoint (Bucket details → *Endpoint*), e.g.
   `s3.us-west-004.backblazeb2.com`. The region is the middle part, `us-west-004`.

Values to configure (see table below):

| Setting | Value |
|---------|-------|
| `s3_endpoint` | `https://s3.us-west-004.backblazeb2.com` |
| `s3_region` | `us-west-004` |
| `s3_access_key_id` | the `keyID` |
| `s3_secret_access_key` | the `applicationKey` |

### Cloudflare R2 (10 GB/month free, Object Lock)

1. **R2 → Create bucket**, then enable **Object Lock** and add a default retention rule.
2. **Manage R2 API Tokens → Create API Token**:
   - Permissions: **Object Read & Write** scoped to that bucket. R2 tokens cannot be
     narrowed to "no delete" as granularly as B2/S3, so rely on Object Lock as the real
     guarantee here.
3. Endpoint is `https://<account_id>.r2.cloudflarestorage.com`, region `auto`.

| Setting | Value |
|---------|-------|
| `s3_endpoint` | `https://<account_id>.r2.cloudflarestorage.com` |
| `s3_region` | `auto` |
| `s3_access_key_id` | the R2 token access key id |
| `s3_secret_access_key` | the R2 token secret |

---

## Paid options

Same mechanism, just a different endpoint.

- **AWS S3**, create the bucket with **Object Lock** enabled (**Compliance** mode for
  the strongest guarantee: not even the root account can delete before retention). Use
  an IAM key with only `s3:PutObject` (no `s3:DeleteObject`). Leave `s3_endpoint`
  **empty** and set `s3_region` to the real region.
- **Wasabi / MinIO / other S3-compatible**, set `s3_endpoint` to the provider's S3 URL
  and the matching region.

---

## Configure it

Add these to your consumer repo (**Settings → Secrets and variables → Actions**). All
are optional; omit `BACKUP_S3_BUCKET` to keep the feature off.

| Name | Kind | Example |
|------|------|---------|
| `BACKUP_S3_BUCKET` | variable | `my-supabase-backups` |
| `BACKUP_S3_ENDPOINT` | variable | `https://s3.us-west-004.backblazeb2.com` (empty for AWS S3) |
| `BACKUP_S3_REGION` | variable | `us-west-004` (`auto` for R2) |
| `BACKUP_S3_PREFIX` | variable | `marinas-de-aco/` (optional folder inside the bucket) |
| `BACKUP_S3_ACCESS_KEY_ID` | secret | write-only key id |
| `BACKUP_S3_SECRET_ACCESS_KEY` | secret | write-only key secret |

The [daily backup example](../examples/supabase-backup-daily.yml) already wires these
up. Once set, each run logs `Off-site copy verified: <key> (<bytes>)`.

---

## Restoring from the off-site copy

The blob is identical to the GitHub artifact, so the normal restore/verify flow works
after you download it:

```bash
# needs: age, gzip, psql, aws
aws s3 cp "s3://my-supabase-backups/marinas-de-aco/my-project-<UTC>.sql.gz.age" . \
  --endpoint-url "https://s3.us-west-004.backblazeb2.com"
age -d -i age-key.txt my-project-<UTC>.sql.gz.age | gunzip > backup.sql
psql "$RESTORE_TARGET_DB_URL" -v ON_ERROR_STOP=1 -f backup.sql
```

## Why the write-only key matters

Object Lock stops deletion; the write-only key stops the attacker from even *trying*,
and stops accidental cleanup scripts. Together they mean: **a full compromise of your
GitHub repo/account can neither read (age) nor delete (Object Lock + no-delete key) the
off-site backups.** That is the property GitHub artifacts alone cannot give you.
