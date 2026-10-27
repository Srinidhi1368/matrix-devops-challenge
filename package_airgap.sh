#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="${RELEASE_VERSION:-1.4.2}"
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

command -v docker >/dev/null || {
  echo "ERROR: Docker is required." >&2
  exit 1
}
command -v sha256sum >/dev/null || {
  echo "ERROR: sha256sum is required." >&2
  exit 1
}
command -v tar >/dev/null || {
  echo "ERROR: tar is required." >&2
  exit 1
}
command -v find >/dev/null || {
  echo "ERROR: find is required." >&2
  exit 1
}

[[ -f "$ROOT/.env.example" ]] || {
  echo "ERROR: .env.example is missing." >&2
  exit 1
}

cd "$ROOT"

# Compose requires database variables even during image builds.
# Generate a temporary local .env only when one does not already exist.
if [[ ! -f "$ROOT/.env" ]]; then
  cp .env.example .env
  chmod 600 .env
  GENERATED_ENV=1
  echo "Using a temporary .env for the image build."
fi

export IMAGE_TAG="$TAG"

docker compose build

docker image inspect "eoir-vision-api:$TAG" >/dev/null
docker image inspect "eoir-inference-worker:$TAG" >/dev/null

PAYLOAD="$STAGE/release_v${VERSION}"
mkdir -p "$PAYLOAD"

# Never package local secrets, release archives, or Git metadata.
tar \
  --exclude='./.git' \
  --exclude='./.env' \
  --exclude='./release_v*.tar.gz' \
  --exclude='./*.bak' \
  --exclude='./__pycache__' \
  --exclude='./models/.trt_cache' \
  -cf - . | tar -xf - -C "$PAYLOAD"

docker save \
  "eoir-vision-api:$TAG" \
  "eoir-inference-worker:$TAG" \
  -o "$PAYLOAD/images.tar"

(
  cd "$PAYLOAD"
  find . -type f ! -name SHA256SUMS -print0 |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS
)

tar -C "$STAGE" -czf "$ROOT/$BUNDLE" "release_v${VERSION}"

echo "Release bundle created: $ROOT/$BUNDLE"
sha256sum "$ROOT/$BUNDLE"
echo "The bundle excludes .env and includes payload checksums."
