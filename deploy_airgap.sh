#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BUNDLE="${1:-release_v1.4.2.tar.gz}"
DEST="${2:-./field_release}"
IMAGE_TAG="${IMAGE_TAG:-1.4.2}"

for cmd in docker sha256sum tar python3 curl; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: Required command not found: $cmd" >&2
    exit 1
  }
done

[[ -f "$BUNDLE" ]] || {
  echo "ERROR: Release bundle not found: $BUNDLE" >&2
  exit 1
}

# Resolve paths before creating temporary staging directories.
BUNDLE="$(realpath "$BUNDLE")"
mkdir -p "$DEST"
DEST="$(realpath "$DEST")"

# Do not extract untrusted archive paths.
python3 - "$BUNDLE" <<'PY'
import sys
import tarfile
from pathlib import PurePosixPath

archive = sys.argv[1]

try:
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()

        if not members:
            raise ValueError("Archive is empty")

        for member in members:
            path = PurePosixPath(member.name)

            if path.is_absolute() or ".." in path.parts:
                raise ValueError(
                    f"Unsafe archive path: {member.name}"
                )

            if not (member.isfile() or member.isdir()):
                raise ValueError(
                    f"Unsupported archive entry type: {member.name}"
                )

except (tarfile.TarError, OSError, ValueError) as exc:
    print(f"ERROR: Invalid release archive: {exc}", file=sys.stderr)
    sys.exit(1)
PY

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Extract only into a temporary staging directory.
tar -xzf "$BUNDLE" -C "$STAGE" --strip-components=1

cd "$STAGE"

[[ -s SHA256SUMS ]] || {
  echo "ERROR: SHA256SUMS is missing or empty." >&2
  exit 1
}

# Verify every packaged file before loading images.
sha256sum -c SHA256SUMS

[[ -s images.tar ]] || {
  echo "ERROR: images.tar is missing or empty." >&2
  exit 1
}

[[ -f docker-compose.yml && -f .env.example ]] || {
  echo "ERROR: Required deployment files are missing." >&2
  exit 1
}

# Preserve an existing deployment configuration.
# Never overwrite an existing .env file.
if [[ -e "$DEST/.env" ]]; then
  cp "$DEST/.env" "$STAGE/.env"
fi

# Refuse unexpected files in an existing deployment directory.
if [[ -d "$DEST" ]]; then
  while IFS= read -r -d '' file; do
    name="${file#"$DEST"/}"
    if [[ "$name" != ".env" ]]; then
      echo "ERROR: Destination contains existing files: $DEST" >&2
      echo "Use a new empty destination." >&2
      exit 1
    fi
  done < <(find "$DEST" -mindepth 1 -maxdepth 1 -print0)
fi

cp -a "$STAGE/." "$DEST/"
cd "$DEST"

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  echo "Created $DEST/.env from .env.example."
  echo "Set a strong POSTGRES_PASSWORD, then rerun deployment." >&2
  exit 2
fi

if grep -q '^POSTGRES_PASSWORD=CHANGE_ME_TO_A_LONG_RANDOM_PASSWORD$' .env; then
  echo "ERROR: Replace the placeholder POSTGRES_PASSWORD in .env." >&2
  exit 1
fi

# Validate Compose configuration before loading images.
export IMAGE_TAG
docker compose config --quiet

# Load only after archive and payload checks pass.
docker load -i images.tar

docker image inspect "eoir-vision-api:$IMAGE_TAG" >/dev/null
docker image inspect "eoir-inference-worker:$IMAGE_TAG" >/dev/null

docker compose up -d --no-build

echo "Waiting for inference_worker health..."
deadline=$((SECONDS + 30))

while (( SECONDS < deadline )); do
  container_id="$(docker compose ps -q inference_worker)"

  if [[ -n "$container_id" ]]; then
    state="$(docker inspect \
      -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
      "$container_id")"

    case "$state" in
      healthy)
        break
        ;;
      unhealthy)
        echo "ERROR: inference_worker is unhealthy." >&2
        docker compose ps
        docker compose logs --tail=100 inference_worker
        exit 1
        ;;
    esac
  fi

  sleep 2
done

[[ "${state:-}" == "healthy" ]] || {
  echo "ERROR: Worker did not become healthy within 30 seconds." >&2
  docker compose ps
  exit 1
}

curl --fail --silent --show-error http://localhost:8000/health
echo
curl --fail --silent --show-error http://localhost:8000/api/v1/detect
echo

echo "Air-gapped deployment verified."
