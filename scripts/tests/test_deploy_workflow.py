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


def test_a_failed_migration_says_what_happened(tmp_path):
    code, output, summary = run(
        tmp_path, step("app.yml", "Migrate on the app server"), 30
    )
    assert (
        code == 1
        and "::error::the migration failed (exit code 30)" in output
        and "migrated" not in summary
    )
