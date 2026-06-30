import os
import re
import sys


def require_env(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        sys.exit(f"ERROR: {name} is not set.")
    return val


def get_env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _get_env_list(
    env: str,
    sep: str = r'[;,]',
) -> list[str]:
    """
    Retrieves a list of values from environment variables (single or multi).
    Uses ENV or ENVS (with 'S' appended).

    Args:
        env (str): Name of the environment variable (singular).
        sep (str): Separator regex for splitting multi-value env.

    Returns:
        list[str]: List of values.

    Raises:
        ValueError: If neither or both env vars are set.
    """
    value = os.getenv(env, '')
    values = os.getenv(env + 'S', '')
    if not value and not values:
        raise ValueError(f"Neither {env} nor {env+'S'} is set in the environment.")

    if value and values:
        raise ValueError(f"Both {env} and {env+'S'} are set. Please set only one.")
    elif value:
        names = [value]
    elif values:
        names = re.split(sep, values)
    else:
        names = []

    return names


def get_ports() -> list[int]:
    """
    Retrieves port numbers from environment variables PORT or PORTS.

    Returns:
        list[int]: A list of validated TCP port numbers.

    Raises:
        ValueError: If neither or both environment variables are set, or if a
            value is not a valid port (an integer between 1 and 65535).
    """
    ports = []
    for raw in _get_env_list('PORT'):
        raw = raw.strip()
        if not raw.isdigit() or not (1 <= int(raw) <= 65535):
            raise ValueError(f"Port '{raw}' is invalid. Must be an integer between 1 and 65535.")
        ports.append(int(raw))
    return ports
