#!/usr/bin/env bash
# Create an encrypted logical backup of a Supabase Postgres database.
#
# Required env:
#   SUPABASE_DB_URL  Pooler (session mode) connection string. Contains a password
#                    and is masked in logs. Must be IPv4-reachable (GitHub runners
#                    are IPv4; Supabase direct connections are IPv6-only).
#   AGE_RECIPIENT    age public key(s) (age1...), one per line for multiple.
#   BACKUP_PREFIX    Filename prefix, e.g. the project slug.
# Optional:
#   OUTPUT_DIR       Where to write the artifact (default: ./backup-out).
#
# Output: $OUTPUT_DIR/$BACKUP_PREFIX-<UTC timestamp>.sql.gz.age
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh disable=SC1091
source "$HERE/lib.sh"

require_env SUPABASE_DB_URL AGE_RECIPIENT BACKUP_PREFIX
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/backup-out}"

mask_db_url "$SUPABASE_DB_URL"
command -v supabase >/dev/null || die "supabase CLI not found"
command -v age >/dev/null || die "age not found"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Roles first, then schema (may GRANT to roles), then data — restore-safe order.
log "Dumping roles..."
supabase db dump --db-url "$SUPABASE_DB_URL" --role-only -f "$workdir/roles.sql"
log "Dumping schema..."
supabase db dump --db-url "$SUPABASE_DB_URL" -f "$workdir/schema.sql"
log "Dumping data..."
supabase db dump --db-url "$SUPABASE_DB_URL" --data-only -f "$workdir/data.sql"

cat "$workdir/roles.sql" "$workdir/schema.sql" "$workdir/data.sql" > "$workdir/backup.sql"

# Guard against "successful but useless" backups.
size=$(wc -c < "$workdir/backup.sql")
[ "$size" -ge 1024 ] || die "backup.sql suspiciously small ($size bytes)"
grep -q 'CREATE TABLE' "$workdir/schema.sql" || die "schema dump has no CREATE TABLE"

# Build age recipient args (one public key per line).
recips=()
while IFS= read -r line; do
  [ -n "$line" ] && recips+=(-r "$line")
done <<< "$AGE_RECIPIENT"
[ "${#recips[@]}" -gt 0 ] || die "no age recipients parsed from AGE_RECIPIENT"

mkdir -p "$OUTPUT_DIR"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="$OUTPUT_DIR/${BACKUP_PREFIX}-${ts}.sql.gz.age"
log "Compressing + encrypting -> $out"
gzip -9 -c "$workdir/backup.sql" | age "${recips[@]}" -o "$out"

encsize=$(wc -c < "$out")
[ "$encsize" -ge 512 ] || die "encrypted output suspiciously small ($encsize bytes)"
log "Backup complete: $(basename "$out") ($encsize bytes, plaintext $size bytes)"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "artifact_path=$out"
    echo "artifact_name=$(basename "$out")"
  } >> "$GITHUB_OUTPUT"
fi
