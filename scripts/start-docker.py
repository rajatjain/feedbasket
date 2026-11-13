#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    os.chdir(Path(__file__).resolve().parents[1])
    os.environ.setdefault("FEEDBASKET_HOST_UID", str(os.getuid()))
    os.environ.setdefault("FEEDBASKET_HOST_GID", str(os.getgid()))
    compose = ["docker", "compose"]
    config = json.loads(subprocess.check_output([*compose, "config", "--format", "json"]))
    for mount in config["services"]["backend"]["volumes"]:
        if mount["type"] == "bind":
            Path(mount["source"]).mkdir(mode=0o700, parents=True, exist_ok=True)
    os.execvp("docker", [*compose, "up", "--build", "-d", *sys.argv[1:]])


if __name__ == "__main__":
    main()
