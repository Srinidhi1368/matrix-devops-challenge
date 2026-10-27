#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BUNDLE="${1:-release_v1.4.8.tar.gz}"
DEST="${2:-./field_release_143}"
IMAGE_TAG="${IMAGE_TAG:-1.4.8}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-eoir-field}"
API_HOST_IP="${API_HOST_IP:-0.0.0.0}"
API_HOST_PORT="${API_HOST_PORT:-8000}"

for cmd in docker sha256sum tar python3 curl realpath find cmp cp; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: Required command not found: $cmd" >&2
    exit 1
  }
done

[[ -f "$BUNDLE" ]] || {
  echo "ERROR: Release bundle not found: $BUNDLE" >&2
  exit 1
}
BUNDLE="$(realpath "$BUNDLE")"

mkdir -p "$DEST"
DEST="$(realpath "$DEST")"

[[ "$API_HOST_PORT" =~ ^[0-9]+$ ]] &&
  (( API_HOST_PORT >= 1 && API_HOST_PORT <= 65535 )) || {
    echo "ERROR: API_HOST_PORT must be between 1 and 65535." >&2
    exit 1
  }

[[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || {
  echo "ERROR: Invalid Compose project name: $COMPOSE_PROJECT_NAME" >&2
  exit 1
}

# Reject unsafe archive paths and non-regular archive entries.
python3 - "$BUNDLE" <<'PY'
import sys
import tarfile
from pathlib import PurePosixPath

try:
    with tarfile.open(sys.argv[1], "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError("archive is empty")

        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError(f"unsafe archive path: {member.name}")
            if not (member.isfile() or member.isdir()):
                raise ValueError(
                    f"unsupported archive entry type: {member.name}"
                )
except (tarfile.TarError, OSError, ValueError) as exc:
    print(f"ERROR: Invalid release archive: {exc}", file=sys.stderr)
    sys.exit(1)
PY

STAGE="$(mktemp -d)"
ENV_BACKUP=""
cleanup() {
  rm -rf "$STAGE"
  if [[ -n "$ENV_BACKUP" ]]; then
    rm -f "$ENV_BACKUP"
  fi
}
trap cleanup EXIT

tar -xzf "$BUNDLE" -C "$STAGE" --strip-components=1
cd "$STAGE"

[[ -s SHA256SUMS && -s images.tar &&
   -f docker-compose.yml && -f .env.example ]] || {
  echo "ERROR: Release is missing required files." >&2
  exit 1
}

echo "Verifying release checksums..."
sha256sum -c SHA256SUMS

# Preserve the destination's .env outside the release payload.
if [[ -e "$DEST/.env" ]]; then
  [[ -f "$DEST/.env" && ! -L "$DEST/.env" ]] || {
    echo "ERROR: Destination .env must be a regular, non-symlink file." >&2
    exit 1
  }
  ENV_BACKUP="$(mktemp)"
  cp -p "$DEST/.env" "$ENV_BACKUP"
fi

# A retry is allowed only when the destination belongs to this exact release.
if [[ -e "$DEST/SHA256SUMS" ]]; then
  [[ -f "$DEST/SHA256SUMS" ]] || {
    echo "ERROR: Destination manifest is not a regular file." >&2
    exit 1
  }
  cmp -s "$DEST/SHA256SUMS" "$STAGE/SHA256SUMS" || {
    echo "ERROR: Destination contains a different release." >&2
    echo "Choose a new destination; existing files were not overwritten." >&2
    exit 1
  }
  echo "Matching release detected; safe retry path selected."
elif find "$DEST" -mindepth 1 -maxdepth 1 \
    ! -name .env -print -quit | grep -q .; then
  echo "ERROR: Destination contains unverified files and no release manifest." >&2
  echo "Choose a new, empty destination." >&2
  exit 1
fi

# Install verified release files, but never copy a packaged .env over ours.
cp -a "$STAGE/." "$DEST/"
if [[ -n "$ENV_BACKUP" ]]; then
  cp -p "$ENV_BACKUP" "$DEST/.env"
fi

cd "$DEST"

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  echo "Created $DEST/.env from .env.example."
  echo "Set a strong POSTGRES_PASSWORD, then rerun this command." >&2
  exit 2
fi

if grep -q '^POSTGRES_PASSWORD=CHANGE_ME_TO_A_LONG_RANDOM_PASSWORD$' .env; then
  echo "ERROR: Replace the placeholder POSTGRES_PASSWORD in .env." >&2
  exit 1
fi

export IMAGE_TAG COMPOSE_PROJECT_NAME API_HOST_IP API_HOST_PORT

compose() {
  docker compose \
    --project-directory "$DEST" \
    --file "$DEST/docker-compose.yml" \
    --env-file "$DEST/.env" \
    --project-name "$COMPOSE_PROJECT_NAME" "$@"
}

# Ensure the non-root inference worker can read model artifacts.
chmod 755 "$DEST/models"
chmod 644 "$DEST/models/manifest.json"
chmod 644 "$DEST/models/eo_detector_fp16.engine"

echo "Validating Compose configuration..."
compose config --quiet

echo "Loading verified images..."
docker load -i "$DEST/images.tar"
docker image inspect "eoir-vision-api:$IMAGE_TAG" >/dev/null
docker image inspect "eoir-inference-worker:$IMAGE_TAG" >/dev/null

echo "Starting isolated Compose project: $COMPOSE_PROJECT_NAME"
compose up -d --no-build

echo "Waiting for inference_worker health..."
deadline=$((SECONDS + 60))
state="missing"

while (( SECONDS < deadline )); do
  container_id="$(compose ps -q inference_worker)"
  if [[ -n "$container_id" ]]; then
    state="$(docker inspect \
      -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
      "$container_id")"
    case "$state" in
      healthy) break ;;
      unhealthy)
        echo "ERROR: inference_worker is unhealthy." >&2
        compose ps
        compose logs --tail=100 inference_worker
        exit 1
        ;;
    esac
  fi
  sleep 2
done

if [[ "$state" != "healthy" ]]; then
  echo "ERROR: Worker did not become healthy within 60 seconds." >&2
  compose ps
  compose logs --tail=100 inference_worker
  exit 1
fi

BASE_URL="http://127.0.0.1:${API_HOST_PORT}"
curl --fail --silent --show-error "$BASE_URL/health"
echo
curl --fail --silent --show-error "$BASE_URL/api/v1/detect"
echo

echo "Air-gapped deployment verified."
echo "Compose project: $COMPOSE_PROJECT_NAME"
echo "API endpoint: $BASE_URL"
