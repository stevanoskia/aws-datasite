"""The pre-push hook (.githooks/pre-push). What would hurt: a push that makes private data public. The hook is the only
check that runs before the push; the pipeline's checks run after it, when the data is already public.

Each test pushes from a fresh clone (with this working copy's hook and check script) to a local bare repository."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
FAKE_KEY = "AKIA" + "ABCDEFGHIJKLMNOP"  # an access key's shape; put together so the scan doesn't find it in this file
IDENTITY = ["-c", "user.name=test", "-c", "user.email=test@users.noreply.github.com"]


def git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *IDENTITY, *args], cwd=cwd, capture_output=True, text=True, check=check)


@pytest.fixture
def clone(tmp_path):
    remote, work = tmp_path / "remote.git", tmp_path / "work"
    git(tmp_path, "init", "-q", "--bare", str(remote))
    git(tmp_path, "clone", "-q", "--no-hardlinks", str(ROOT), str(work))
    # The hook and the script as they are now, not as last committed
    for path in (".githooks/pre-push", "scripts/check.ps1"):
        shutil.copyfile(ROOT / path, work / path)
    git(work, "config", "core.hooksPath", ".githooks")
    git(work, "remote", "add", "test", str(remote))
    git(work, "add", "-A")
    git(work, "commit", "-q", "--allow-empty", "-m", "the hook as it is now")
    return work


def push(work: Path) -> subprocess.CompletedProcess:
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    return subprocess.run(["git", "push", "test", "HEAD:main"], cwd=work, capture_output=True, text=True, env=env)


def test_the_hook_runs_the_quick_checks():
    hook = (ROOT / ".githooks/pre-push").read_text(encoding="utf-8")
    runs = [line for line in hook.splitlines() if line.strip().startswith("exec ")]
    assert runs and all(line.rstrip().endswith("scripts/check.ps1 -Quick") for line in runs)
    script = (ROOT / "scripts/check.ps1").read_text(encoding="utf-8")
    assert "Test-PrivateData\nif ($Quick)" in script.replace("\r\n", "\n")  # the scan runs in every mode


def test_a_planted_access_key_stops_the_push(clone):
    (clone / "notes.txt").write_text(f"key {FAKE_KEY}\n")
    git(clone, "add", "notes.txt")
    git(clone, "commit", "-q", "-m", "a leak")
    done = push(clone)
    assert done.returncode != 0, "the push went through"
    assert "FAIL  private data" in done.stdout + done.stderr
    assert FAKE_KEY not in done.stdout + done.stderr  # the scan names the place, never the value


def test_clean_work_is_pushed(clone):
    (clone / "notes.txt").write_text("nothing private here\n")
    git(clone, "add", "notes.txt")
    git(clone, "commit", "-q", "-m", "clean")
    done = push(clone)
    assert done.returncode == 0, done.stdout + done.stderr
    assert "ok    private data" in done.stdout + done.stderr
