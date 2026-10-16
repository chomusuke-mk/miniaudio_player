#!/usr/bin/env python3
"""
Test HTTP Server for miniaudio_player adversarial and URI playback testing.

Features:
- ThreadingHTTPServer with per-connection thread isolation.
- Byte-Range requests (HTTP 206 Partial Content) for arbitrary seeking.
- Bandwidth throttling (slow network simulation).
- Sudden connection drop / socket reset.
- Error codes (HTTP 404, 403, 500).
- HTTP Redirections (302, 307).
- Continuous live chunked audio streaming (Transfer-Encoding: chunked).
- Malformed/corrupt headers simulation.
- Dynamic port allocation.
"""

import argparse
import json
import os
import random
import re
import socket
import sys
import threading
import time
from http import HTTPStatus
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

MIME_TYPES = {
    '.mp3': 'audio/mpeg',
    '.wav': 'audio/wav',
    '.flac': 'audio/flac',
    '.ogg': 'audio/ogg',
    '.oga': 'audio/ogg',
    '.opus': 'audio/opus',
    '.aac': 'audio/aac',
    '.aif': 'audio/aiff',
    '.aiff': 'audio/aiff',
    '.aifc': 'audio/aiff',
    '.m4a': 'audio/mp4',
    '.webm': 'audio/webm',
}

class AdversarialAudioHTTPHandler(BaseHTTPRequestHandler):
    server_version = "AdversarialAudioServer/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        try:
            with open('/tmp/server_log.txt', 'a') as f:
                f.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))
        except Exception:
            pass

    def send_error(self, code, message=None, explain=None):
        try:
            with open('/tmp/server_log.txt', 'a') as f:
                f.write(f"send_error: {code} message={message} explain={explain}\n")
        except Exception:
            pass
        super().send_error(code, message, explain)

    def _resolve_music_path(self, filename):
        base_dir = self.server.music_dir
        clean_name = os.path.basename(filename)
        path = os.path.join(base_dir, clean_name)
        if os.path.isfile(path):
            return path
        return None

    def _get_mime(self, path):
        _, ext = os.path.splitext(path.lower())
        return MIME_TYPES.get(ext, 'application/octet-stream')

    def _record_request(self, path, is_range):
        if not hasattr(self.server, "stats_lock"):
            return
        with self.server.stats_lock:
            self.server.total_requests += 1
            self.server.requests_by_path[path] = self.server.requests_by_path.get(path, 0) + 1
            if is_range:
                self.server.range_requests_by_path[path] = self.server.range_requests_by_path.get(path, 0) + 1

    def _check_burst_limit(self, key, limit=15, window_sec=0.5):
        if not hasattr(self.server, "stats_lock"):
            return True
        now = time.time()
        with self.server.stats_lock:
            times = self.server.recent_request_times.setdefault(key, [])
            times[:] = [t for t in times if now - t <= window_sec]
            if len(times) >= limit:
                self.server.rate_limited_count += 1
                return False
            times.append(now)
            return True

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        self.close_connection = True
        try:
            with open('/tmp/server_log.txt', 'a') as f:
                f.write(f"do_GET: {self.path} headers={dict(self.headers)}\n")
        except Exception:
            pass

        # 1. Shutdown endpoint
        if path == "/shutdown":
            self.send_response(HTTPStatus.OK)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"Shutting down\n")
            threading.Thread(target=self.server.shutdown).start()
            return

        # 1b. Endpoints discovery catalog
        if path == "/endpoints":
            catalog = {}
            for fname in sorted(os.listdir(self.server.music_dir)):
                fpath = os.path.join(self.server.music_dir, fname)
                if not os.path.isfile(fpath):
                    continue
                _, ext = os.path.splitext(fname.lower())
                if ext in MIME_TYPES:
                    fmt = ext.lstrip(".")
                    info = {
                        "filename": fname,
                        "format": fmt,
                        "remote_normal": f"/music/{fname}",
                        "remote_flaky": f"/flaky/music/{fname}",
                        "remote_corrupt": f"/corrupt/music/{fname}",
                        "live_normal": f"/live/{fname}",
                        "live_flaky": f"/flaky/live/{fname}",
                        "live_corrupt": f"/corrupt/live/{fname}",
                    }
                    if fmt == "m4a":
                        if "alac" in fname.lower():
                            catalog["alac"] = info
                        else:
                            catalog["m4a"] = info
                            catalog["m4a_aac"] = info
                    elif fmt in catalog:
                        if fname.startswith("salida"):
                            catalog[fmt] = info
                    else:
                        catalog[fmt] = info

            payload = json.dumps(catalog, indent=2).encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return

        # 1c. Stats query endpoint
        if path == "/stats":
            with self.server.stats_lock:
                stats = {
                    "total_requests": self.server.total_requests,
                    "requests_by_path": dict(self.server.requests_by_path),
                    "range_requests_by_path": dict(self.server.range_requests_by_path),
                    "rate_limited_count": self.server.rate_limited_count,
                }
            payload = json.dumps(stats, indent=2).encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return

        # 1d. Reset stats endpoint
        if path == "/reset_stats":
            with self.server.stats_lock:
                self.server.total_requests = 0
                self.server.requests_by_path.clear()
                self.server.range_requests_by_path.clear()
                self.server.rate_limited_count = 0
                self.server.recent_request_times.clear()
            body = b'{"status":"ok"}\n'
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return

        # 2. Corrupt headers endpoint
        if path == "/corrupt/headers":
            try:
                self.request.sendall(b"INVALID_PROTOCOL_GARBAGE_NO_HTTP_HEADERS\r\n\r\n")
            except Exception:
                pass
            return

        # 3. HTTP Error endpoints
        if path.startswith("/error/"):
            code_str = path[len("/error/"):]
            try:
                code = int(code_str)
                self.send_response(code)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Connection", "close")
                body = f"Simulated error {code}".encode("utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except ValueError:
                self.send_response(HTTPStatus.BAD_REQUEST)
                self.send_header("Connection", "close")
                self.end_headers()
            return

        # 4. HTTP Redirection endpoints
        if path.startswith("/redirect/"):
            target = query.get("target", ["/music/salida.mp3"])[0]
            status_code = HTTPStatus.FOUND # 302
            if "307" in path:
                status_code = HTTPStatus.TEMPORARY_REDIRECT
            elif "301" in path:
                status_code = HTTPStatus.MOVED_PERMANENTLY

            self.send_response(status_code)
            self.send_header("Location", target)
            self.send_header("Connection", "close")
            self.end_headers()
            return

        # 5. Dropped connection endpoint (/drop/<filename>?after=16384)
        if path.startswith("/drop/"):
            filename = path[len("/drop/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            after_bytes = int(query.get("after", [16384])[0])
            mime = self._get_mime(filepath)
            file_size = os.path.getsize(filepath)

            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Connection", "close")
            self.end_headers()

            try:
                with open(filepath, "rb") as f:
                    remaining = after_bytes
                    while remaining > 0:
                        chunk_size = min(4096, remaining)
                        data = f.read(chunk_size)
                        if not data:
                            break
                        self.wfile.write(data)
                        remaining -= len(data)
                    self.wfile.flush()
                self.request.shutdown(socket.SHUT_RDWR)
                self.request.close()
            except Exception:
                pass
            return

        # 6. Throttled slow endpoint (/slow/<filename>?delay=0.01&chunk=2048)
        if path.startswith("/slow/"):
            filename = path[len("/slow/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            delay = float(query.get("delay", [0.01])[0])
            chunk_size = int(query.get("chunk", [2048])[0])
            mime = self._get_mime(filepath)
            file_size = os.path.getsize(filepath)

            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Connection", "close")
            self.end_headers()

            try:
                with open(filepath, "rb") as f:
                    while True:
                        data = f.read(chunk_size)
                        if not data:
                            break
                        self.wfile.write(data)
                        self.wfile.flush()
                        time.sleep(delay)
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        # 7a. Flaky Live Stream endpoint (/flaky/live/<filename>)
        if path.startswith("/flaky/live/"):
            filename = path[len("/flaky/live/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            self._record_request(path, False)
            mime = self._get_mime(filepath)
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Cache-Control", "no-cache, no-store")
            self.send_header("Connection", "close")
            self.end_headers()

            chunk_size = 4096
            chunk_num = 0
            try:
                while True:
                    with open(filepath, "rb") as f:
                        while True:
                            data = f.read(chunk_size)
                            if not data:
                                break
                            chunk_num += 1
                            # Introduce jitter or intermittent delay
                            delay = 0.15 if (chunk_num % 6 == 0) else 0.03
                            chunk_header = f"{len(data):X}\r\n".encode("ascii")
                            self.wfile.write(chunk_header + data + b"\r\n")
                            self.wfile.flush()
                            time.sleep(delay)
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        # 7b. Corrupt Live Stream endpoint (/corrupt/live/<filename>)
        if path.startswith("/corrupt/live/"):
            filename = path[len("/corrupt/live/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            self._record_request(path, False)
            mime = self._get_mime(filepath)
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Cache-Control", "no-cache, no-store")
            self.send_header("Connection", "close")
            self.end_headers()

            garbage_chunk = b"\xFF\x00\xDE\xAD\xBE\xEF\x00\xFF" * 512
            try:
                while True:
                    chunk_header = f"{len(garbage_chunk):X}\r\n".encode("ascii")
                    self.wfile.write(chunk_header + garbage_chunk + b"\r\n")
                    self.wfile.flush()
                    time.sleep(0.04)
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        # 7. Live Chunked Stream endpoint (/live/<filename>)
        if path.startswith("/live/"):
            filename = path[len("/live/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            self._record_request(path, False)
            mime = self._get_mime(filepath)
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Cache-Control", "no-cache, no-store")
            self.send_header("Connection", "close")
            self.end_headers()

            chunk_size = 4096
            delay = 0.03
            try:
                while True:
                    with open(filepath, "rb") as f:
                        while True:
                            data = f.read(chunk_size)
                            if not data:
                                break
                            chunk_header = f"{len(data):X}\r\n".encode("ascii")
                            self.wfile.write(chunk_header + data + b"\r\n")
                            self.wfile.flush()
                            time.sleep(delay)
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        # 9. Periodic Network Stalls (/stall/<filename>?chunk_size=16384&stall_ms=500&initial_burst=65536)
        if path.startswith("/stall/"):
            filename = path[len("/stall/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            chunk_size = int(query.get("chunk_size", [16384])[0])
            stall_ms = int(query.get("stall_ms", [500])[0])
            initial_burst = int(query.get("initial_burst", [65536])[0])
            mime = self._get_mime(filepath)
            file_size = os.path.getsize(filepath)
            range_header = self.headers.get("Range")

            start = 0
            end = file_size - 1
            status_code = HTTPStatus.OK

            if range_header:
                m = re.match(r"^bytes=(\d*)-(\d*)$", range_header.strip())
                if m:
                    s_str, e_str = m.groups()
                    start = int(s_str) if s_str else 0
                    end = int(e_str) if e_str else file_size - 1
                    status_code = HTTPStatus.PARTIAL_CONTENT

            content_length = end - start + 1
            self.send_response(status_code)
            self.send_header("Content-Type", mime)
            if status_code == HTTPStatus.PARTIAL_CONTENT:
                self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
            self.send_header("Content-Length", str(content_length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Connection", "close")
            self.end_headers()

            try:
                with open(filepath, "rb") as f:
                    f.seek(start)
                    remaining = content_length
                    burst_remaining = initial_burst

                    while remaining > 0:
                        to_read = min(chunk_size, remaining)
                        data = f.read(to_read)
                        if not data:
                            break
                        self.wfile.write(data)
                        self.wfile.flush()
                        remaining -= len(data)

                        if burst_remaining > 0:
                            burst_remaining -= len(data)
                        else:
                            time.sleep(stall_ms / 1000.0)
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        # 10. Rate Limiting (/ratelimit/<filename>?kbps=32&initial_burst=65536)
        if path.startswith("/ratelimit/"):
            filename = path[len("/ratelimit/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            kbps = float(query.get("kbps", [32.0])[0])
            initial_burst = int(query.get("initial_burst", [65536])[0])
            mime = self._get_mime(filepath)
            file_size = os.path.getsize(filepath)
            range_header = self.headers.get("Range")

            start = 0
            end = file_size - 1
            status_code = HTTPStatus.OK

            if range_header:
                m = re.match(r"^bytes=(\d*)-(\d*)$", range_header.strip())
                if m:
                    s_str, e_str = m.groups()
                    start = int(s_str) if s_str else 0
                    end = int(e_str) if e_str else file_size - 1
                    status_code = HTTPStatus.PARTIAL_CONTENT

            content_length = end - start + 1
            self.send_response(status_code)
            self.send_header("Content-Type", mime)
            if status_code == HTTPStatus.PARTIAL_CONTENT:
                self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
            self.send_header("Content-Length", str(content_length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Connection", "close")
            self.end_headers()

            bytes_per_sec = max(1024.0, (kbps * 1024.0) / 8.0)
            chunk_size = max(512, int(bytes_per_sec / 10.0)) # 10 chunks per sec
            sleep_interval = chunk_size / bytes_per_sec

            try:
                with open(filepath, "rb") as f:
                    f.seek(start)
                    remaining = content_length
                    burst_remaining = initial_burst

                    while remaining > 0:
                        to_read = min(chunk_size, remaining)
                        data = f.read(to_read)
                        if not data:
                            break
                        self.wfile.write(data)
                        self.wfile.flush()
                        remaining -= len(data)

                        if burst_remaining > 0:
                            burst_remaining -= len(data)
                        else:
                            time.sleep(sleep_interval)
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        # 11. Dropped socket with Range-resumption (/drop_resume/<filename>?drop_at=65536)
        if path.startswith("/drop_resume/"):
            filename = path[len("/drop_resume/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            drop_at = int(query.get("drop_at", [65536])[0])
            mime = self._get_mime(filepath)
            file_size = os.path.getsize(filepath)
            range_header = self.headers.get("Range")

            # Check if this is a Range request attempting to resume post-drop
            if range_header:
                m = re.match(r"^bytes=(\d*)-(\d*)$", range_header.strip())
                if m:
                    start_str, end_str = m.groups()
                    start = int(start_str) if start_str else 0
                    end = int(end_str) if end_str else file_size - 1

                    # If resuming at or past the drop offset, deliver the remainder!
                    if start >= drop_at or start > 0:
                        content_length = end - start + 1
                        self.send_response(HTTPStatus.PARTIAL_CONTENT)
                        self.send_header("Content-Type", mime)
                        self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
                        self.send_header("Content-Length", str(content_length))
                        self.send_header("Accept-Ranges", "bytes")
                        self.send_header("Connection", "close")
                        self.end_headers()

                        try:
                            with open(filepath, "rb") as f:
                                f.seek(start)
                                remaining = content_length
                                while remaining > 0:
                                    chunk = f.read(min(65536, remaining))
                                    if not chunk:
                                        break
                                    self.wfile.write(chunk)
                                    remaining -= len(chunk)
                                self.wfile.flush()
                        except Exception:
                            pass
                        return

            # Initial request: deliver up to drop_at, then abruptly drop socket
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Connection", "close")
            self.end_headers()

            try:
                with open(filepath, "rb") as f:
                    remaining = drop_at
                    while remaining > 0:
                        chunk_size = min(4096, remaining)
                        data = f.read(chunk_size)
                        if not data:
                            break
                        self.wfile.write(data)
                        remaining -= len(data)
                    self.wfile.flush()
                self.request.shutdown(socket.SHUT_RDWR)
                self.request.close()
            except Exception:
                pass
            return

        # 8a. Flaky music endpoint (/flaky/music/<filename>)
        if path.startswith("/flaky/music/"):
            filename = path[len("/flaky/music/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            burst_limit = int(query.get("burst_limit", [0])[0])
            if burst_limit > 0 and not self._check_burst_limit(path, limit=burst_limit, window_sec=0.5):
                self.send_response(HTTPStatus.TOO_MANY_REQUESTS)
                self.send_header("Retry-After", "1")
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(b"Rate limit exceeded (burst)\n")
                return

            range_header = self.headers.get("Range")
            self._record_request(path, bool(range_header))

            mode = query.get("mode", [None])[0]
            if mode is None:
                req_count = self.server.requests_by_path.get(path, 1)
                if req_count % 7 == 3:
                    mode = "drop"
                elif req_count % 7 == 5:
                    mode = "stall"
                elif req_count % 11 == 7:
                    mode = "error"
                else:
                    mode = "normal"

            if mode == "error":
                self.send_response(HTTPStatus.SERVICE_UNAVAILABLE)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Connection", "close")
                body = b"Flaky temporary error (503)"
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            mime = self._get_mime(filepath)
            file_size = os.path.getsize(filepath)

            start = 0
            end = file_size - 1
            status_code = HTTPStatus.OK

            if range_header:
                m = re.match(r"^bytes=(\d*)-(\d*)$", range_header.strip())
                if m:
                    s_str, e_str = m.groups()
                    start = int(s_str) if s_str else 0
                    end = int(e_str) if e_str else file_size - 1
                    status_code = HTTPStatus.PARTIAL_CONTENT

            content_length = end - start + 1
            self.send_response(status_code)
            self.send_header("Content-Type", mime)
            if status_code == HTTPStatus.PARTIAL_CONTENT:
                self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
            self.send_header("Content-Length", str(content_length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Connection", "close")
            self.end_headers()

            if mode == "drop":
                try:
                    with open(filepath, "rb") as f:
                        f.seek(start)
                        drop_bytes = min(8192, content_length)
                        data = f.read(drop_bytes)
                        self.wfile.write(data)
                        self.wfile.flush()
                    self.request.shutdown(socket.SHUT_RDWR)
                    self.request.close()
                except Exception:
                    pass
                return

            stall_ms = 400 if mode == "stall" else 0
            try:
                with open(filepath, "rb") as f:
                    f.seek(start)
                    remaining = content_length
                    sent = 0
                    while remaining > 0:
                        chunk = f.read(min(32768, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        remaining -= len(chunk)
                        sent += len(chunk)
                        if stall_ms > 0 and sent >= 16384:
                            time.sleep(stall_ms / 1000.0)
                            stall_ms = 0
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        # 8b. Corrupt music endpoint (/corrupt/music/<filename>)
        if path.startswith("/corrupt/music/"):
            filename = path[len("/corrupt/music/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            range_header = self.headers.get("Range")
            self._record_request(path, bool(range_header))

            mime = self._get_mime(filepath)
            file_size = os.path.getsize(filepath)

            start = 0
            end = file_size - 1
            status_code = HTTPStatus.OK

            if range_header:
                m = re.match(r"^bytes=(\d*)-(\d*)$", range_header.strip())
                if m:
                    s_str, e_str = m.groups()
                    start = int(s_str) if s_str else 0
                    end = int(e_str) if e_str else file_size - 1
                    status_code = HTTPStatus.PARTIAL_CONTENT

            content_length = end - start + 1
            self.send_response(status_code)
            self.send_header("Content-Type", mime)
            if status_code == HTTPStatus.PARTIAL_CONTENT:
                self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
            self.send_header("Content-Length", str(content_length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Connection", "close")
            self.end_headers()

            # Write corrupt bytes (not valid audio header/payload)
            garbage_pattern = b"\xFF\x00\xDE\xAD\xBE\xEF\x00\xFF" * 4096
            try:
                remaining = content_length
                while remaining > 0:
                    to_send = min(len(garbage_pattern), remaining)
                    self.wfile.write(garbage_pattern[:to_send])
                    self.wfile.flush()
                    remaining -= to_send
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        # 8. Standard music endpoint with Range request support (/music/<filename>)
        if path.startswith("/music/"):
            filename = path[len("/music/"):]
            filepath = self._resolve_music_path(filename)
            if not filepath:
                self.send_response(HTTPStatus.NOT_FOUND)
                self.send_header("Connection", "close")
                self.end_headers()
                return

            mime = self._get_mime(filepath)
            file_size = os.path.getsize(filepath)
            range_header = self.headers.get("Range")
            self._record_request(path, bool(range_header))

            if range_header:
                m = re.match(r"^bytes=(\d*)-(\d*)$", range_header.strip())
                if m:
                    start_str, end_str = m.groups()
                    if start_str and end_str:
                        start = int(start_str)
                        end = int(end_str)
                    elif start_str:
                        start = int(start_str)
                        end = file_size - 1
                    elif end_str:
                        length = int(end_str)
                        start = max(0, file_size - length)
                        end = file_size - 1
                    else:
                        start = 0
                        end = file_size - 1

                    if start >= file_size or start > end:
                        self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                        self.send_header("Content-Range", f"bytes */{file_size}")
                        self.send_header("Connection", "close")
                        self.end_headers()
                        return

                    end = min(end, file_size - 1)
                    content_length = end - start + 1

                    self.send_response(HTTPStatus.PARTIAL_CONTENT)
                    self.send_header("Content-Type", mime)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
                    self.send_header("Content-Length", str(content_length))
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Connection", "close")
                    self.end_headers()

                    try:
                        with open(filepath, "rb") as f:
                            f.seek(start)
                            remaining = content_length
                            while remaining > 0:
                                chunk = f.read(min(65536, remaining))
                                if not chunk:
                                    break
                                self.wfile.write(chunk)
                                remaining -= len(chunk)
                            self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, socket.error):
                        pass
                    return

            # Full file 200 OK
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Connection", "close")
            self.end_headers()

            try:
                with open(filepath, "rb") as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        self.send_response(HTTPStatus.NOT_FOUND)
        self.send_header("Connection", "close")
        self.end_headers()

def main():
    parser = argparse.ArgumentParser(description="Adversarial Audio HTTP Test Server")
    parser.add_argument("--port", type=int, default=0, help="Port to listen on (0 for dynamic)")
    parser.add_argument("--dir", type=str, default="example/assets/music", help="Directory with music files")
    args = parser.parse_args()

    music_dir = os.path.abspath(args.dir)
    if not os.path.isdir(music_dir):
        sys.stderr.write(f"Directory not found: {music_dir}\n")
        sys.exit(1)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), AdversarialAudioHTTPHandler)
    server.daemon_threads = True
    server.music_dir = music_dir
    server.stats_lock = threading.Lock()
    server.total_requests = 0
    server.requests_by_path = {}
    server.range_requests_by_path = {}
    server.rate_limited_count = 0
    server.recent_request_times = {}
    actual_port = server.server_address[1]

    sys.stdout.write(f"SERVER_STARTED_PORT:{actual_port}\n")
    sys.stdout.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    main()
