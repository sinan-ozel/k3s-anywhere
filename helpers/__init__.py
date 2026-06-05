import os
import sys


def require_env(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        sys.exit(f"ERROR: {name} is not set.")
    return val


def get_env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()
