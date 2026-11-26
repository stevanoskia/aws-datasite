"""The pipeline's way of running a fixed script on the app server, with a stand-in for the AWS CLI."""

import os
import subprocess
from pathlib import Path

import pytest
from test_infra_workflow import BASH

SCRIPT = Path(__file__).resolve().parents[1] / "ci_send_command.sh"
TAG = "c" * 40
SERVER_OUTPUT = "output-of-the-server-must-stay-in-aws"

# Answers like the AWS CLI. Asked for the invocation without a --query, it would also return the server's output
AWS = f"""
echo "$*" >> "$FAKE/aws.log"
case "$*" in
  *describe-instance-information*) cat "$FAKE/online" ;;
  *send-command*) echo cmd-123 ;;
  *list-command-invocations*)
    n=$(( $(cat "$FAKE/polls" 2> /dev/null || echo 0) + 1 )); echo $n > "$FAKE/polls"
    if [ $n -lt 3 ]; then echo "InProgress i-0abc"; else printf '%s\\ti-0abc\\n' "$(cat "$FAKE/status")"; fi ;;
  *get-command-invocation*)
    case "$*" in *"--query ResponseCode"*) cat "$FAKE/code" ;; *) echo "{SERVER_OUTPUT}" ;; esac ;;
  *) exit 99 ;;
esac
"""


@pytest.fixture
def fake(tmp_path):
    (tmp_path / "bin").mkdir()
    (tmp_path / "bin/aws").write_text(f"#!/usr/bin/env bash\n{AWS}\n", newline="\n")
    (tmp_path / "bin/aws").chmod(0o755)  # Linux runs only executable files (Windows doesn't check)
    for name, value in {"online": "1", "status": "Success", "code": "0"}.items():
        (tmp_path / name).write_text(value + "\n")
    return tmp_path


def run(fake: Path, tag: str = TAG, **env: str) -> tuple[int, str]:
    environment = {**os.environ, "PATH": f"{fake / 'bin'}{os.pathsep}{os.environ['PATH']}", "FAKE": fake.as_posix(), "POLL_SECONDS": "0", **env}
    done = subprocess.run([BASH, SCRIPT.as_posix(), "test-deploy", tag], env=environment, capture_output=True, text=True, check=False)
    return done.returncode, done.stdout + done.stderr


@pytest.mark.parametrize("status, code", [("Success", "0"), ("Failed", "20"), ("Failed", "10")])
def test_the_exit_code_of_the_server_is_passed_on(fake, status, code):
    (fake / "status").write_text(status)
    (fake / "code").write_text(code)
    result, output = run(fake)
    assert result == int(code)
    assert f"status {status}, exit code {code}" in output and "cmd-123" in output
    assert (fake / "polls").read_text().strip() == "3"  # waited until it was finished


def test_the_server_output_never_reaches_the_log(fake):
    _, output = run(fake)
    assert SERVER_OUTPUT not in output and "i-0abc" not in output
    log = (fake / "aws.log").read_text()
    assert "--details" not in log and "--query ResponseCode" in log


@pytest.mark.parametrize("tag", ["c" * 39, "C" * 40, TAG + "; reboot", "", "../" + "c" * 37])
def test_only_a_commit_is_accepted(fake, tag):
    code, _ = run(fake, tag)
    assert code == 2 and not (fake / "aws.log").exists()


def test_a_stopped_server_is_reported_at_once(fake):
    (fake / "online").write_text("0")
    code, output = run(fake)
    assert code == 3 and "not online" in output and "send-command" not in (fake / "aws.log").read_text()


def test_it_gives_up_after_the_time_limit(fake):
    (fake / "status").write_text("InProgress")
    code, output = run(fake, WAIT_SECONDS="0")
    assert code == 4 and "no result" in output


def test_a_cancelled_command_is_a_failure(fake):
    (fake / "status").write_text("Cancelled")
    (fake / "code").write_text("-1")
    assert run(fake)[0] == 5
