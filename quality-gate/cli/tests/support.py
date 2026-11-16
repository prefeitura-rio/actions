from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, final

from quality_gate.ai_review.llm import HttpResponse

if TYPE_CHECKING:
    from collections.abc import Mapping
    from pathlib import Path


def git(directory: Path, *arguments: str) -> str:
    completed = subprocess.run(  # noqa: S603 - fixed git argv in tests
        ["git", *arguments],  # noqa: S607
        cwd=directory,
        capture_output=True,
        text=True,
        check=True,
    )
    return completed.stdout


@dataclass(frozen=True, slots=True)
class Request:
    """A request recorded by ``FakeTransport``."""

    url: str
    headers: dict[str, str]
    payload: dict[str, object]


@final
@dataclass
class FakeTransport:
    """Transport test double that answers with queued responses."""

    responses: list[HttpResponse]
    requests: list[Request] = field(default_factory=list[Request])

    def post_json(
        self,
        url: str,
        headers: Mapping[str, str],
        payload: Mapping[str, object],
        timeout: float,
    ) -> HttpResponse:
        """Record the request and answer with the next queued response."""
        assert timeout > 0
        self.requests.append(Request(url=url, headers=dict(headers), payload=dict(payload)))
        return self.responses.pop(0)


def chat_response(content: str, status: int = 200) -> HttpResponse:
    body = json.dumps({"choices": [{"message": {"role": "assistant", "content": content}}]})
    return HttpResponse(status=status, body=body)
