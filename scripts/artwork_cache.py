#!/usr/bin/env python3
"""Local artwork cache for Aria.

Qt's Image loads remote covers over HTTP/2, which Spotify's image CDN
regularly drops ("HTTP/2 protocol error"), leaving RetryImage to back off for
up to a minute before a cover appears. This helper fetches the same images
with HTTP/1.1 in the background and keeps them on disk across shell restarts.

Protocol (one line per record):
  stdin:  <https image url>
  stdout: HIT   <key> <path>   - already cached (also emitted at startup)
          READY <key> <path>   - freshly cached
          FAIL  <key>          - download failed; QML keeps the remote fallback
"""

import os
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse
from urllib.request import Request, urlopen

WORKERS = 4
MAX_FILES = 320
MAX_BYTES = 5 * 1024 * 1024
print_lock = threading.Lock()


def cache_key(url):
    # FNV-1a 32-bit. Kept in sync with Api.artworkCacheKey in QML so the
    # bindings can look up a file before this process answers.
    value = 0x811C9DC5
    for byte in url.encode("utf-8"):
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return f"{value:08x}"


def cacheable(url):
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "https" and (
        host == "scdn.co" or host.endswith(".scdn.co")
    )


def emit(*parts):
    with print_lock:
        sys.stdout.write(" ".join(parts) + "\n")
        sys.stdout.flush()


def prune(directory):
    try:
        images = [
            os.path.join(directory, name)
            for name in os.listdir(directory)
            if name.endswith(".jpg")
        ]
        images.sort(key=lambda path: os.path.getmtime(path), reverse=True)
        for path in images[MAX_FILES:]:
            os.unlink(path)
    except OSError:
        pass


def download(url, directory, key):
    path = os.path.join(directory, key + ".jpg")
    temporary = path + ".part"
    try:
        request = Request(url, headers={
            "Accept": "image/avif,image/webp,image/*,*/*;q=0.8",
            "User-Agent": "Mozilla/5.0 (Aria artwork cache)",
        })
        with urlopen(request, timeout=12) as response:
            content_type = response.headers.get_content_type()
            if not content_type.startswith("image/"):
                raise ValueError(content_type)
            payload = response.read(MAX_BYTES + 1)
        if not payload or len(payload) > MAX_BYTES:
            raise ValueError("empty or oversized artwork")
        with open(temporary, "wb") as handle:
            handle.write(payload)
        os.replace(temporary, path)
        return path
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        return None


def main():
    if len(sys.argv) < 2:
        return 1
    directory = sys.argv[1]
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        return 1

    # Announce files left by earlier sessions so Qt never re-fetches them.
    # A shell killed mid-download can leave partial files behind.
    try:
        for name in os.listdir(directory):
            if name.endswith(".part"):
                os.unlink(os.path.join(directory, name))
    except OSError:
        pass
    try:
        for name in os.listdir(directory):
            if name.endswith(".jpg") and len(name) == 12:
                emit("HIT", name[:-4], os.path.join(directory, name))
    except OSError:
        pass
    prune(directory)

    seen = set()

    def finish(future, key):
        try:
            path = future.result()
        except Exception:
            path = None
        if path:
            emit("READY", key, path)
        else:
            emit("FAIL", key)

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for line in sys.stdin:
            url = line.strip()
            if not cacheable(url):
                continue
            key = cache_key(url)
            if key in seen or os.path.exists(os.path.join(directory, key + ".jpg")):
                continue
            seen.add(key)
            pool.submit(download, url, directory, key).add_done_callback(
                lambda future, key=key: finish(future, key)
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
