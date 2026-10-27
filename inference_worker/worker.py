from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import hmac
import json
import os
import time

ENGINE_PATH = os.environ.get("ENGINE_PATH", "/app/models/eo_detector_fp16.engine")
MANIFEST_PATH = os.environ.get("MANIFEST_PATH", "/app/models/manifest.json")
CACHE_DIR = os.environ.get("TRT_CACHE_DIR", "/tmp/trt_cache")
PORT = int(os.environ.get("WORKER_PORT", "9000"))
WARMUP_SECONDS = max(0.0, float(os.environ.get("ENGINE_WARMUP_SEC", "0.2")))


def verify_engine():
    """Verify the model artifact on every status request; fail closed."""
    try:
        with open(MANIFEST_PATH, "r", encoding="utf-8") as mf:
            manifest = json.load(mf)
        expected = manifest.get("sha256", "")
        if not isinstance(expected, str) or len(expected) != 64:
            return False, "invalid_manifest_sha256", ""
        digest = hashlib.sha256()
        with open(ENGINE_PATH, "rb") as ef:
            for chunk in iter(lambda: ef.read(1024 * 1024), b""):
                digest.update(chunk)
        actual = digest.hexdigest()
        if not hmac.compare_digest(actual, expected.lower()):
            return False, expected, actual
        os.makedirs(CACHE_DIR, exist_ok=True)
        lock_file = os.path.join(CACHE_DIR, "fp16_execution_context.lock")
        with open(lock_file, "w", encoding="utf-8") as lf:
            lf.write(actual)
        return True, expected, actual
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        return False, f"verification_error:{type(exc).__name__}", ""


class WorkerHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/status":
            self.send_response(404)
            self.end_headers()
            return
        valid, expected, actual = verify_engine()
        code = 200 if valid else 503
        body = json.dumps({
            "service": "inference_worker",
            "engine_loaded": os.path.isfile(ENGINE_PATH),
            "checksum_valid": valid,
            "expected_sha256": expected,
            "actual_sha256": actual,
        }).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"[inference_worker] {fmt % args}", flush=True)


if __name__ == "__main__":
    time.sleep(WARMUP_SECONDS)
    ok, expected, actual = verify_engine()
    print(f"[inference_worker] initial engine verification valid={ok}; expected={str(expected)[:12]}; actual={actual[:12]}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), WorkerHandler).serve_forever()
