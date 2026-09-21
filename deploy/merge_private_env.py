#!/usr/bin/env python3
"""Atomically merge selected export assignments into a private secret file.

The exports arrive on stdin over SSH; values are never printed or placed in
command-line arguments. The destination must already be a private regular file.
"""

import os
from pathlib import Path
import stat
import sys
import tempfile


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("Usage: merge_private_env.py SECRET_FILE KEY [KEY ...]")
    destination = Path(sys.argv[1])
    keys = tuple(sys.argv[2:])
    if len(set(keys)) != len(keys) or any(not key.isidentifier() or not key.isupper() for key in keys):
        raise SystemExit("Expected unique uppercase environment variable names.")
    current_stat = destination.lstat()
    if not stat.S_ISREG(current_stat.st_mode) or current_stat.st_mode & 0o077:
        raise SystemExit("Destination must be a private regular file.")
    incoming = sys.stdin.read().splitlines()
    if len(incoming) != len(keys):
        raise SystemExit("Expected exactly one export for each requested key.")
    for key, line in zip(keys, incoming):
        prefix = f"export {key}="
        if not line.startswith(prefix) or not line[len(prefix):] or "\r" in line:
            raise SystemExit(f"Invalid export for {key}.")

    existing = destination.read_text().splitlines()
    retained = [line for line in existing if not any(line.startswith(f"export {key}=") for key in keys)]
    handle, temporary = tempfile.mkstemp(prefix=".planner-ingestion-", dir=destination.parent)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w") as stream:
            stream.write("\n".join((*retained, *incoming)) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("Provisioned private environment values (names only).")


if __name__ == "__main__":
    main()
