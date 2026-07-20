#!/usr/bin/env bash
# Prove a backup is restorable: decrypt -> restore into an ephemeral Postgres ->
# assert expected tables exist (and optionally have rows). "A backup is only
# good if it restores."
#
# Required env:
#   BACKUP_FILE       *.sql.gz.age
#   PG_URL            Connection string of a THROWAWAY Postgres (service container).
#   EXPECTED_TABLES   Space/comma separated public tables that MUST exist.
#   AGE_IDENTITY / AGE_IDENTITY_FILE
# Optional:
#   NONEMPTY_TABLES   Subset that MUST have >= 1 row.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh disable=SC1091
source "$HERE/lib.sh"

require_env BACKUP_FILE PG_URL EXPECTED_TABLES
command -v age >/dev/null || die "age not found"
command -v psql >/dev/null || die "psql not found"
[ -f "$BACKUP_FILE" ] || die "BACKUP_FILE not found: $BACKUP_FILE"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

idfile="$workdir/identity.key"
if [ -n "${AGE_IDENTITY_FILE:-}" ]; then
  idfile="$AGE_IDENTITY_FILE"
elif [ -n "${AGE_IDENTITY:-}" ]; then
  ( umask 077; printf '%s\n' "$AGE_IDENTITY" > "$idfile" )
else
  die "provide AGE_IDENTITY or AGE_IDENTITY_FILE"
fi

sql="$workdir/backup.sql"
log "Decrypting backup..."
age -d -i "$idfile" "$BACKUP_FILE" | gunzip > "$sql"
[ -s "$sql" ] || die "decrypted SQL is empty"

log "Bootstrapping Supabase-like roles/extensions in ephemeral DB..."
psql "$PG_URL" -v ON_ERROR_STOP=1 -f "$HERE/bootstrap-roles.sql"

log "Restoring backup into ephemeral DB (ON_ERROR_STOP=1)..."
psql "$PG_URL" -v ON_ERROR_STOP=1 -f "$sql"

norm() { printf '%s' "$1" | tr ',' ' '; }
fail=0

log "Checking expected tables exist..."
for t in $(norm "$EXPECTED_TABLES"); do
  [ -n "$t" ] || continue
  reg=$(psql "$PG_URL" -tAc "SELECT to_regclass('public.$t')")
  if [ -z "$reg" ]; then
    log "MISSING table: public.$t"; fail=1
  else
    log "ok: public.$t"
  fi
done

log "Checking non-empty tables..."
for t in $(norm "${NONEMPTY_TABLES:-}"); do
  [ -n "$t" ] || continue
  c=$(psql "$PG_URL" -tAc "SELECT count(*) FROM public.$t")
  if [ "${c:-0}" -lt 1 ]; then
    log "EMPTY (expected rows): public.$t"; fail=1
  else
    log "ok: public.$t has $c row(s)"
  fi
done

[ "$fail" -eq 0 ] || die "VERIFICATION FAILED — investigate the latest backup"
log "VERIFICATION PASSED — backup is restorable and contains expected tables."
