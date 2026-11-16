from __future__ import annotations

import pytest

from quality_gate.ai_review.errors import ConfigurationError, ProviderError
from quality_gate.ai_review.llm import ChatClient, HttpResponse, validate_base_url
from tests.support import FakeTransport, chat_response


def _client(transport: FakeTransport, sleeps: list[float] | None = None) -> ChatClient:
    recorded = sleeps if sleeps is not None else []
    return ChatClient(
        base_url="https://llm.example.invalid/v1/",
        api_key="test-key",
        model="test-model",
        transport=transport,
        sleep=recorded.append,
    )


@pytest.mark.parametrize(
    "url",
    [
        "http://llm.example.invalid/v1",
        "ftp://llm.example.invalid",
        "https://",
        "https://user:pass@llm.example.invalid/v1",
        "https://llm.example.invalid/v1?key=1",
        "file:///etc/passwd",
    ],
)
def test_rejects_unsafe_base_urls(url: str) -> None:
    with pytest.raises(ConfigurationError):
        _ = validate_base_url(url)


def test_accepts_https_and_plain_http_on_localhost() -> None:
    assert validate_base_url("https://api.openai.com/v1/") == "https://api.openai.com/v1"
    assert validate_base_url("http://127.0.0.1:8080/v1") == "http://127.0.0.1:8080/v1"


def test_sends_openai_compatible_request() -> None:
    transport = FakeTransport(responses=[chat_response("hello")])

    answer = _client(transport).complete("system text", "user text")

    assert answer == "hello"
    [request] = transport.requests
    assert request.url == "https://llm.example.invalid/v1/chat/completions"
    assert request.headers == {"Authorization": "Bearer test-key"}
    assert request.payload == {
        "model": "test-model",
        "messages": [
            {"role": "system", "content": "system text"},
            {"role": "user", "content": "user text"},
        ],
    }


def test_retries_rate_limits_and_server_errors() -> None:
    transport = FakeTransport(
        responses=[
            HttpResponse(status=429, body="slow down"),
            HttpResponse(status=503, body="unavailable"),
            chat_response("ok"),
        ],
    )
    sleeps: list[float] = []

    assert _client(transport, sleeps).complete("s", "u") == "ok"
    assert sleeps == [2.0, 4.0]
    assert len(transport.requests) == 3


def test_gives_up_after_the_last_attempt() -> None:
    transport = FakeTransport(responses=[HttpResponse(status=500, body="boom")] * 3)

    with pytest.raises(ProviderError) as raised:
        _ = _client(transport).complete("s", "u")

    assert str(raised.value) == (
        "The model provider failed after 3 attempts. HTTP 500 from the model provider: boom"
    )


def test_client_errors_are_not_retried_and_body_is_bounded() -> None:
    transport = FakeTransport(responses=[HttpResponse(status=401, body="x" * 2000)])

    with pytest.raises(ProviderError) as raised:
        _ = _client(transport).complete("s", "u")

    assert len(transport.requests) == 1
    assert str(raised.value) == "HTTP 401 from the model provider: " + "x" * 500


@pytest.mark.parametrize(
    "body",
    ["not json", "{}", '{"choices": []}', '{"choices": [{"message": {"content": null}}]}'],
)
def test_malformed_provider_responses_are_errors(body: str) -> None:
    transport = FakeTransport(responses=[HttpResponse(status=200, body=body)])

    with pytest.raises(ProviderError):
        _ = _client(transport).complete("s", "u")


@pytest.mark.parametrize(
    ("api_key", "model", "message"),
    [
        ("", "m", "The model API key is empty. Set QUALITY_GATE_AI_API_KEY (input api-key)."),
        ("k", "", "The model name is empty. Set the model input."),
    ],
)
def test_requires_api_key_and_model(api_key: str, model: str, message: str) -> None:
    with pytest.raises(ConfigurationError) as raised:
        _ = ChatClient(
            base_url="https://llm.example.invalid",
            api_key=api_key,
            model=model,
            transport=FakeTransport(responses=[]),
        )

    assert str(raised.value) == message
