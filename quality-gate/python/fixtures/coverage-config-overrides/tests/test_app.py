from app import process


def test_process() -> None:
    assert process([1, 2, 3]) == 6
