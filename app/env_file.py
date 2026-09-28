"""Small helper to update individual keys in a .env file in place, preserving
everything else (comments, ordering, unrelated keys).
"""

from pathlib import Path


def update_env_file(
    env_path: Path, updates: dict[str, str], remove_keys: frozenset[str] = frozenset()
) -> None:
    lines = env_path.read_text().splitlines() if env_path.exists() else []
    written: set[str] = set()
    new_lines: list[str] = []

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            new_lines.append(line)
            continue
        key = stripped.split("=", 1)[0].strip()
        if key in remove_keys:
            continue
        if key in updates:
            new_lines.append(f"{key}={updates[key]}")
            written.add(key)
        else:
            new_lines.append(line)

    for key, value in updates.items():
        if key not in written:
            new_lines.append(f"{key}={value}")

    env_path.write_text("\n".join(new_lines) + "\n")
