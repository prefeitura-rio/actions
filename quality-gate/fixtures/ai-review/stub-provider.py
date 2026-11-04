"""OpenAI-compatible stub used by the Quality Gate Tests workflow.

It answers every chat completion with one styleguide finding on
quality-gate/fixtures/ai-review/project/app.py, so the workflow can exercise
the ai-review action end to end without a real model provider. Requests
without the expected bearer token get HTTP 401.

Usage: python3 stub-provider.py <port>
"""

from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "stub-key"  # noqa: S105 - fixed token of a local test stub, not a secret
FINDING = {
    "path": "quality-gate/fixtures/ai-review/project/app.py",
    "line": 1,
    "severity": "error",
    "rule": "no-print",
    "message": "print is not allowed by the styleguide.",
    "suggestion": 'logging.getLogger(__name__).info("hello")',
}


class Handler(BaseHTTPRequestHandler):
    """Answers POST /v1/chat/completions."""

    def do_POST(self) -> None:
        """Answer one chat completion request."""
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)
        if self.path != "/v1/chat/completions":
            self._send(404, {"error": {"message": "not found"}})
        elif self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self._send(401, {"error": {"message": "invalid api key"}})
        else:
            content = json.dumps({"findings": [FINDING]})
            self._send(200, {"choices": [{"message": {"role": "assistant", "content": content}}]})

    def _send(self, status: int, document: dict[str, object]) -> None:
        body = json.dumps(document).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        _ = self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
