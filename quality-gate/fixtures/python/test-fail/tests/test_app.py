from app import process


def test_process_empty() -> None:
    assert process([]) == 0


def test_process_values() -> None:
    assert process([1, 2, 3]) == 7
