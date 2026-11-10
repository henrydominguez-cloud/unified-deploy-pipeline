"""Minimal HTTP service used to exercise the pipeline.

All behaviour comes from environment variables that the Helm chart fills
from envs/<env>/app.yaml, so a config_only run changes the output without
a new image.
"""

import json
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def build_response(path, env=None):
    env = os.environ if env is None else env
    if path == "/healthz":
        return 200, {"status": "ok"}
    if path == "/":
        return 200, {
            "greeting": env.get("GREETING", "hello"),
            "feature_new_ui": env.get("FEATURE_NEW_UI", "false") == "true",
            "version": env.get("APP_VERSION", "unknown"),
        }
    return 404, {"error": "not found"}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        status, body = build_response(self.path)
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    # As PID 1 in a container, Python ignores SIGTERM unless a handler is set.
    # Without this, every rollout waits the full 30 s grace period per pod.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    port = int(os.environ.get("PORT", "8080"))
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
