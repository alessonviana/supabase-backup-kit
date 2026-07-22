#!/usr/bin/env bash
# Copy an already-encrypted backup to an S3-compatible bucket (off-site copy).
#
# Works with any S3-compatible storage by setting S3_ENDPOINT:
#   Backblaze B2   (free 10GB, Object Lock)  -> https://s3.<region>.backblazeb2.com
#   Cloudflare R2  (free 10GB, Object Lock)  -> https://<account>.r2.cloudflarestorage.com
#   AWS S3         (Object Lock)             -> (leave S3_ENDPOINT empty)
#   Wasabi / MinIO / ...                     -> the provider's S3 endpoint
#
# The uploaded object is only made *immutable* by the bucket's own Object Lock /
# retention policy. This script does not (and cannot) enforce that; configure it
# once on the bucket. See README "Off-site copy".
#
# Required env:
#   ARTIFACT_PATH          Path to the *.sql.gz.age file produced by backup.sh.
#   S3_BUCKET              Destination bucket name.
#   AWS_ACCESS_KEY_ID      Credential id. Prefer a WRITE-ONLY key (no delete).
#   AWS_SECRET_ACCESS_KEY  Credential secret. SENSITIVE.
# Optional:
#   S3_ENDPOINT           Custom endpoint URL (empty = real AWS S3).
#   S3_REGION             Region ("auto" for R2; real region for B2/S3). Default: auto.
#   S3_PREFIX             Key prefix inside the bucket, e.g. "backups/". Default: none.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh disable=SC1091
source "$HERE/lib.sh"

require_env ARTIFACT_PATH S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
[ -f "$ARTIFACT_PATH" ] || die "ARTIFACT_PATH does not exist: $ARTIFACT_PATH"
command -v aws >/dev/null || die "aws CLI not found (the action installs it)"

# Credentials must never surface in logs.
mask "$AWS_ACCESS_KEY_ID"
mask "$AWS_SECRET_ACCESS_KEY"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="${S3_REGION:-auto}"

endpoint_args=()
[ -n "${S3_ENDPOINT:-}" ] && endpoint_args=(--endpoint-url "$S3_ENDPOINT")

# Normalize prefix: strip leading slash, ensure a single trailing slash if set.
prefix="${S3_PREFIX:-}"
prefix="${prefix#/}"
[ -n "$prefix" ] && prefix="${prefix%/}/"

fname="$(basename "$ARTIFACT_PATH")"
key="${prefix}${fname}"
dest="s3://${S3_BUCKET}/${key}"

log "Uploading off-site copy -> $dest"
aws s3 cp "$ARTIFACT_PATH" "$dest" --only-show-errors "${endpoint_args[@]}"

# Confirm the object landed and matches the local size (defence against a silent
# partial upload). head-object also fails loudly on a bad endpoint/credential.
local_size=$(wc -c < "$ARTIFACT_PATH")
remote_size=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$key" \
  --query 'ContentLength' --output text "${endpoint_args[@]}")
[ "$remote_size" = "$local_size" ] || \
  die "off-site size mismatch: local=$local_size remote=$remote_size"

log "Off-site copy verified: $key ($remote_size bytes)"
