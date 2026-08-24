import logging

logger = logging.getLogger(__name__)


def process(data):
    total = 0
    for item in data:
        total += item
    logger.info("processed %d items", len(data))
    return total
