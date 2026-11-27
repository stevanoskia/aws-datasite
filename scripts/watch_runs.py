"""Shows how far the pipeline runs of a commit are, until they end.

    python scripts/watch_runs.py            the runs of the last commit (HEAD)
    python scripts/watch_runs.py <commit>   the runs of another commit

Reads the runs with gh (logged in) from the repository of the current folder, every 5 seconds. The percentage compares
each job's time with how long the same job took in the last successful runs of its workflow. Time spent waiting for an
approval is not counted. Ends with exit code 0 when every run succeeded, else 1.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from statistics import median

POLL_SECONDS = 5
APPEAR_SECONDS = 90  # how long to wait for GitHub to start the runs of a push
HISTORY_RUNS = 5
UNKNOWN_JOB_SECONDS = 60
NOT_STARTED = {"queued", "waiting", "pending", "requested"}  # "waiting": for an approval
BAR_WIDTH = 24


def parse_time(text: str | None) -> datetime | None:
    return datetime.fromisoformat(text.replace("Z", "+00:00")) if text else None


def duration(job: dict) -> float | None:
    start, end = parse_time(job.get("started_at")), parse_time(job.get("completed_at"))
    return (end - start).total_seconds() if start and end else None


def typical_seconds(history: list[list[dict]]) -> dict[str, float]:
    """Median time of each job name, over the earlier runs in which it succeeded."""
    times: dict[str, list[float]] = {}
    for jobs in history:
        for job in jobs:
            seconds = duration(job)
            if job.get("conclusion") == "success" and seconds is not None:
                times.setdefault(job["name"], []).append(seconds)
    return {name: median(values) for name, values in times.items()}


def progress(run: dict, jobs: list[dict], typical: dict[str, float], now: datetime) -> tuple[int, float]:
    """Percentage done (100 only when the run has ended) and the seconds probably left."""
    if run["status"] == "completed":
        return 100, 0.0
    done = total = 0.0
    current = {job["name"]: job for job in jobs}
    # Jobs that need others may not be listed yet: the earlier runs say what usually comes
    for name in current.keys() | typical.keys():
        job, usual = current.get(name), typical.get(name, UNKNOWN_JOB_SECONDS)
        if job is None or job["status"] in NOT_STARTED or (job["status"] != "completed" and not job.get("started_at")):
            total += usual  # still to come
        elif job["status"] == "completed":
            done, total = done + usual, total + usual  # finished or skipped: its usual share counts as done
        else:
            elapsed = max(0.0, (now - parse_time(job["started_at"])).total_seconds())
            share = max(usual, elapsed * 1.05)  # a job that takes longer than usual is not shown as finished
            done, total = done + elapsed, total + share
    if total == 0:
        return 0, 0.0
    return min(99, int(100 * done / total)), max(0.0, total - done)


def minutes(seconds: float) -> str:
    seconds = int(round(seconds))
    return f"{seconds // 60}m{seconds % 60:02d}s"


def what_runs(run: dict, jobs: list[dict]) -> str:
    if run["status"] == "completed":
        return run.get("conclusion") or "completed"
    if run["status"] == "waiting":
        waiting = [job["name"] for job in jobs if job["status"] == "waiting"]
        return "WAITING FOR YOUR APPROVAL" + (f": {waiting[0]}" if waiting else "")
    for job in jobs:
        if job["status"] == "in_progress":
            step = next((s["name"] for s in job.get("steps", []) if s.get("status") == "in_progress"), None)
            return f"{job['name']}" + (f" > {step}" if step else "")
    return run["status"]


def line(run: dict, jobs: list[dict], typical: dict[str, float], now: datetime) -> str:
    percent, left = progress(run, jobs, typical, now)
    filled = BAR_WIDTH * percent // 100
    bar = "#" * filled + "-" * (BAR_WIDTH - filled)
    started = parse_time(run.get("run_started_at") or run.get("created_at")) or now
    elapsed = (parse_time(run.get("updated_at")) if run["status"] == "completed" else now) - started
    eta = "" if run["status"] == "completed" or run["status"] == "waiting" else f", ~{minutes(left)} left"
    return f"{run['name']:<7} [{bar}] {percent:3d}%  {minutes(elapsed.total_seconds())}{eta}  {what_runs(run, jobs)}"


# -----------------------------------------------------------------------------
# GitHub, through gh
# -----------------------------------------------------------------------------


def gh_program() -> str:
    found = os.environ.get("GH_PATH") or shutil.which("gh")
    if not found:
        raise SystemExit("gh not found: install it, or set GH_PATH to gh.exe")
    return found


def gh_api(path: str) -> dict:
    done = subprocess.run([gh_program(), "api", path], capture_output=True, text=True, encoding="utf-8")
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip() or f"gh api {path} failed")
    return json.loads(done.stdout)


def runs_of(commit: str) -> list[dict]:
    runs = gh_api(f"repos/{{owner}}/{{repo}}/actions/runs?head_sha={commit}&per_page=20")["workflow_runs"]
    return [run for run in runs if run.get("path", "").startswith(".github/workflows/")]  # not GitHub's own runs


def jobs_of(run_id: int) -> list[dict]:
    return gh_api(f"repos/{{owner}}/{{repo}}/actions/runs/{run_id}/jobs?per_page=50")["jobs"]


def history_of(workflow_id: int) -> dict[str, float]:
    runs = gh_api(f"repos/{{owner}}/{{repo}}/actions/workflows/{workflow_id}/runs?status=success&event=push&per_page={HISTORY_RUNS}")
    with ThreadPoolExecutor(HISTORY_RUNS) as pool:
        return typical_seconds(list(pool.map(jobs_of, [run["id"] for run in runs["workflow_runs"]])))


def main() -> int:
    if os.name == "nt":
        os.system("")  # lets older Windows consoles understand the codes that redraw the lines
    target = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    commit = subprocess.run(["git", "rev-parse", target], capture_output=True, text=True, check=True).stdout.strip()
    print(f"Pipeline runs of {commit[:7]} (Ctrl+C stops watching, not the runs)")

    deadline = time.monotonic() + APPEAR_SECONDS
    while not (runs := runs_of(commit)):
        if time.monotonic() > deadline:
            print("No run started for this commit (no workflow watches the files it changes).")
            return 0
        time.sleep(POLL_SECONDS)
    time.sleep(POLL_SECONDS)  # several workflows can start for one push: give the others a moment
    runs = runs_of(commit)
    for run in runs:
        print(f"  {run['name']}: {run['html_url']}")

    typical = {run["workflow_id"]: history_of(run["workflow_id"]) for run in runs}
    shown = 0
    while True:
        try:
            runs = runs_of(commit)
            lines = [line(run, jobs_of(run["id"]), typical.get(run["workflow_id"], {}), datetime.now(timezone.utc)) for run in runs]
        except RuntimeError as error:  # the network or GitHub for a moment: try again at the next round
            lines = [f"(no answer from GitHub: {str(error)[:80]})"]
        if shown:
            sys.stdout.write(f"\x1b[{shown}F")  # back to the first line of the last round, to draw over it
        for text in lines:
            sys.stdout.write("\x1b[2K" + text + "\n")
        sys.stdout.flush()
        shown = len(lines)
        if runs and all(run["status"] == "completed" for run in runs) and not lines[0].startswith("(no answer"):
            return 0 if all(run.get("conclusion") == "success" for run in runs) else 1
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped watching; the runs go on.")
        sys.exit(130)
