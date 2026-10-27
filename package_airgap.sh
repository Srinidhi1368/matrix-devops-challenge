#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="${RELEASE_VERSION:-1.4.8}"
TAG="${IMAGE_TAG:-$VERSION}"
BUNDLE="release_v${VERSION}.tar.gz"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$(mktemp -d)"
GENERATED_ENV=0

cleanup() {
  rm -rf "$STAGE"
  if [[ "$GENERATED_ENV" -eq 1 ]]; then
    rm -f "$ROOT/.env"
  fi
}
trap cleanup EXIT

for cmd in docker sha256sum tar find sort xargs; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: Required command not found: $cmd" >&2
    exit 1
  }
done

[[ -f "$ROOT/docker-compose.yml" && -f "$ROOT/.env.example" ]] || {
  echo "ERROR: docker-compose.yml or .env.example is missing." >&2
  exit 1
}

cd "$ROOT"

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  GENERATED_ENV=1
fi

export IMAGE_TAG="$TAG"

echo "Building release images..."
docker compose \
  --project-directory "$ROOT" \
  --file "$ROOT/docker-compose.yml" \
  --env-file "$ROOT/.env" \
  --project-name airgap-package-build \
  build

docker image inspect "eoir-vision-api:$TAG" >/dev/null
docker image inspect "eoir-inference-worker:$TAG" >/dev/null

PAYLOAD="$STAGE/release_v${VERSION}"
mkdir -p "$PAYLOAD"

# Copy project files while excluding secrets, Git data, old bundles,
# backups, and local build/cache artifacts.
tar -C "$ROOT" \
  --exclude='./.git' \
  --exclude='./.env' \
  --exclude='./release_v*.tar.gz' \
  --exclude='./*.bak' \
  --exclude='./*.pre_v1.4.8' \
  --exclude='./deploy_airgap.sh.before_retry_fix' \
  --exclude='./field_release' \
  --exclude='./field_release_143' \
  --exclude='./__pycache__' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='./field_release_146' \
  --exclude='./field_release_143' \
  --exclude='./models/.trt_cache' \
  --exclude='./.github/workflows/ci.yml.broken' \
  --exclude='./1' \
  -cf - . | tar -xf - -C "$PAYLOAD"

docker save \
  "eoir-vision-api:$TAG" \
  "eoir-inference-worker:$TAG" \
  -o "$PAYLOAD/images.tar"
# Normalize model permissions for non-root container access.
chmod 755 "$PAYLOAD/models"
chmod 644 "$PAYLOAD/models/manifest.json"
chmod 644 "$PAYLOAD/models/eo_detector_fp16.engine"

(
  cd "$PAYLOAD"
  find . -type f ! -name SHA256SUMS -print0 |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS
)

# Do not overwrite an existing bundle of the same version.
if [[ -e "$ROOT/$BUNDLE" ]]; then
  echo "ERROR: $BUNDLE already exists; refusing to overwrite it." >&2
  exit 1
fi

tar -C "$STAGE" -czf "$ROOT/$BUNDLE" "release_v${VERSION}"

echo "Created $ROOT/$BUNDLE"
echo "Bundle checksum:"
sha256sum "$ROOT/$BUNDLE"
echo "Verify its contents with:"
echo "  tar -xzf '$BUNDLE' -C /tmp/release-check --strip-components=1"
