#!/usr/bin/env python3
"""Deterministic Ollama fixture for the iOS QoL integration workflow."""

from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


MODEL = "qol-model"


class FixtureState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._requests: list[dict[str, Any]] = []
        self._releases = {
            "slow": threading.Event(),
            "beta": threading.Event(),
        }

    def reset(self) -> None:
        with self._lock:
            self._requests.clear()
            for release in self._releases.values():
                release.clear()

    def append(self, request: dict[str, Any]) -> None:
        with self._lock:
            self._requests.append(request)

    def snapshot(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._requests)

    def release(self, name: str) -> bool:
        release = self._releases.get(name)
        if release is None:
            return False
        release.set()
        return True

    def wait(self, name: str) -> None:
        self._releases[name].wait(timeout=45)


STATE = FixtureState()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        route, endpoint = self._route()
        if self.path == "/test/requests":
            self._json(200, {"requests": STATE.snapshot()})
        elif route is not None and endpoint == "/api/version":
            self._json(200, {"version": "0.12.6-qol-fixture"})
        elif route is not None and endpoint == "/api/tags":
            self._json(
                200,
                {
                    "models": [
                        {
                            "name": MODEL,
                            "model": MODEL,
                            "modified_at": "2026-09-11T00:00:00Z",
                            "size": 1,
                            "digest": f"{route}-fixture",
                            "details": {},
                        }
                    ]
                },
            )
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
        if self.path == "/test/reset":
            self._read_json()
            STATE.reset()
            self._json(200, {"ok": True})
            return
        if self.path.startswith("/test/release/"):
            self._read_json()
            name = self.path.removeprefix("/test/release/")
            if STATE.release(name):
                self._json(200, {"released": name})
            else:
                self._json(404, {"error": "unknown release gate"})
            return

        route, endpoint = self._route()
        if route is None:
            self._json(404, {"error": "not found"})
            return
        body = self._read_json()
        if endpoint == "/api/show":
            self._json(200, {"details": {}, "capabilities": ["vision"]})
        elif endpoint == "/api/chat":
            self._chat(route, body)
        else:
            self._json(404, {"error": "not found"})

    def _route(self) -> tuple[str | None, str]:
        for route in ("home", "lab"):
            prefix = f"/{route}"
            if self.path == prefix or self.path.startswith(f"{prefix}/"):
                return route, self.path[len(prefix) :]
        return None, self.path

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length) if length else b"{}"
        try:
            decoded = json.loads(data)
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid JSON"})
            raise
        if not isinstance(decoded, dict):
            self._json(400, {"error": "expected a JSON object"})
            raise ValueError("expected a JSON object")
        return decoded

    def _chat(self, route: str, body: dict[str, Any]) -> None:
        messages = body.get("messages")
        prompt = ""
        image_count = 0
        if isinstance(messages, list):
            for message in reversed(messages):
                if not isinstance(message, dict) or message.get("role") != "user":
                    continue
                content = message.get("content")
                if isinstance(content, str):
                    prompt = content
                images = message.get("images")
                if isinstance(images, list):
                    image_count = len(images)
                break
        STATE.append(
            {
                "route": route,
                "prompt": prompt,
                "model": body.get("model"),
                "imageCount": image_count,
            }
        )

        if "SLOW_HOME" in prompt:
            chunks = [
                (0.0, "HOME_SLOW_STARTED "),
                (
                    "slow",
                    "HOME_SLOW_COMPLETE FIND_TARGET. "
                    "Math: $x^2 + 1$.\n\n"
                    "```dart\nprint(\"queue\");\n```",
                ),
            ]
        elif "QUEUE_BETA" in prompt:
            chunks = [(0.0, "HOME_BETA_STARTED "), ("beta", "HOME_BETA_LATE")]
        elif "QUEUE_ALPHA" in prompt:
            chunks = [(0.0, "HOME_ALPHA_COMPLETE")]
        elif "IMAGE_PAIR" in prompt:
            chunks = [(0.0, "HOME_IMAGE_COMPLETE")]
        else:
            chunks = [(0.0, f"{route.upper()}_COMPLETE")]

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for gate, content in chunks:
                if isinstance(gate, str):
                    STATE.wait(gate)
                elif gate:
                    time.sleep(gate)
                self._ndjson(
                    {
                        "model": MODEL,
                        "message": {"role": "assistant", "content": content},
                        "done": False,
                    }
                )
            self._ndjson(
                {
                    "model": MODEL,
                    "message": {"role": "assistant", "content": ""},
                    "done": True,
                    "done_reason": "stop",
                }
            )
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.close_connection = True

    def _ndjson(self, value: dict[str, Any]) -> None:
        self.wfile.write(json.dumps(value, separators=(",", ":")).encode())
        self.wfile.write(b"\n")
        self.wfile.flush()

    def _json(self, status: int, value: dict[str, Any]) -> None:
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(f"QOL_FIXTURE_READY http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
