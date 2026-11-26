"""The private values here are made up, and put together from parts so that check.ps1 doesn't find them in this file."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "safe_log.py"
ACCOUNT = "4455" + "66778899"
OTHER_ACCOUNT = "9988" + "77665544"
OFFICE = "81.2.69.142"
BUCKET = "my-state-bucket-1a2b3c"


def run(text: str | bytes, redact: str = "", forbid: str = "") -> tuple[str, int]:
    env = {**os.environ, "LOG_REDACT": redact, "LOG_FORBID": forbid}
    data = text if isinstance(text, bytes) else text.encode()
    done = subprocess.run([sys.executable, str(SCRIPT)], input=data, capture_output=True, env=env)
    assert done.stderr == b""
    return done.stdout.decode("utf-8").replace("\r\n", "\n"), done.returncode


@pytest.mark.parametrize(
    "private",
    [
        OTHER_ACCOUNT,
        f"arn:aws:iam::{OTHER_ACCOUNT}:role/x",
        f"role-{OTHER_ACCOUNT}",
        "AKIA" + "ABCDEFGHIJKLMNOP",
        "ASIA" + "ABCDEFGHIJKLMNOP",
        "-----BEGIN RSA " + "PRIVATE KEY-----",
        "ghp_" + "a1" * 18,
        "github_pat_" + "a1" * 15,
        "somebody" + "@" + "company.example.io",
        "my-db.abc123xyz.eu-north-1.rds.amazonaws.com",
        "MY-DB.ABC123XYZ.EU-NORTH-1.RDS.AMAZONAWS.COM:5432",
        "8.8.8.8",
        f"{OFFICE}/32",
        f'["{OFFICE}/32"]',
        f"from {OFFICE}.",
    ],
)
def test_private_lines_are_hidden(private):
    output, code = run(f"before\nx = {private} y\nafter\n")
    assert private not in output and OFFICE not in output
    assert output.startswith("before\n[line hidden: ") and "\nafter\n" in output
    assert code == 3


NORMAL = """\
Plan: 3 to add, 0 to change, 0 to destroy.
  # module.db_secret.aws_secretsmanager_secret.this will be created
  + cidr_ipv4 = "0.0.0.0/0"
  + cidr_block = "10.30.10.0/24"
aws_instance.nat: Creation complete after 12s [id=i-0c304a4a01d26f986]
Terraform v1.17.1, provider 6.74.0, 127.0.0.1, 172.31.0.0/16, 169.254.169.254
Service = "rds.amazonaws.com", "com.amazonaws.eu-north-1.s3"
id=terraform-20261125103807393000000001 sha256:1234567890123456789012ab
blob.core.windows.net/actions-results/c8b25e1f-6b59-8de6-8565-123456789012/artifact
user15{AT}example.org 123456-name{AT}users.noreply.github.com
50 ── 100%
""".replace("{AT}", "@")


def test_normal_output_is_unchanged():
    assert run(NORMAL) == (NORMAL, 0)


def test_expected_values_are_replaced_and_are_no_finding():
    line = f"arn:aws:iam::{ACCOUNT}:role/app in {BUCKET.upper()}\n"
    assert run(line, redact=f"{ACCOUNT}\n{BUCKET}\n") == ("arn:aws:iam::***:role/app in ***\n", 0)


def test_one_expected_value_does_not_excuse_another():
    output, code = run(f"{ACCOUNT} and {OTHER_ACCOUNT}\n", redact=ACCOUNT)
    assert code == 3 and ACCOUNT not in output and OTHER_ACCOUNT not in output


def test_a_value_inside_another_leaves_nothing_behind():
    assert run("name-of-it-full\n", redact="name-of\nname-of-it-full") == ("***\n", 0)


def test_forbidden_values_are_hidden_in_any_case():
    output, code = run("the Secret-Word is here\n", forbid="secret-word")
    assert (output.splitlines()[0], code) == ("[line hidden: private value]", 3)


@pytest.mark.parametrize("empty", ["", "\n\n", "  \n", "a\n"])
def test_empty_or_tiny_values_do_not_match_everything(empty):
    assert run("a normal line\n", redact=empty, forbid=empty) == ("a normal line\n", 0)


def test_it_reads_to_the_end_after_a_hit_and_after_unreadable_bytes():
    text = f"{OTHER_ACCOUNT}\n".encode() + b"\xff\xfe broken\n" + b"line\n" * 50_000 + b"last\n"
    output, code = run(text)
    lines = output.splitlines()
    assert (lines[0], lines[-2], len(lines), code) == ("[line hidden: account ID]", "last", 50_004, 3)


def test_a_line_that_cannot_be_checked_is_hidden(monkeypatch):
    sys.path.insert(0, str(SCRIPT.parent))
    import safe_log

    monkeypatch.setattr(safe_log, "find_private", lambda *_: 1 / 0)
    assert safe_log.clean("something\n", [], []) == ("[line hidden: not checkable]\n", True)
