#!/usr/bin/env bash
# Shared helpers for supabase-backup-kit scripts.
# Sourced by backup.sh / restore.sh / verify.sh.

log() { printf '%s [backup-kit] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Mask a value in GitHub Actions logs (no-op outside Actions or when empty).
mask() {
  if [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "${1:-}" ]; then
    printf '::add-mask::%s\n' "$1"
  fi
}

# Fail unless every named env var is non-empty.
require_env() {
  local n
  for n in "$@"; do
    [ -n "${!n:-}" ] || die "required env var $n is not set"
  done
}

# Best-effort mask of the password inside a postgres URL.
mask_db_url() {
  local url="$1" pw
  mask "$url"
  pw="$(printf '%s' "$url" | sed -n 's#.*://[^:]*:\([^@]*\)@.*#\1#p' || true)"
  [ -n "$pw" ] && mask "$pw"
  return 0
}
