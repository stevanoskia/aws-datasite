"""Reads the public logs of all pipeline runs and reports private data in them: what scripts/safe_log.py missed.

    python scripts/scan_run_logs.py          needs the gh CLI and an AWS login (AWS_PROFILE)

Everything stays in memory. Only counts and places are printed, never the values. Exits with 1 when something was found."""

import io
import json
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

from safe_log import find_private

ROOT = Path(__file__).resolve().parents[1]
GH = shutil.which("gh") or r"C:\Program Files\GitHub CLI\gh.exe"
TIMESTAMP = re.compile(r"^\ufeff?\d{4}-\d\d-\d\dT[\d:.]+Z ?")


def gh(path: str, *more: str) -> bytes:
    return subprocess.run([GH, "api", path, *more], capture_output=True, check=True).stdout


def local_private_values() -> list[str]:
    account = subprocess.run(
        ["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"], capture_output=True, text=True
    ).stdout.strip()
    if not re.fullmatch(r"\d{12}", account):
        sys.exit("ERROR: no AWS login, so the account ID is not known (AWS_PROFILE, aws login)")
    found = {account}
    for path in [*ROOT.glob("terraform/live/*/*.tfvars"), *ROOT.glob("terraform/live/*/backend.hcl")]:
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.lstrip().startswith("#"):
                for value in re.findall(r'"([^"]+)"', line):
                    if "@" in value or "-tfstate-" in value or re.fullmatch(r"[\d.]+(/\d+)?", value):
                        found.add(value.split("/")[0])
    terms = ROOT / "scripts/private-terms.local.txt"
    if terms.exists():
        found |= {line.strip() for line in terms.read_text(encoding="utf-8").splitlines() if line.strip() and line[0] != "#"}
    return sorted(found)


def main() -> int:
    private = local_private_values()
    repo = subprocess.run(
        [GH, "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], capture_output=True, text=True, check=True, cwd=ROOT
    ).stdout.strip()

    runs, page = [], 1
    while True:
        data = json.loads(gh(f"repos/{repo}/actions/runs?per_page=100&page={page}"))
        runs += data["workflow_runs"]
        if len(runs) >= data["total_count"] or not data["workflow_runs"]:
            break
        page += 1

    lines, masked, missing, findings = 0, 0, 0, {}
    for run in runs:
        for attempt in range(1, run["run_attempt"] + 1):
            try:
                archive = gh(f"repos/{repo}/actions/runs/{run['id']}/attempts/{attempt}/logs", "--allow-escape-sequences")
            except subprocess.CalledProcessError:
                missing += 1  # still running, or older than the retention
                continue
            with zipfile.ZipFile(io.BytesIO(archive)) as files:
                for name in files.namelist():
                    if name.endswith("/"):
                        continue
                    for line in files.read(name).decode("utf-8", "replace").splitlines():
                        lines += 1
                        masked += "***" in line
                        rule = find_private(TIMESTAMP.sub("", line), private)
                        if rule:
                            key = (run["id"], run["name"], name, rule)
                            findings[key] = findings.get(key, 0) + 1

    print(f"{len(runs)} runs, {lines} lines read, {masked} of them with masked values, {missing} logs not available")
    print(f"{len(private)} private values and all rules of safe_log.py")
    for (run_id, workflow, name, rule), count in sorted(findings.items()):
        print(f"  {rule}: {count}x in run {run_id} ({workflow}), {name}")
    print(f"{sum(findings.values())} findings")
    return 1 if findings or lines == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
