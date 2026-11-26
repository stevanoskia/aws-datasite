"""The steps of the deploy and app workflows that turn a server's exit code into a message, run as GitHub runs them."""

import os
import re
import subprocess
import textwrap
from pathlib import Path

import pytest
from test_infra_workflow import BASH

ROOT = Path(__file__).resolve().parents[2]
TAG = "d" * 40
GITHUB_SHELL = [
    BASH,
    "--noprofile",
    "--norc",
    "-eo",
    "pipefail",
]  # what "run:" uses: -e stops at the first failing command


def step(workflow: str, name: str) -> str:
    text = (ROOT / ".github/workflows" / workflow).read_text(encoding="utf-8")
    body = re.search(
        rf"- name: {re.escape(name)}\n(.*?)(?=\n      - |\n  \w|\Z)", text, re.DOTALL
    ).group(1)
    return textwrap.dedent(body.split("run: |\n", 1)[1])


def run(tmp_path: Path, script: str, server_code: int) -> tuple[int, str, str]:
    (tmp_path / "scripts").mkdir(exist_ok=True)
    (tmp_path / "scripts/ci_send_command.sh").write_text(
        f"echo 'status Failed, exit code {server_code}'\nexit {server_code}\n",
        newline="\n",
    )
    (tmp_path / "step.sh").write_text(script, newline="\n")
    summary = tmp_path / "summary"
    env = {
        **os.environ,
        "TAG": TAG,
        "GITHUB_SHA": TAG,
        "GITHUB_STEP_SUMMARY": summary.as_posix(),
    }
    done = subprocess.run(
        [*GITHUB_SHELL, "step.sh"],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    return (
        done.returncode,
        done.stdout + done.stderr,
        summary.read_text() if summary.exists() else "",
    )


DEPLOY = step("deploy.yml", "Deploy on the app server")


@pytest.mark.parametrize(
    "server_code, message",
    [
        (10, "the database lacks migrations"),
        (11, "the database could not be checked"),
        (20, "the previous one runs again"),
        (21, "the app is down"),
        (3, "failed (exit code 3)"),
    ],
)
def test_a_failed_deploy_says_what_happened(tmp_path, server_code, message):
    code, output, summary = run(tmp_path, DEPLOY, server_code)
    assert code == 1
    assert f"::error::{message}" in output or (
        message in output and "::error::" in output
    )
    assert message in summary


def test_a_good_deploy_is_reported(tmp_path):
    code, output, summary = run(tmp_path, DEPLOY, 0)
    assert (
        code == 0
        and "deployed and healthy" in output
        and f"{TAG}: deployed and healthy" in summary
    )


def git_repository(folder: Path) -> dict[str, str]:
    """Three commits: the first one with a migration, then an app change, then a new migration."""

    def git(*arguments: str) -> str:
        done = subprocess.run(["git", "-C", str(folder), *arguments], capture_output=True, text=True, check=True)
        return done.stdout.strip()

    git("init", "-q")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "test")
    commits = {}
    for name, path in (("first", "db/migrations/0001_a.sql"), ("app", "app/main.py"), ("migration", "db/migrations/0002_b.sql")):
        (folder / path).parent.mkdir(parents=True, exist_ok=True)
        (folder / path).write_text(name)
        git("add", "-A")
        git("commit", "-q", "-m", name)
        commits[name] = git("rev-parse", "HEAD")
    return commits


@pytest.mark.parametrize(
    "event, before, after, by_hand, expected",
    [
        ("push", "first", "app", "", "false"),  # no new migration
        ("push", "app", "migration", "", "true"),  # a new migration
        ("push", "first", "migration", "", "true"),  # several commits, one of them with a migration
        ("push", "", "app", "", "true"),  # starting point unknown: rather ask once too often
        ("push", "0" * 40, "app", "", "true"),  # a commit that doesn't exist
        ("workflow_dispatch", "", "migration", "", "false"),  # by hand: only when asked for
        ("workflow_dispatch", "", "app", "false", "false"),
        ("workflow_dispatch", "", "app", "true", "true"),
    ],
)
def test_the_migration_runs_only_when_needed(tmp_path, event, before, after, by_hand, expected):
    commits = git_repository(tmp_path)
    output = tmp_path / "output"
    env = {
        **os.environ,
        "EVENT": event,
        "BEFORE": commits.get(before, before),
        "BY_HAND": by_hand,
        "GITHUB_SHA": commits[after],
        "GITHUB_OUTPUT": output.as_posix(),
        "GITHUB_STEP_SUMMARY": (tmp_path / "summary").as_posix(),
    }
    (tmp_path / "step.sh").write_text(step("app.yml", "Compare with the previous push"), newline="\n")
    done = subprocess.run([*GITHUB_SHELL, "step.sh"], cwd=tmp_path, env=env, capture_output=True, text=True, check=False)
    assert done.returncode == 0, done.stderr
    assert output.read_text().strip() == f"migrate={expected}"


def test_the_snapshot_waits_until_the_database_is_available(tmp_path):
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin/aws").write_text('#!/usr/bin/env bash\necho "$*" >> "$LOG"\necho None\n', newline="\n")
    (tmp_path / "bin/aws").chmod(0o755)
    (tmp_path / "step.sh").write_text(step("app.yml", "Snapshot of the database"), newline="\n")
    env = {
        **os.environ,
        "PATH": f"{tmp_path / 'bin'}{os.pathsep}{os.environ['PATH']}",
        "LOG": (tmp_path / "aws.log").as_posix(),
        "GITHUB_SHA": TAG,
        "GITHUB_RUN_ID": "1",
        "GITHUB_STEP_SUMMARY": (tmp_path / "summary").as_posix(),
    }
    done = subprocess.run([*GITHUB_SHELL, "step.sh"], cwd=tmp_path, env=env, capture_output=True, text=True, check=False)
    calls = (tmp_path / "aws.log").read_text().splitlines()
    assert done.returncode == 0, done.stderr
    assert calls[0].startswith("rds wait db-instance-available") and calls[1].startswith("rds create-db-snapshot")


def test_a_failed_migration_says_what_happened(tmp_path):
    code, output, summary = run(
        tmp_path, step("app.yml", "Migrate on the app server"), 30
    )
    assert (
        code == 1
        and "::error::the migration failed (exit code 30)" in output
        and "migrated" not in summary
    )
