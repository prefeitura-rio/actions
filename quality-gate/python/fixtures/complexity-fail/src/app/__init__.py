def calculate_total(values: list[int]) -> int:
    total = 0
    for value in values:
        if value > 0:
            if value % 2 == 0:
                for candidate in values:
                    if candidate > value:
                        if candidate % 3 == 0:
                            total += candidate
                        else:
                            total -= candidate
                    elif candidate < 0:
                        if abs(candidate) > value:
                            total += value
                        else:
                            total -= value
                    else:
                        total += 1
            elif value < -10:
                total -= value
            else:
                total += value
        elif value == 0:
            total += 1
        else:
            total -= value
    return total
