import hashlib
import json
import os
import unittest

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class TestModelManifest(unittest.TestCase):
    def test_engine_checksum_matches_manifest(self):
        manifest_path = os.path.join(BASE, "models", "manifest.json")
        engine_path = os.path.join(BASE, "models", "eo_detector_fp16.engine")
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
        with open(engine_path, "rb") as f:
            actual_sha = hashlib.sha256(f.read()).hexdigest()
        self.assertEqual(manifest.get("sha256"), actual_sha)

    def test_manifest_declares_test_fixture_not_production_engine(self):
        with open(os.path.join(BASE, "models", "manifest.json"), encoding="utf-8") as f:
            manifest = json.load(f)
        self.assertEqual(manifest.get("artifact_type"), "simulated_test_fixture")


if __name__ == "__main__":
    unittest.main()
