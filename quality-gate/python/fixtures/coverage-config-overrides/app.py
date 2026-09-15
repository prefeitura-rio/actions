def process(data: list[int]) -> int:
    total = sum(data)
    if total > 10:
        return total * 2
    return total


def untested_feature(data: list[int]) -> int:
    total = 0
    for item in data:
        total += item
    if total > 0:
        return total
    return -1
