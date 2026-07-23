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
#   MAX_AGE_HOURS     Fail if the newest backup is older than this (default 48).
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

norm() { printf '%s' "$1" | tr ',' ' '; }
fail=0

# Freshness. The filename ends with -<UTC timestamp>.sql.gz.age, e.g.
# my-project-20260721T084923Z.sql.gz.age. Fail if the newest backup is stale, which
# would mean the daily backup pipeline has stopped producing artifacts.
max_age_hours="${MAX_AGE_HOURS:-48}"
ts_raw="$(basename "$BACKUP_FILE" | grep -oE '[0-9]{8}T[0-9]{6}Z' | tail -1 || true)"
if [ -n "$ts_raw" ]; then
  fmt="${ts_raw:0:4}-${ts_raw:4:2}-${ts_raw:6:2} ${ts_raw:9:2}:${ts_raw:11:2}:${ts_raw:13:2} UTC"
  bts="$(date -u -d "$fmt" +%s 2>/dev/null || true)"
  if [ -n "$bts" ]; then
    age_h=$(( ( $(date -u +%s) - bts ) / 3600 ))
    if [ "$age_h" -gt "$max_age_hours" ]; then
      log "STALE backup: newest is ${age_h}h old (> ${max_age_hours}h). Is the daily backup running?"
      fail=1
    else
      log "Freshness ok: backup is ${age_h}h old (<= ${max_age_hours}h)"
    fi
  fi
else
  log "WARN: could not parse timestamp from filename; skipping freshness check"
fi

log "Bootstrapping Supabase-like roles/extensions in ephemeral DB..."
psql "$PG_URL" -v ON_ERROR_STOP=1 -f "$HERE/bootstrap-roles.sql"

# Best-effort restore. Supabase dumps carry managed-environment noise (extensions,
# roles, publications, comments) that may not apply to a vanilla Postgres, so we do
# NOT abort on those. BUT we DO fail if any error touches YOUR data (the public
# schema or an expected table). The smoke checks below are the remaining assertions.
restore_log="$workdir/restore.log"
log "Restoring backup (best-effort; errors on your data still fail)..."
psql "$PG_URL" -v ON_ERROR_STOP=0 -f "$sql" 2>&1 | tee "$restore_log"

data_pat='public'
for t in $(norm "$EXPECTED_TABLES"); do
  [ -n "$t" ] && data_pat="$data_pat|$t"
done
if grep -E 'ERROR:' "$restore_log" | grep -Eq "($data_pat)"; then
  log "Restore produced error(s) touching your data (public schema / expected tables):"
  grep -E 'ERROR:' "$restore_log" | grep -E "($data_pat)" >&2 || true
  fail=1
fi

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

[ "$fail" -eq 0 ] || die "VERIFICATION FAILED: investigate the latest backup"
log "VERIFICATION PASSED: backup is restorable and contains expected tables."
