#!/usr/bin/env python3

from pathlib import Path
import subprocess
import sys


INSTALLER_PATH = Path(__file__).resolve().with_name("install.sh")


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    print(
        "install.py is deprecated; delegating to install.sh.",
        file=sys.stderr,
    )
    try:
        result = subprocess.run(
            ["bash", str(INSTALLER_PATH), *arguments],
            check=False,
        )
    except FileNotFoundError:
        print("bash is required to run install.sh.", file=sys.stderr)
        return 127
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
