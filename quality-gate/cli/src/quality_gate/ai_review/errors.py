"""Errors raised by the AI review."""


class AIReviewError(Exception):
    """Base error of the AI review. Its message is shown to the user as is."""


class ConfigurationError(AIReviewError):
    """Invalid input: missing styleguide, credentials, git references or options."""


class ProviderError(AIReviewError):
    """The model provider could not be reached or answered with an error."""


class ResponseFormatError(AIReviewError):
    """The model answered with something that is not the expected JSON document."""
