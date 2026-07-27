#!/usr/bin/env python3
"""Restore deterministic source mtimes so Xcode can reuse CI build outputs."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATHS = ("Config", "Resources", "Sources", "Tests", "project.yml")


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.check_output(
        ("git", *args),
        cwd=cwd,
        text=True,
    ).strip()


def restore_prompt_mtimes() -> None:
    files = git("ls-files", "-z", "--", *SOURCE_PATHS).split("\0")
    for relative_path in filter(None, files):
        path = ROOT / relative_path
        if not path.exists():
            continue
        timestamp = int(git("log", "-1", "--format=%ct", "--", relative_path))
        os.utime(path, (timestamp, timestamp), follow_symlinks=False)


def restore_ghostty_mtimes() -> None:
    worktree = ROOT / ".build/ghostty"
    timestamp = int(git("show", "-s", "--format=%ct", "HEAD", cwd=worktree))
    macos = worktree / "macos"
    for directory, _, filenames in os.walk(macos):
        for filename in filenames:
            path = Path(directory) / filename
            if not path.is_symlink():
                os.utime(path, (timestamp, timestamp))


def restore_project_mtimes() -> None:
    timestamp = int((ROOT / "project.yml").stat().st_mtime)
    project = ROOT / "Prompt.xcodeproj"
    for directory, _, filenames in os.walk(project):
        for filename in filenames:
            path = Path(directory) / filename
            if not path.is_symlink():
                os.utime(path, (timestamp, timestamp))


if __name__ == "__main__":
    restore_prompt_mtimes()
    restore_ghostty_mtimes()
    restore_project_mtimes()
