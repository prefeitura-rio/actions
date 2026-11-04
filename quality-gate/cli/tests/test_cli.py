from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import TYPE_CHECKING, ClassVar, final, override

import pytest
from typer.testing import CliRunner, Result

from quality_gate.ai_review.json_values import as_object, loads
from quality_gate.cli import app
from tests.support import git

if TYPE_CHECKING:
    from collections.abc import Iterator, Mapping, Sequence
    from pathlib import Path

runner = CliRunner()


@final
class _ProviderHandler(BaseHTTPRequestHandler):
    """OpenAI-compatible endpoint answering with the queued responses."""

    queued: ClassVar[list[tuple[int, str]]] = []
    requests: ClassVar[list[dict[str, object]]] = []
    authorizations: ClassVar[list[str]] = []

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        document = as_object(loads(self.rfile.read(length).decode("utf-8")))
        assert document is not None
        type(self).requests.append(document)
        type(self).authorizations.append(self.headers.get("Authorization", ""))
        status, body = type(self).queued.pop(0)
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        _ = self.wfile.write(encoded)

    @override
    def log_message(self, format: str, *args: object) -> None:
        return


@pytest.fixture
def provider() -> Iterator[str]:
    _ProviderHandler.queued = []
    _ProviderHandler.requests = []
    _ProviderHandler.authorizations = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), _ProviderHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}/v1"
    finally:
        server.shutdown()
        server.server_close()


def _answer(findings: Sequence[Mapping[str, object]]) -> tuple[int, str]:
    content = json.dumps({"findings": findings})
    return 200, json.dumps({"choices": [{"message": {"content": content}}]})


def _feature_branch(repository: Path) -> None:
    _ = git(repository, "checkout", "--quiet", "-b", "feature")
    _ = (repository / "service" / "new.py").write_text("print('hi')\n", encoding="utf-8")
    _ = git(repository, "add", ".")
    _ = git(repository, "commit", "--quiet", "-m", "feature")


def _invoke(repository: Path, provider: str, *extra: str, key: str = "test-key") -> Result:
    return runner.invoke(
        app,
        [
            "ai-review",
            "--working-directory",
            str(repository / "service"),
            "--base-ref",
            "main",
            "--model",
            "test-model",
            "--base-url",
            provider,
            *extra,
        ],
        env={"QUALITY_GATE_AI_API_KEY": key},
    )


def test_findings_fail_with_report_summary_and_annotations(
    repository: Path,
    provider: str,
    tmp_path: Path,
) -> None:
    _feature_branch(repository)
    _ProviderHandler.queued.append(
        _answer(
            [
                {
                    "path": "service/new.py",
                    "line": 1,
                    "severity": "error",
                    "rule": "no-print",
                    "message": "print is forbidden",
                    "suggestion": "logger.info('hi')",
                },
            ],
        ),
    )
    error_file = tmp_path / "error.txt"
    summary_file = tmp_path / "summary.md"

    result = runner.invoke(
        app,
        [
            "ai-review",
            "--working-directory",
            str(repository / "service"),
            "--base-ref",
            "main",
            "--model",
            "test-model",
            "--base-url",
            provider,
            "--summary-file",
            str(summary_file),
            "--error-file",
            str(error_file),
            "--github-annotations",
        ],
        env={"QUALITY_GATE_AI_API_KEY": "test-key"},
    )

    assert result.exit_code == 1
    assert "::error file=service/new.py,line=1,title=AI review%3A no-print::" in result.stdout
    report = error_file.read_text(encoding="utf-8")
    assert report.startswith("Error: AI review found code outside the styleguide")
    assert "service/new.py:1: error [no-print] print is forbidden\n    logger.info('hi')" in report
    assert "| `service/new.py:1` | error | no-print |" in summary_file.read_text(encoding="utf-8")
    assert _ProviderHandler.authorizations == ["Bearer test-key"]
    [request] = _ProviderHandler.requests
    messages = request["messages"]
    assert isinstance(messages, list)
    assert "Never use print." in json.dumps(messages)
    assert '<file path=\\"service/new.py\\">' in json.dumps(messages)
    assert "old.py" not in json.dumps(messages)


def test_github_mode_disables_workflow_commands_around_model_output(
    repository: Path,
    provider: str,
) -> None:
    _feature_branch(repository)
    _ProviderHandler.queued.append(
        _answer(
            [
                {
                    "path": "service/new.py",
                    "line": 1,
                    "severity": "error",
                    "rule": "no-print",
                    "message": "bad\n::add-mask::leak",
                    "suggestion": "::error file=x.py,line=1::fake\n::stop-commands::other",
                },
            ],
        ),
    )

    result = _invoke(repository, provider, "--github-annotations")

    assert result.exit_code == 1
    lines = result.stdout.splitlines()
    annotation, stop = lines[0], lines[1]
    assert annotation.startswith("::error file=service/new.py,line=1,")
    assert "%0A::add-mask::leak" in annotation
    assert stop.startswith("::stop-commands::")
    token = stop.removeprefix("::stop-commands::")
    assert len(token) == 32
    assert lines[-1] == f"::{token}::"
    body = lines[2:-1]
    assert "::add-mask::leak" in body
    assert all(token not in line for line in body)
    assert result.stderr == ""


def test_clean_review_passes(repository: Path, provider: str) -> None:
    _feature_branch(repository)
    _ProviderHandler.queued.append(_answer([]))

    result = _invoke(repository, provider)

    assert result.exit_code == 0
    assert "AI review passed: 1 file(s) reviewed against STYLEGUIDE.md" in result.stdout


def test_warnings_only_fail_when_requested(repository: Path, provider: str) -> None:
    _feature_branch(repository)
    warning = {
        "path": "service/new.py",
        "line": 1,
        "severity": "warning",
        "rule": "naming",
        "message": "vague",
    }
    _ProviderHandler.queued.extend([_answer([warning]), _answer([warning])])

    assert _invoke(repository, provider).exit_code == 0
    failed = _invoke(repository, provider, "--fail-on", "warning")
    assert failed.exit_code == 1


def test_no_changed_sources_passes_without_calling_the_model(
    repository: Path,
    provider: str,
) -> None:
    result = _invoke(repository, provider)

    assert result.exit_code == 0
    assert _ProviderHandler.requests == []


def test_missing_api_key_is_a_configuration_error(
    repository: Path,
    provider: str,
    tmp_path: Path,
) -> None:
    error_file = tmp_path / "error.txt"

    result = _invoke(repository, provider, "--error-file", str(error_file), key="")

    assert result.exit_code == 2
    assert error_file.read_text(encoding="utf-8") == (
        "The model API key is empty. Set QUALITY_GATE_AI_API_KEY (input api-key).\n"
    )


def test_missing_styleguide_is_a_configuration_error(repository: Path, provider: str) -> None:
    (repository / "STYLEGUIDE.md").unlink()

    result = _invoke(repository, provider)

    assert result.exit_code == 2
    assert "No styleguide found." in result.stderr
    assert _ProviderHandler.requests == []


def test_provider_rejection_is_a_provider_error(repository: Path, provider: str) -> None:
    _feature_branch(repository)
    _ProviderHandler.queued.append((401, '{"error": {"message": "invalid key"}}'))

    result = _invoke(repository, provider)

    assert result.exit_code == 3
    assert "HTTP 401 from the model provider" in result.stderr


def test_unparseable_model_answer_is_a_provider_error(repository: Path, provider: str) -> None:
    _feature_branch(repository)
    _ProviderHandler.queued.append(
        (200, json.dumps({"choices": [{"message": {"content": "I cannot help."}}]})),
    )

    result = _invoke(repository, provider)

    assert result.exit_code == 3
    assert "The model answer is not a JSON object" in result.stderr
