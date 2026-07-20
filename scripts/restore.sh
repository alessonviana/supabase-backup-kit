#!/usr/bin/env bash
# Restore an encrypted backup produced by backup.sh into a target database.
#
# Required env:
#   BACKUP_FILE            Path to a *.sql.gz.age file.
#   AGE_IDENTITY           age private key contents (AGE-SECRET-KEY-...), OR
#   AGE_IDENTITY_FILE      path to an age identity file.
# For a real restore (DRY_RUN != 1):
#   RESTORE_TARGET_DB_URL  psql connection string of the TARGET database.
# Optional:
#   DRY_RUN                "1" = decrypt + summarize only, never touch a DB.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh disable=SC1091
source "$HERE/lib.sh"

require_env BACKUP_FILE
[ -f "$BACKUP_FILE" ] || die "BACKUP_FILE not found: $BACKUP_FILE"
command -v age >/dev/null || die "age not found"

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
log "Decrypting + decompressing $(basename "$BACKUP_FILE")"
age -d -i "$idfile" "$BACKUP_FILE" | gunzip > "$sql"
[ -s "$sql" ] || die "decrypted SQL is empty (wrong key or corrupt backup?)"

tables=$(grep -c '^CREATE TABLE' "$sql" || true)
copies=$(grep -c '^COPY ' "$sql" || true)
log "Decrypted OK: $(wc -c < "$sql") bytes, ${tables} CREATE TABLE, ${copies} COPY block(s)"

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "DRY_RUN=1 -> not touching any database. Summary above."
  exit 0
fi

require_env RESTORE_TARGET_DB_URL
mask_db_url "$RESTORE_TARGET_DB_URL"
command -v psql >/dev/null || die "psql not found"

log "Restoring into TARGET database (ON_ERROR_STOP=1)..."
psql "$RESTORE_TARGET_DB_URL" -v ON_ERROR_STOP=1 -f "$sql"
log "Restore complete."
