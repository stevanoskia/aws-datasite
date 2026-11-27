"""The progress shown by scripts/watch_runs.py. What would hurt: "done" while a run still goes on (or never stopping),
a wait for an approval counted as work, or a failed run that ends the watch with success."""

import importlib.util
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location("watch_runs", Path(__file__).resolve().parents[1] / "watch_runs.py")
watch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(watch)

NOW = datetime(2026, 11, 27, 12, 0, tzinfo=timezone.utc)


def at(seconds_ago: float) -> str:
    return (NOW - timedelta(seconds=seconds_ago)).isoformat().replace("+00:00", "Z")


def job(name, status="completed", conclusion="success", started=None, took=None, steps=()):
    started_at = at(started) if started is not None else None
    completed_at = at(started - took) if started is not None and took is not None else None
    return {"name": name, "status": status, "conclusion": conclusion if status == "completed" else None,
            "started_at": started_at, "completed_at": completed_at,
            "steps": [{"name": s, "status": "in_progress"} for s in steps]}  # fmt: skip


RUN = {"name": "infra", "status": "in_progress", "run_started_at": at(100), "updated_at": at(0)}
TYPICAL = {"validate": 120.0, "plan": 60.0, "apply (needs approval)": 30.0}


def test_the_usual_time_is_the_median_of_successful_runs():
    history = [
        [job("validate", started=500, took=100), job("plan", started=400, took=60)],
        [job("validate", started=500, took=140), job("plan", conclusion="failure", started=400, took=5)],
        [job("validate", started=500, took=120), job("apply", conclusion="skipped", started=10, took=0)],
    ]
    assert watch.typical_seconds(history) == {"validate": 120.0, "plan": 60.0}


def test_halfway_through_the_first_job():
    jobs = [job("validate", status="in_progress", started=60)]
    percent, left = watch.progress(RUN, jobs, TYPICAL, NOW)
    assert percent == 28 and left == pytest.approx(150)  # 60 of 210 seconds; plan and apply still to come


def test_jobs_not_listed_yet_still_count():
    percent, _ = watch.progress(RUN, [], TYPICAL, NOW)
    assert percent == 0


def test_a_slow_job_never_shows_as_finished():
    jobs = [job("validate", status="in_progress", started=900)]
    percent, left = watch.progress(RUN, jobs, {"validate": 120.0}, NOW)
    assert percent < 100 and left > 0


def test_only_an_ended_run_is_at_100_percent():
    jobs = [job(name, started=300, took=10) for name in TYPICAL]
    assert watch.progress(RUN, jobs, TYPICAL, NOW)[0] == 99  # all jobs done, but GitHub hasn't closed the run yet
    assert watch.progress({**RUN, "status": "completed"}, jobs, TYPICAL, NOW) == (100, 0.0)


def test_waiting_for_an_approval_is_not_counted_as_work():
    run = {**RUN, "status": "waiting"}
    jobs = [job("validate", started=300, took=120), job("plan", started=180, took=60),
            job("apply (needs approval)", status="waiting", started=100)]  # fmt: skip
    first = watch.progress(run, jobs, TYPICAL, NOW)
    later = watch.progress(run, jobs, TYPICAL, NOW + timedelta(minutes=30))
    assert first == later and first[0] == 85  # 180 of 210 seconds
    assert "WAITING FOR YOUR APPROVAL" in watch.line(run, jobs, TYPICAL, NOW)


def test_a_skipped_job_counts_as_done():
    jobs = [job("validate", started=300, took=120), job("plan", started=180, took=60),
            job("apply (needs approval)", conclusion="skipped", started=1, took=0)]  # fmt: skip
    assert watch.progress(RUN, jobs, TYPICAL, NOW)[0] == 99


def test_the_line_shows_the_step_that_runs():
    jobs = [job("validate", status="in_progress", started=60, steps=["All checks"])]
    text = watch.line(RUN, jobs, TYPICAL, NOW)
    assert "validate > All checks" in text and "28%" in text and "1m40s" in text


class GitHub:
    """Answers gh api like GitHub would: the run goes on for `rounds` questions, then ends with `conclusion`."""

    def __init__(self, conclusion: str, rounds: int = 3) -> None:
        self.conclusion, self.rounds, self.asked = conclusion, rounds, 0

    def __call__(self, path: str) -> dict:
        if "head_sha=" in path:
            self.asked += 1
            ended = self.asked > self.rounds
            return {"workflow_runs": [{"id": 7, "workflow_id": 3, "name": "infra", "path": ".github/workflows/infra.yml",
                                       "html_url": "https://github.example/run/7", "run_started_at": at(60), "updated_at": at(0),
                                       "status": "completed" if ended else "in_progress",
                                       "conclusion": self.conclusion if ended else None},
                                      {"id": 8, "workflow_id": 4, "name": "Dependency Graph", "path": "dynamic/x",
                                       "status": "in_progress"}]}  # fmt: skip
        if "/workflows/" in path:
            return {"workflow_runs": [{"id": 1}]}
        return {"jobs": [job("validate", started=50, took=40)]}


@pytest.mark.parametrize("conclusion, code", [("success", 0), ("failure", 1), ("cancelled", 1)])
def test_the_watch_ends_with_the_runs_and_reports_their_result(monkeypatch, capsys, conclusion, code):
    github = GitHub(conclusion)
    monkeypatch.setattr(watch, "gh_api", github)
    monkeypatch.setattr(watch.time, "sleep", lambda _: None)
    monkeypatch.setattr(watch.sys, "argv", ["watch_runs.py", "HEAD"])
    assert watch.main() == code
    shown = capsys.readouterr().out
    assert github.asked == 4  # started, listed, one round in progress, then ended
    assert "99%" in shown  # while it goes on, even with every job done
    assert "Dependency Graph" not in shown  # GitHub's own runs are not part of the pipeline
    assert "100%" in shown and conclusion in shown.splitlines()[-1]


def test_a_commit_without_runs_ends_after_a_while(monkeypatch, capsys):
    clock = iter(range(0, 10_000, 10))
    asked = []

    def no_runs(path: str) -> dict:
        asked.append(path)
        assert len(asked) < 50, "still asking for runs after the waiting time"  # fail, don't hang
        return {"workflow_runs": []}

    monkeypatch.setattr(watch, "gh_api", no_runs)
    monkeypatch.setattr(watch.time, "sleep", lambda _: None)
    monkeypatch.setattr(watch.time, "monotonic", lambda: next(clock))
    monkeypatch.setattr(watch.sys, "argv", ["watch_runs.py", "HEAD"])
    assert watch.main() == 0 and "No run started" in capsys.readouterr().out


def test_a_new_workflow_shows_its_time_but_no_percentage():
    text = watch.line(RUN, [job("validate", status="in_progress", started=60)], {}, NOW)
    assert "--" in text and "%" not in text and "left" not in text and "1m40s" in text


def test_lines_never_wrap_so_the_redraw_stays_in_place(monkeypatch, capsys):
    github = GitHub("success")
    monkeypatch.setattr(watch, "gh_api", github)
    monkeypatch.setattr(watch.time, "sleep", lambda _: None)
    monkeypatch.setattr(watch.sys, "argv", ["watch_runs.py", "HEAD"])
    monkeypatch.setattr(watch.shutil, "get_terminal_size", lambda fallback: watch.os.terminal_size((40, 24)))
    watch.main()
    drawn = re.findall(r"\x1b\[2K([^\n]*)\n", capsys.readouterr().out)
    assert drawn and all(len(text) < 40 for text in drawn)
