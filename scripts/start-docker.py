#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def backend_source_digest():
    """Hash the same source and dependency inputs that the Dockerfile copies."""
    backend = Path("backend")
    inputs = [Path("Dockerfile"), Path(".dockerignore")]
    inputs.extend(backend / name for name in (
        "pyproject.toml", "uv.lock", "package.json", "package-lock.json", "feedbasket.docker.toml",
    ))
    for directory in ("feedbasket", "migrations"):
        inputs.extend(path for path in (backend / directory).rglob("*")
                      if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc")

    digest = hashlib.sha256()
    for path in sorted(inputs):
        digest.update(path.as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def main():
    os.chdir(Path(__file__).resolve().parents[1])
    os.environ.setdefault("FEEDBASKET_HOST_UID", str(os.getuid()))
    os.environ.setdefault("FEEDBASKET_HOST_GID", str(os.getgid()))
    os.environ["FEEDBASKET_BUILD_SOURCE"] = backend_source_digest()
    compose = ["docker", "compose"]
    config = json.loads(subprocess.check_output([*compose, "config", "--format", "json"]))
    for mount in config["services"]["backend"]["volumes"]:
        if mount["type"] == "bind":
            Path(mount["source"]).mkdir(mode=0o700, parents=True, exist_ok=True)
    args = sys.argv[1:]
    if not any(arg == "--wait" or arg.startswith("--wait=") for arg in args):
        args.insert(0, "--wait")
    os.execvp("docker", [*compose, "up", "--build", "-d", *args])


if __name__ == "__main__":
    main()
