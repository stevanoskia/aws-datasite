"""Prints its input without private values. Pipeline logs of a public repository are public.

    terraform apply ... 2>&1 | python3 scripts/safe_log.py

  - Values in LOG_REDACT (one per line) are expected, such as the account ID in an ARN: replaced by ***.
  - Values in LOG_FORBID and everything that looks private must not appear: the whole line is hidden.

Exits with 3 when a line was hidden. It always reads its input to the end: stopping early would kill the
program before it in the pipe, and a Terraform run stopped halfway leaves things half built."""

import ipaddress
import os
import re
import sys

SHAPES = {
    "account ID": re.compile(r"(?<![0-9A-Za-z.])\d{12}(?![0-9A-Za-z])"),
    "AWS access key": re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{16}\b"),
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY"),
    "GitHub token": re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})"),
    "database address": re.compile(r"[a-z0-9-]+\.[a-z0-9]+\.[a-z0-9-]+\.rds\.amazonaws\.com", re.I),
}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
PUBLIC_EMAIL = re.compile(r"@(example\.(com|org|net)|users\.noreply\.github\.com)$|^git@github\.com$", re.I)
IPV4 = re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.]*\d)")


def is_public_address(text: str) -> bool:
    try:
        return ipaddress.ip_address(text).is_global
    except ValueError:
        return False


def find_private(line: str, forbidden: list[str]) -> str | None:
    """The name of the first rule that matches, or None."""
    if any(value.lower() in line.lower() for value in forbidden):
        return "private value"
    for name, shape in SHAPES.items():
        if shape.search(line):
            return name
    if any(not PUBLIC_EMAIL.search(email) for email in EMAIL.findall(line)):
        return "email address"
    if any(is_public_address(address) for address in IPV4.findall(line)):
        return "public IP address"
    return None


def clean(line: str, redact: list[str], forbidden: list[str]) -> tuple[str, bool]:
    """The line as it may be printed, and whether it was hidden."""
    try:
        for value in redact:
            line = re.sub(re.escape(value), "***", line, flags=re.I)
        rule = find_private(line, forbidden)
    except Exception:  # a line that can't be checked is not printed, and the input is still read to the end
        rule = "not checkable"
    return (f"[line hidden: {rule}]\n", True) if rule else (line, False)


def values(name: str) -> list[str]:
    # Longest first, so that a value inside another one can't leave half of it. Very short ones would match everywhere
    found = {value.strip() for value in os.environ.get(name, "").splitlines()}
    return sorted((value for value in found if len(value) >= 6), key=len, reverse=True)


def main() -> int:
    redact, forbidden = values("LOG_REDACT"), values("LOG_FORBID")
    hidden = 0
    for raw in sys.stdin.buffer:
        line, was_hidden = clean(raw.decode("utf-8", errors="replace"), redact, forbidden)
        hidden += was_hidden
        sys.stdout.buffer.write(line.encode("utf-8"))
        sys.stdout.buffer.flush()
    if hidden:
        print(f"{hidden} line(s) were hidden because they looked private", flush=True)
    return 3 if hidden else 0


if __name__ == "__main__":
    sys.exit(main())
