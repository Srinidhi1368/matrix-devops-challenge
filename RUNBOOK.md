# EO/IR Stack v1.4.8 — Field Runbook

## Release gate and known fixture limitation
Run `cp .env.example .env`, set a strong `POSTGRES_PASSWORD`, then `docker compose up -d --build`.
Verify with `curl -fsS http://localhost:8000/health` and `curl -fsS http://localhost:8000/api/v1/detect`. The bundled 4 KB engine file is a **simulated test fixture**, not a production TensorRT plan; do not promote it to a real surveillance system. A production release must supply a validated, target-compatible engine and its signed/verified manifest.

## Defects found and fixes
Line references below refer to the original challenge files as received; fix locations refer to this corrected repository.

| Original file / lines | Root cause | Fix in corrected repository |
|---|---|---|
| `docker-compose.yml` L3-L8 | Database password hardcoded in source; port 5432 unnecessarily published to host. | `.env.example` contract, required interpolation, no host DB port, persistent DB volume. |
| `docker-compose.yml` L11-L22 | AWS secret hardcoded; healthcheck is `echo worker_alive || exit 0` and always passes; no worker health endpoint check. | Removed unused AWS secret; real `/status` healthcheck every 3s with 2 retries. |
| `docker-compose.yml` L24-L38 | API uses `localhost:9001`; API and worker are on disjoint networks; startup order does not wait for readiness. | `http://inference_worker:9000`, shared `sensor_backplane`, `depends_on: condition: service_healthy`. |
| `Dockerfile` L1-L13 | Full Python base, unnecessary build tools/utilities, root runtime, broad copy of repository. | `python:3.11-slim`, standard-library-only runtime, selective copy, dedicated non-root `app` user; `.dockerignore`. |
| `vision_api/app.py` L7-L18 and L35-L45 | Wrong default worker address; startup-only session flag can remain false after worker recovers; health response has wrong schema. | Runtime readiness is checked per request; `/health` returns `status` and `worker_ready`; detect fails closed. |
| `inference_worker/worker.py` L12-L34 | Verification exceptions (e.g. malformed JSON/missing file) can crash handling; cache write location is under model directory; integrity result is not reflected by Docker's old healthcheck. | Fail-closed verification, `/tmp/trt_cache`, HTTP 503 for invalid artifact, healthcheck polls `/status`. |
| `models/manifest.json` L8 | Declared SHA-256 did not match the supplied engine file. | Manifest checksum updated to the SHA-256 of the supplied fixture; tests verify it. |
| `.github/workflows/ci.yml` L16-L18 | `|| true` masks test failures. | Tests are a required job; Compose config and shell syntax are validated. |
| `.github/workflows/ci.yml` L20-L27 | Build/promotion uses mutable `:latest`, with no test dependency or artifact gate. | Build/test depends on validation; publishing is gated and uses the full commit SHA tag, never `latest`. |
| Repository omissions | No `.dockerignore`, `.env.example`, air-gap scripts, or runbook. | All required release artifacts are included. |

## Air-gapped packaging and deployment
1. On the connected build machine, install Docker Compose, copy `.env.example` to `.env`, and set a strong password. Never distribute `.env`.
2. Run `./package_airgap.sh`. It builds version-tagged images, exports them to `images.tar`, includes source/config/models, generates `SHA256SUMS`, and creates `release_v1.4.8.tar.gz`.
3. Transfer the bundle to the field host using approved media. Optionally verify the outer archive with the SHA-256 printed by the packaging script using a separately communicated digest.
4. Run `./deploy_airgap.sh release_v1.4.8.tar.gz ./field_release`. On first run it extracts and verifies the payload checksums, creates `.env` from the template, and exits for password configuration. Set the password in `./field_release/.env`, then rerun the command.
5. Deployment verifies `SHA256SUMS` **before** `docker load`, loads the prebuilt images, starts Compose with `--no-build`, then verifies worker health and API endpoints. No registry or internet access is required. `SHA256SUMS` covers every payload file except itself (a checksum manifest cannot meaningfully include its own digest).

## 15-minute field rollback: bad engine promotion
**0–2 min:** Stop further promotion. Capture `docker compose ps`, `docker compose logs --tail=200 inference_worker vision_api`, and current manifest/hash for the incident record. Do not overwrite the last-known-good release directory.
**2–5 min:** Select the approved previous release bundle and verify its SHA-256 against the separately communicated release digest. Extract it into a separate versioned directory and run `sha256sum -c SHA256SUMS`.
**5–8 min:** Restore the last-known-good `eo_detector_fp16.engine` **and its matching `manifest.json` together** from that verified release. Do not mix a model and manifest from different releases. Use a staged copy then atomic rename on the same filesystem where practical.
**8–11 min:** Recreate the worker with the rollback release (`docker compose up -d --no-build --force-recreate inference_worker`); wait for `healthy`. If the old engine is in a different bundle, use that bundle's release directory and its matching Compose project/configuration.
**11–13 min:** Check `curl -fsS http://localhost:8000/health` and `curl -fsS http://localhost:8000/api/v1/detect`; confirm worker logs show a valid checksum.
**13–15 min:** If checks fail, stop promotion, retain logs and both release bundles, restore the last known-good complete deployment (images, engine, manifest, configuration) as a unit, and escalate to the release owner. Do not delete the prior working bundle until sign-off.

## CUDA / TensorRT and CPU architecture drift
TensorRT engine plans are not generally portable across GPU architectures, TensorRT/CUDA versions, plugins, or operating-system/runtime combinations. Do not assume an x86_64 lab engine will run on an aarch64 Jetson Orin. Build and validate separate engine artifacts on representative target hardware (or with a vendor-supported compatible workflow), pin and record the JetPack, CUDA, TensorRT, driver, plugin and model versions, and publish separate manifests per target (`linux/amd64` vs `linux/arm64`, GPU architecture and runtime matrix). Verify artifact hash and compatibility metadata before promotion. Container multi-architecture support alone does **not** make a TensorRT plan portable.

## Demonstration / troubleshooting
- `docker images` — show version/commit-tagged images.
- `docker compose ps` and `docker compose logs -f inference_worker` — inspect service/health state.
- `curl -i http://localhost:8000/health` and `curl -i http://localhost:8000/api/v1/detect`.
- Corruption test (local test environment only): back up `models/eo_detector_fp16.engine`, append bytes to it, and observe `docker compose ps` transition to `unhealthy` within 15 seconds and API 503; restore the original file and confirm health returns. Never corrupt a production artifact.
- If a service is unhealthy, inspect logs, verify manifest SHA-256 against `sha256sum models/eo_detector_fp16.engine`, check the worker can write to `/tmp/trt_cache`, and verify `.env` values.
