# DevOps Engineer Challenge — EO/IR Stack Packaging, Hardening & Air-Gapped Release

Release: **1.4.2**. This repository demonstrates container hardening, runtime model integrity checks, service readiness, CI release gates, and offline packaging.

> **Important artifact limitation:** the supplied `models/eo_detector_fp16.engine` is a small simulated test fixture, not a usable production TensorRT plan. It is intentionally labeled in `models/manifest.json`. The fixture is suitable for this laptop-based challenge's checksum and failure demonstrations only. A real field deployment must replace it with a validated target-compatible model plan and regenerate/verify the manifest.

## Prerequisites
- Docker Engine and Docker Compose v2.
- `curl`, `sha256sum`, Bash, and GNU tar for release packaging/deployment.
- No GPU is needed for this simulated challenge.

## Local start
```bash
cp .env.example .env
# Edit .env and replace POSTGRES_PASSWORD with a strong unique password.
docker compose up -d --build
docker compose ps
curl -i http://localhost:8000/health
curl -i http://localhost:8000/api/v1/detect
```

Healthy `/health` response:
```json
{"status":"healthy","worker_ready":true}
```
The detection endpoint returns a deterministic sample response only when the worker reports a valid engine checksum. This challenge does not perform real image inference.

## Verify failure detection
In a disposable local test environment only:
```bash
cp models/eo_detector_fp16.engine /tmp/eo_detector_fp16.engine.backup
printf 'corrupt' >> models/eo_detector_fp16.engine
# Within 15 seconds, worker health becomes unhealthy and API requests return 503:
watch -n 1 'docker compose ps'
curl -i http://localhost:8000/health
# Restore the exact artifact:
cp /tmp/eo_detector_fp16.engine.backup models/eo_detector_fp16.engine
# Wait for health to recover.
```
The model directory is mounted read-only inside containers. Change the host-side file only in a disposable test checkout. The worker writes its verification cache under `/tmp/trt_cache`.

## Tests and CI
```bash
python -m unittest discover -s tests -v
bash -n package_airgap.sh deploy_airgap.sh
cp .env.example .env
# Set a local non-production password in .env, then:
docker compose config --quiet
```
CI fails on unit-test, artifact checksum, shell syntax, Compose validation, image build, image-size, smoke-test, or corruption-detection failures. Publishing is gated on successful tests and uses the full commit SHA as an immutable-by-convention image tag; `latest` is not used.

## Air-gapped release
On the connected build host:
```bash
cp .env.example .env
# Set a strong password in .env. Do not distribute this file.
./package_airgap.sh
```
Transfer `release_v1.4.2.tar.gz` to the disconnected field host using approved media. Communicate the outer archive's SHA-256 through a separate trusted channel. On the field host:
```bash
./deploy_airgap.sh release_v1.4.2.tar.gz ./field_release
# First run extracts and verifies files, creates .env.example copy, then exits.
# Edit ./field_release/.env to set a strong password, then rerun:
./deploy_airgap.sh release_v1.4.2.tar.gz ./field_release
```
Deployment validates `SHA256SUMS` before loading images or starting containers and uses `docker compose up --no-build`. The checksum manifest covers every payload file except itself. Never include the actual `.env` file or production secrets in the bundle.

See [`RUNBOOK.md`](RUNBOOK.md) for defect/root-cause mapping, rollback, compatibility controls, and demo steps.
