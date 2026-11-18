#!/usr/bin/env python3
"""Focused tests for the HTTP/1.1 artwork cache helper."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SOURCE_ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = SOURCE_ROOT / "scripts" / "artwork_cache.py"
SPEC = importlib.util.spec_from_file_location("aria_artwork_cache", HELPER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load artwork cache helper")
helper = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = helper
SPEC.loader.exec_module(helper)

SAMPLE = "https://i.scdn.co/image/example"


class ArtworkCacheTest(unittest.TestCase):
    def test_cache_key_matches_the_qml_implementation(self):
        # Api.artworkCacheKey uses the same FNV-1a algorithm.
        self.assertEqual(helper.cache_key(SAMPLE), "837f4ac4")
        self.assertEqual(
            helper.cache_key(
                "https://i.scdn.co/image/ab67616d0000b273abcdef0123456789abcdef01"
            ),
            "c059531b",
        )

    def test_only_spotify_image_hosts_are_downloaded(self):
        self.assertTrue(helper.cacheable(SAMPLE))
        self.assertTrue(helper.cacheable("https://i.scdn.co/image/a"))
        self.assertFalse(helper.cacheable("http://i.scdn.co/image/a"))
        self.assertFalse(helper.cacheable("https://example.com/image/a"))
        self.assertFalse(helper.cacheable("https://i.scdn.co.evil.test/a"))

    def test_failed_download_leaves_no_cache_file(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(helper, "urlopen", side_effect=OSError("offline")):
                self.assertIsNone(helper.download(SAMPLE, directory, "837f4ac4"))
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_rejects_non_image_responses(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.headers.get_content_type.return_value = "text/html"
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(helper, "urlopen", return_value=response):
                self.assertIsNone(helper.download(SAMPLE, directory, "837f4ac4"))

    def test_cached_files_are_announced_at_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "837f4ac4.jpg"
            path.write_bytes(b"fake jpeg")
            result = subprocess.run(
                [sys.executable, str(HELPER_PATH), directory],
                input="",
                text=True,
                capture_output=True,
                timeout=10,
                check=True,
            )
            self.assertIn(f"HIT 837f4ac4 {path}", result.stdout)


if __name__ == "__main__":
    unittest.main()
