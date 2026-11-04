"""Typed access to untrusted JSON documents."""

from __future__ import annotations

import json
from typing import cast


def loads(text: str) -> object:
    """Decode ``text``; raises ``json.JSONDecodeError`` like ``json.loads``."""
    return cast("object", json.loads(text))


def as_object(value: object) -> dict[str, object] | None:
    """Return ``value`` as a JSON object with string keys, or ``None``."""
    if not isinstance(value, dict):
        return None
    items = cast("dict[object, object]", value)
    return {str(key): item for key, item in items.items()}


def as_list(value: object) -> list[object] | None:
    """Return ``value`` as a JSON array, or ``None``."""
    if not isinstance(value, list):
        return None
    return cast("list[object]", value)
