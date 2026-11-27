"""Runs the plan and apply scripts exactly as they are in the infra workflow, with stand-ins for terraform, aws and jq."""

import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/infra.yml").read_text(encoding="utf-8")
GIT_BASH = Path(
    r"C:\Program Files\Git\bin\bash.exe"
)  # plain "bash" can be another program on Windows
BASH = str(GIT_BASH) if GIT_BASH.exists() else shutil.which("bash")

ACCOUNT = "4455" + "66778899"
EMAIL = "somebody" + "@" + "company.example.io"
ADDRESS = "81.2.69.142"
# Not a public-looking address (shared address space of providers): only the exact list catches it
UNUSUAL_ADDRESS = "100.64.12.34"
BUCKET = "my-state-bucket-1a2b3c"

# Prints what the test put into <stack>.txt, and ends with the code in <stack>.code
TERRAFORM = """
case "$*" in *init*) if [ -e "$FAKE/init.txt" ]; then cat "$FAKE/init.txt" >&2; exit 1; fi; exit 0 ;; esac
stack="$(basename "${1#-chdir=}")"
echo "$stack" >> "$FAKE/calls"
cat "$FAKE/$stack.txt"
if [ -e "$FAKE/$stack.err" ]; then cat "$FAKE/$stack.err" >&2; fi
echo "end of $stack"
exit "$(cat "$FAKE/$stack.code")"
"""
JQ = """
import json, sys
assert sys.argv[1:] == ["-r", ".[]"], sys.argv  # the only use of jq that this stand-in knows
for address in json.load(sys.stdin):
    print(address)
"""


def step_script(name: str) -> str:
    step = re.search(
        rf"- name: {re.escape(name)}\n(.*?)(?=\n      - |\n  \w|\Z)", WORKFLOW, re.S
    ).group(1)
    return textwrap.dedent(step.split("run: |\n", 1)[1])


class Pipeline:
    def __init__(self, folder: Path) -> None:
        self.fake, self.work, tools = folder / "fake", folder / "work", folder / "tools"
        for path in (self.fake, tools, self.work / "scripts"):
            path.mkdir(parents=True)
        for stack in ("00-bootstrap", "10-network", "20-data"):
            (self.work / "terraform/live" / stack).mkdir(parents=True)
            self.stack(stack, "No changes.", 0)
        for name in ("safe_log.py", "ci_private_values.sh"):
            shutil.copy(ROOT / "scripts" / name, self.work / "scripts" / name)
        (tools / "jq.py").write_text(JQ)
        python = Path(sys.executable).as_posix()
        programs = {
            "terraform": TERRAFORM,
            "aws": f"echo {ACCOUNT}",
            "jq": f'"{python}" "{(tools / "jq.py").as_posix()}" "$@"',
            "python3": f'"{python}" "$@"',
        }
        for program, script in programs.items():
            (tools / program).write_text(
                "#!/usr/bin/env bash\n" + script + "\n", newline="\n"
            )
            (tools / program).chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
            "FAKE": self.fake.as_posix(),
            "GITHUB_WORKSPACE": self.work.as_posix(),
            "GITHUB_OUTPUT": (self.fake / "output").as_posix(),
            "GITHUB_STEP_SUMMARY": (self.fake / "summary").as_posix(),
            "AWS_REGION": "eu-north-1",
            "TF_STATE_BUCKET": BUCKET,
            "OPERATOR_ALLOWED_CIDRS": json.dumps(
                [f"{ADDRESS}/32", f"{UNUSUAL_ADDRESS}/32"]
            ),
            "CHANGED": "10-network 20-data",
        }

    def stack(self, name: str, output: str, code: int) -> None:
        (self.fake / f"{name}.txt").write_text(output + "\n", newline="\n")
        (self.fake / f"{name}.code").write_text(str(code))

    def run(self, step: str) -> tuple[int, str]:
        (self.work / "step.sh").write_text(step_script(step), newline="\n")
        done = subprocess.run(
            [BASH, "--noprofile", "--norc", "-eo", "pipefail", "step.sh"],
            cwd=self.work,
            env=self.env,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        shown = done.stdout + done.stderr
        # GitHub turns these commands into masks and doesn't show them
        return done.returncode, "\n".join(
            line for line in shown.splitlines() if not line.startswith("::add-mask::")
        )

    def text(self, name: str) -> str:
        path = self.fake / name
        return path.read_text() if path.exists() else ""


PLAN, APPLY = "Plan every stack", "Apply the reviewed plans (in stack order)"


@pytest.fixture
def pipeline(tmp_path):
    return Pipeline(tmp_path)


def test_a_clean_plan_is_shown_and_handed_on(pipeline):
    pipeline.stack(
        "20-data",
        f"  # thing will be created\n  id = arn:aws:iam::{ACCOUNT}:x {BUCKET}\nPlan: 1 to add",
        2,
    )
    code, shown = pipeline.run(PLAN)
    assert (code, pipeline.text("output")) == (0, "changed=20-data\n")
    assert "id = arn:aws:iam::***:x ***" in shown
    assert ACCOUNT not in shown and BUCKET not in shown
    assert "00-bootstrap" not in pipeline.text("calls")
    assert "Plan: 1 to add" in pipeline.text("summary")


def test_a_change_of_hidden_outputs_is_not_called_no_changes(pipeline):
    pipeline.stack(
        "20-data", "No changes. Your infrastructure matches the configuration.", 2
    )
    code, shown = pipeline.run(PLAN)
    assert (code, pipeline.text("output")) == (0, "changed=20-data\n")
    summary = pipeline.text("summary").split("### 20-data\n")[1]
    assert summary.startswith("Changes to outputs only") and "No changes" not in summary
    assert (
        "No changes" in pipeline.text("summary").split("### 20-data")[0]
    )  # the stacks without changes still say so


@pytest.mark.parametrize(
    "private", [EMAIL, ADDRESS, UNUSUAL_ADDRESS, f"{UNUSUAL_ADDRESS}/32", "8.8.8.8"]
)
def test_a_plan_with_private_data_fails_before_anything_can_be_applied(
    pipeline, private
):
    pipeline.stack("10-network", f"  # {private} will be created\nPlan: 1 to add", 2)
    code, shown = pipeline.run(PLAN)
    assert code == 1 and "private data in the plan of: 10-network" in shown
    assert "changed=" not in pipeline.text("output")
    assert private not in shown and private not in pipeline.text("summary")
    assert "end of 20-data" in shown  # the other plans are still checked and shown


def test_a_failing_plan_is_filtered_too(pipeline):
    pipeline.stack("10-network", f"Error: {EMAIL}", 1)
    code, shown = pipeline.run(PLAN)
    assert code == 1 and EMAIL not in shown and "plan failed for 10-network" in shown


@pytest.mark.parametrize("step", [PLAN, APPLY])
def test_a_failing_init_is_filtered_too(pipeline, step):
    (pipeline.fake / "init.txt").write_text(
        f"Error: {EMAIL}\nno such bucket {BUCKET}\n"
    )
    code, shown = pipeline.run(step)
    assert code != 0 and "no such bucket ***" in shown
    assert EMAIL not in shown and BUCKET not in shown


def test_a_clean_apply(pipeline):
    code, shown = pipeline.run(APPLY)
    assert (code, pipeline.text("calls")) == (0, "10-network\n20-data\n")
    assert "20-data: applied" in pipeline.text("summary")


@pytest.mark.parametrize("where", ["output", "errors"])
def test_an_apply_with_private_data_finishes_and_then_fails(pipeline, where):
    if where == "output":
        pipeline.stack("10-network", f"db_address = {UNUSUAL_ADDRESS}", 0)
    else:
        (pipeline.fake / "10-network.err").write_text(f"Warning: {EMAIL}\n")
    code, shown = pipeline.run(APPLY)
    assert code == 1 and "private data in the output of: 10-network" in shown
    assert UNUSUAL_ADDRESS not in shown and EMAIL not in shown
    assert (
        "end of 10-network" in shown and "end of 20-data" in shown
    )  # not stopped halfway
    assert pipeline.text("summary").count("applied") == 2


def test_a_failing_apply_stops_the_next_stack(pipeline):
    pipeline.stack("10-network", "Error: something", 1)
    code, shown = pipeline.run(APPLY)
    assert (code, pipeline.text("calls")) == (1, "10-network\n")
    assert "applied" not in pipeline.text("summary")


@pytest.mark.parametrize("step", [PLAN, APPLY])
@pytest.mark.parametrize("missing", ["TF_STATE_BUCKET", "OPERATOR_ALLOWED_CIDRS"])
def test_without_its_private_values_the_filter_does_not_run(pipeline, step, missing):
    pipeline.env[missing] = "[]" if missing == "OPERATOR_ALLOWED_CIDRS" else ""
    code, _ = pipeline.run(step)
    assert code != 0 and pipeline.text("calls") == ""


def test_every_address_becomes_a_mask_of_its_own(pipeline):
    (pipeline.work / "step.sh").write_text(step_script(PLAN), newline="\n")
    done = subprocess.run(
        [BASH, "step.sh"],
        cwd=pipeline.work,
        env=pipeline.env,
        capture_output=True,
        text=True,
    )
    masks = {
        f"::add-mask::{a}"
        for a in (ADDRESS, f"{ADDRESS}/32", UNUSUAL_ADDRESS, f"{UNUSUAL_ADDRESS}/32")
    }
    assert masks <= set(done.stdout.splitlines())


SCOPE = "Does the push need a plan?"


class History:
    """A repository with one earlier push, and the decision step run on the next one."""

    def __init__(self, folder: Path) -> None:
        self.repo, self.output = folder / "repo", folder / "output"
        self.repo.mkdir()
        self.git("init", "-q")
        self.change("README.md")
        self.before = self.git("rev-parse", "HEAD")

    def git(self, *args: str) -> str:
        done = subprocess.run(
            ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", *args],
            cwd=self.repo, capture_output=True, text=True, check=True,
        )  # fmt: skip
        return done.stdout.strip()

    def change(self, *paths: str) -> None:
        for path in paths:
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            with open(self.repo / path, "a", encoding="utf-8") as file:
                file.write("x\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")

    def plan(self, event: str = "push", before: str | None = None) -> str:
        (self.repo.parent / "step.sh").write_text(step_script(SCOPE), newline="\n")
        env = {**os.environ, "EVENT": event, "BEFORE": self.before if before is None else before,
               "GITHUB_SHA": self.git("rev-parse", "HEAD"), "GITHUB_OUTPUT": self.output.as_posix(),
               "GITHUB_STEP_SUMMARY": (self.repo.parent / "summary").as_posix()}  # fmt: skip
        subprocess.run([BASH, "--noprofile", "--norc", "-eo", "pipefail", "../step.sh"], cwd=self.repo, env=env, check=True)
        return self.output.read_text().strip()


@pytest.mark.parametrize(
    "paths, expected",
    [
        (["scripts/tunnel.ps1"], "plan=false"),
        (["scripts/tests/test_x.py", "docs/adr/x.md"], "plan=false"),
        ([".github/workflows/app.yml"], "plan=false"),
        (["terraform/modules/network/tests/network.tftest.hcl"], "plan=false"),
        (["terraform/modules/network/main.tf"], "plan=true"),
        (["terraform/live/20-data/main.tf"], "plan=true"),
        (["terraform/modules/observability/files/app/config.alloy"], "plan=true"),
        (["scripts/tunnel.ps1", "terraform/live/30-app/variables.tf"], "plan=true"),
        ([".github/workflows/infra.yml"], "plan=true"),
        (["scripts/safe_log.py"], "plan=true"),
        (["scripts/ci_private_values.sh"], "plan=true"),
    ],
)
def test_only_changes_that_terraform_reads_are_planned(tmp_path, paths, expected):
    history = History(tmp_path)
    history.change(*paths)
    assert history.plan() == expected


@pytest.mark.parametrize(
    "event, before",
    [
        ("workflow_dispatch", None),  # by hand
        ("push", "0" * 40),  # a new branch: GitHub sends zeros
        ("push", "1" * 40),  # a commit that the checkout does not have
        ("push", ""),
    ],
)
def test_a_run_by_hand_or_without_a_known_start_is_planned(tmp_path, event, before):
    history = History(tmp_path)
    history.change("scripts/tunnel.ps1")
    assert history.plan(event, before) == "plan=true"


def test_plan_and_apply_wait_for_the_decision():
    plan_job = re.search(r"\n  plan:\n(.*?)\n  apply:\n", WORKFLOW, re.S).group(1)
    assert "needs: validate\n    if: needs.validate.outputs.plan == 'true'\n" in plan_job
    assert "plan: ${{ steps.scope.outputs.plan }}" in WORKFLOW and "id: scope" in WORKFLOW
    assert "fetch-depth: 0" in WORKFLOW.split("\n  plan:\n")[0]  # without history, every push would look unknown
    assert "needs: plan\n" in WORKFLOW.split("\n  apply:\n")[1]  # a skipped plan skips the apply


def test_every_script_of_plan_and_apply_counts_as_a_change():
    wanted = re.search(r"wanted=\((.*)\)", step_script(SCOPE)).group(1).split()
    used = set(re.findall(r"scripts/[a-z_]+\.[a-z]+", step_script(PLAN) + step_script(APPLY)))
    assert used and used <= set(wanted)


def test_a_change_to_any_workflow_runs_the_workflow_tests():
    paths = re.search(r"push:\n.*?paths:\n((?:      - .*\n)+)", WORKFLOW, re.S).group(1)
    assert '".github/workflows/**"' in paths and '"scripts/**"' in paths
