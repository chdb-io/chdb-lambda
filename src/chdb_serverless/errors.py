"""Shared errors.

MissingDependency is a plain Exception subclass (not SystemExit) so a server
handler's `except Exception` catches it and returns an error response instead
of the process exiting. Its message names the extra to install.
"""


class MissingDependency(RuntimeError):
    """An optional extra (a store or model provider) isn't installed."""
