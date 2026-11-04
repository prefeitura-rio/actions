"""Minimal client for OpenAI-compatible chat completion APIs."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol, cast, final, override
from urllib.parse import urlsplit

from quality_gate.ai_review.errors import ConfigurationError, ProviderError
from quality_gate.ai_review.json_values import as_list, as_object, loads

if TYPE_CHECKING:
    from collections.abc import Callable, Mapping
    from email.message import Message
    from http.client import HTTPResponse
    from typing import IO

RETRYABLE_STATUS: frozenset[int] = frozenset({408, 409, 429, 500, 502, 503, 504})
LOCAL_HOSTS: frozenset[str] = frozenset({"localhost", "127.0.0.1", "::1"})
ERROR_BODY_LIMIT = 500


@dataclass(frozen=True, slots=True)
class HttpResponse:
    """Status code and decoded body of an HTTP response."""

    status: int
    body: str


class Transport(Protocol):
    """Sends one JSON POST request and returns the response without raising on status."""

    def post_json(
        self,
        url: str,
        headers: Mapping[str, str],
        payload: Mapping[str, object],
        timeout: float,
    ) -> HttpResponse:
        """Send ``payload`` as JSON to ``url``."""
        ...


@final
class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """Turn every redirect into an HTTP error, so the API key never follows one."""

    @override
    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: IO[bytes],
        code: int,
        msg: str,
        headers: Message,
        newurl: str,
    ) -> None:
        return None


@final
class UrllibTransport:
    """``Transport`` backed by the standard library. Redirects are not followed."""

    def __init__(self) -> None:
        """Build an opener that refuses redirects."""
        self._opener = urllib.request.build_opener(_RefuseRedirects())

    def post_json(
        self,
        url: str,
        headers: Mapping[str, str],
        payload: Mapping[str, object],
        timeout: float,
    ) -> HttpResponse:
        """Send ``payload`` as JSON to ``url``; network failures raise ``ProviderError``."""
        request = urllib.request.Request(  # noqa: S310 - scheme validated by validate_base_url
            url,
            data=json.dumps(payload).encode("utf-8"),
            method="POST",
        )
        request.add_unredirected_header("Content-Type", "application/json")
        for name, value in headers.items():
            request.add_unredirected_header(name, value)
        try:
            opened = cast("HTTPResponse", self._opener.open(request, timeout=timeout))
            with opened as response:
                body = response.read().decode("utf-8", errors="replace")
                return HttpResponse(status=response.status, body=body)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            return HttpResponse(status=error.code, body=body)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            msg = f"Could not reach the model provider: {error}"
            raise ProviderError(msg) from error


def validate_base_url(base_url: str) -> str:
    """Return ``base_url`` without a trailing slash; HTTPS is required except on localhost."""
    parts = urlsplit(base_url)
    local = parts.scheme == "http" and parts.hostname in LOCAL_HOSTS
    if (parts.scheme != "https" and not local) or not parts.hostname:
        msg = f"Invalid base URL '{base_url}'. Use an https:// URL of an OpenAI-compatible API."
        raise ConfigurationError(msg)
    if parts.username or parts.password or parts.query or parts.fragment:
        msg = "The base URL must not contain credentials, a query or a fragment."
        raise ConfigurationError(msg)
    return base_url.rstrip("/")


def _message_content(body: str) -> str:
    try:
        document = as_object(loads(body))
    except json.JSONDecodeError as error:
        msg = "The model provider returned a response that is not JSON."
        raise ProviderError(msg) from error
    choices = as_list(document.get("choices")) if document is not None else None
    first = as_object(choices[0]) if choices else None
    message = as_object(first.get("message")) if first is not None else None
    content = message.get("content") if message is not None else None
    if isinstance(content, str):
        return content
    msg = "The model provider response has no choices[0].message.content."
    raise ProviderError(msg)


@final
class ChatClient:
    """Sends a system and a user message and returns the assistant answer."""

    def __init__(  # noqa: PLR0913 - explicit dependencies keep the client testable
        self,
        *,
        base_url: str,
        api_key: str,
        model: str,
        transport: Transport,
        timeout: float = 120.0,
        max_attempts: int = 3,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        """Validate the provider settings."""
        if not api_key:
            msg = "The model API key is empty. Set QUALITY_GATE_AI_API_KEY (input api-key)."
            raise ConfigurationError(msg)
        if not model:
            msg = "The model name is empty. Set the model input."
            raise ConfigurationError(msg)
        if max_attempts < 1:
            msg = "max_attempts must be at least 1."
            raise ConfigurationError(msg)
        self._url = f"{validate_base_url(base_url)}/chat/completions"
        self._api_key = api_key
        self._model = model
        self._transport = transport
        self._timeout = timeout
        self._max_attempts = max_attempts
        self._sleep = sleep

    def complete(self, system: str, user: str) -> str:
        """Return the assistant message for ``system`` and ``user``."""
        payload: dict[str, object] = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        }
        headers = {"Authorization": f"Bearer {self._api_key}"}
        last_error = "no attempt was made"
        for attempt in range(1, self._max_attempts + 1):
            try:
                response = self._transport.post_json(self._url, headers, payload, self._timeout)
            except ProviderError as error:
                last_error = str(error)
            else:
                if 200 <= response.status < 300:
                    return _message_content(response.body)
                last_error = (
                    f"HTTP {response.status} from the model provider: "
                    f"{response.body.strip()[:ERROR_BODY_LIMIT]}"
                )
                if 300 <= response.status < 400:
                    last_error += (
                        " (redirects are not followed; set the base URL to the final API URL)"
                    )
                if response.status not in RETRYABLE_STATUS:
                    raise ProviderError(last_error)
            if attempt < self._max_attempts:
                self._sleep(2.0**attempt)
        msg = f"The model provider failed after {self._max_attempts} attempts. {last_error}"
        raise ProviderError(msg)
