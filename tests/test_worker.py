import hashlib
import json
import os
import tempfile
import unittest
from unittest.mock import patch

from inference_worker import worker


class TestEngineVerification(unittest.TestCase):
    def test_valid_engine_and_manifest(self):
        with tempfile.TemporaryDirectory() as td:
            engine = os.path.join(td, "engine.bin")
            manifest = os.path.join(td, "manifest.json")
            cache = os.path.join(td, "cache")
            payload = b"known test engine"
            with open(engine, "wb") as f:
                f.write(payload)
            with open(manifest, "w", encoding="utf-8") as f:
                json.dump({"sha256": hashlib.sha256(payload).hexdigest()}, f)
            with patch.multiple(worker, ENGINE_PATH=engine, MANIFEST_PATH=manifest, CACHE_DIR=cache):
                valid, _, actual = worker.verify_engine()
            self.assertTrue(valid)
            self.assertEqual(actual, hashlib.sha256(payload).hexdigest())
            self.assertTrue(os.path.isfile(os.path.join(cache, "fp16_execution_context.lock")))

    def test_corrupted_engine_fails_verification(self):
        with tempfile.TemporaryDirectory() as td:
            engine = os.path.join(td, "engine.bin")
            manifest = os.path.join(td, "manifest.json")
            with open(engine, "wb") as f:
                f.write(b"original")
            with open(manifest, "w", encoding="utf-8") as f:
                json.dump({"sha256": hashlib.sha256(b"original").hexdigest()}, f)
            with open(engine, "wb") as f:
                f.write(b"corrupted")
            with patch.multiple(worker, ENGINE_PATH=engine, MANIFEST_PATH=manifest, CACHE_DIR=os.path.join(td, "cache")):
                valid, _, _ = worker.verify_engine()
            self.assertFalse(valid)

    def test_missing_engine_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            with patch.multiple(worker, ENGINE_PATH=os.path.join(td, "missing"), MANIFEST_PATH=os.path.join(td, "manifest"), CACHE_DIR=os.path.join(td, "cache")):
                valid, _, _ = worker.verify_engine()
            self.assertFalse(valid)


if __name__ == "__main__":
    unittest.main()
