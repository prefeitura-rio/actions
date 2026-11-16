from __future__ import annotations

import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import TYPE_CHECKING, ClassVar, final, override

import pytest

from quality_gate.ai_review.errors import ProviderError
from quality_gate.ai_review.llm import ChatClient, UrllibTransport

if TYPE_CHECKING:
    from collections.abc import Iterator


@final
class _Recorder(BaseHTTPRequestHandler):
    """Records every request; answers 302 to ``location`` when it is set, else 200."""

    location: ClassVar[str] = ""
    seen: ClassVar[list[tuple[str, str, str]]] = []

    def _handle(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)
        type(self).seen.append(
            (self.command, self.path, self.headers.get("Authorization", "")),
        )
        if type(self).location and self.path.startswith("/v1/"):
            self.send_response(302)
            self.send_header("Location", type(self).location)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = b'{"choices": [{"message": {"content": "ok"}}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        _ = self.wfile.write(body)

    def do_POST(self) -> None:
        self._handle()

    def do_GET(self) -> None:
        self._handle()

    @override
    def log_message(self, format: str, *args: object) -> None:
        return


@pytest.fixture
def server() -> Iterator[str]:
    _Recorder.location = ""
    _Recorder.seen = []
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), _Recorder)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_address[1]}"
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_posts_json_with_headers(server: str) -> None:
    response = UrllibTransport().post_json(
        f"{server}/v1/chat/completions",
        {"Authorization": "Bearer secret-value"},
        {"model": "m"},
        5.0,
    )

    assert response.status == 200
    assert _Recorder.seen == [("POST", "/v1/chat/completions", "Bearer secret-value")]


def test_redirects_are_not_followed_and_the_key_does_not_leak(server: str) -> None:
    _Recorder.location = f"{server}/elsewhere"

    response = UrllibTransport().post_json(
        f"{server}/v1/chat/completions",
        {"Authorization": "Bearer secret-value"},
        {"model": "m"},
        5.0,
    )

    assert response.status == 302
    assert _Recorder.seen == [("POST", "/v1/chat/completions", "Bearer secret-value")]


def test_redirect_is_reported_as_a_provider_error(server: str) -> None:
    _Recorder.location = f"{server}/elsewhere"
    client = ChatClient(
        base_url=f"{server}/v1",
        api_key="secret-value",
        model="m",
        transport=UrllibTransport(),
    )

    with pytest.raises(ProviderError) as raised:
        _ = client.complete("s", "u")

    assert str(raised.value) == (
        "HTTP 302 from the model provider:  (redirects are not followed; "
        "set the base URL to the final API URL)"
    )
    assert [path for _, path, _ in _Recorder.seen] == ["/v1/chat/completions"]


def test_unreachable_provider_is_a_provider_error() -> None:
    with pytest.raises(ProviderError, match="Could not reach the model provider"):
        _ = UrllibTransport().post_json("http://127.0.0.1:9/v1", {}, {}, 2.0)
