"""Runs the deploy and migrate scripts of terraform/modules/app-deploy as SSM would, with stand-ins for docker, aws and curl."""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
from test_infra_workflow import BASH

MODULE = Path(__file__).resolve().parents[2] / "terraform/modules/app-deploy"
TAG, OLD = "a" * 40, "b" * 40
REPOSITORY = "123456789012.dkr.ecr.eu-north-1.amazonaws.com/test/app"
PASSWORD = "pw-only-for-this-test"

DOCKER = r"""
echo "$*" >> "$FAKE/docker.log"
image="${@: -1}"
case "$1" in
  login | pull | logs) [ -e "$FAKE/registry_down" ] && exit 1; exit 0 ;;
  rm) rm -f "$FAKE/running"; exit 0 ;;
  image)
    if [ "$2" = ls ]; then for t in $(cat "$FAKE/images"); do echo "{\"ID\":\"id-$t\",\"Tag\":\"$t\"}"; done; fi
    if [ "$2" = rm ]; then shift 2; echo "$*" >> "$FAKE/removed"; fi
    exit 0 ;;
  run)
    case "$*" in
      *shop.schema_check*) exit "$(cat "$FAKE/schema_code")" ;;
      *migrate.sh*)
        for argument in "$@"; do
          case "$argument" in *:/run/secrets/pgpass:ro) cp "${argument%:/run/secrets/pgpass:ro}" "$FAKE/passfile_seen" ;; esac
        done
        exit "$(cat "$FAKE/migrate_code")" ;;
      *" -d "*)
        tag="${image##*:}"
        if ! [[ "$tag" =~ ^[0-9a-f]{40}$ ]]; then echo "invalid reference format" >&2; exit 125; fi  # like docker
        echo "$tag" > "$FAKE/running"; exit 0 ;;
    esac ;;
esac
exit 99
"""
# The app as seen through its port. "stale" = an old container still answers; "no_data" = /health works, queries don't
CURL = r"""
running="$(cat "$FAKE/running" 2> /dev/null)" || exit 7
grep -qx "$running" "$FAKE/healthy" || exit 22
answering="$running"
if [ -e "$FAKE/stale" ]; then answering="$(cat "$FAKE/stale")"; fi
case "$*" in
  *"/health"*) echo "{\"status\":\"ok\",\"version\":\"$answering\"}" ;;
  *"/customers/1"*) [ -e "$FAKE/no_data" ] && exit 22; exit 0 ;;
esac
"""
AWS = f"""
case "$*" in
  *get-login-password*) echo token ;;
  *get-secret-value*) [ -e "$FAKE/secret_down" ] && exit 255; echo '{{"username":"x","password":"{PASSWORD}"}}' ;;
  *get-parameter*) echo db.internal.example ;;
  *) exit 99 ;;
esac
"""


def shell_path(path: Path) -> str:
    """C:\\x becomes /c/x: in a PATH the colon of C: would split the entry."""
    return f"/{path.drive[0].lower()}{path.as_posix()[2:]}" if path.drive else path.as_posix()


def settings() -> dict[str, str]:
    """The setting names as Terraform defines them, with values for the test."""
    block = re.search(r"settings = \{(.*?)\n  \}", (MODULE / "main.tf").read_text(), re.DOTALL).group(1)
    names = re.findall(r"^\s+([A-Z_]+)\s+=", block, re.MULTILINE)
    names += re.findall(r"\{ ([A-Z_]+_SECRET) = var", (MODULE / "main.tf").read_text())
    return {name: "" for name in names}


class Server:
    def __init__(self, folder: Path) -> None:
        self.fake, self.bin = folder / "fake", folder / "bin"
        self.state, self.run_dir = folder / "etc/shop", folder / "run"
        for path in (self.fake, self.bin, self.run_dir):
            path.mkdir(parents=True)
        python = sys.executable  # "python3" on Windows can be a shortcut to the Microsoft Store
        programs = {"docker": DOCKER, "curl": CURL, "aws": AWS, "sleep": "", "flock": "", "chown": "",
                    "install": 'mkdir -p "${@: -1}"', "python3": f'"{Path(python).as_posix()}" "$@"'}  # fmt: skip
        for name, body in programs.items():
            (self.bin / name).write_text(f"#!/usr/bin/env bash\n{body}\n", newline="\n")
            (self.bin / name).chmod(0o755)  # Linux runs only executable files (Windows doesn't check)
        self.values = {**settings(), "REPOSITORY": REPOSITORY, "REGION": "eu-north-1", "DB_ADDRESS_PARAMETER": "/test/db/address",
                       "STATE": self.state.as_posix(), "RUN_DIR": self.run_dir.as_posix(), "APP_UID": "10001", "CONTAINER": "test-app",
                       "PORT": "8000", "APP_SECRET": "test/app-db", "MIGRATE_SECRET": "test/migrate-db"}  # fmt: skip
        self.set(schema_code="0", migrate_code="0", healthy=TAG, images=f"{TAG} {OLD} {'c' * 40}")

    def set(self, **files: str) -> None:
        for name, text in files.items():
            (self.fake / name).write_text(text + "\n", newline="\n")

    def deployed_before(self, tag: str) -> None:
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / "current").write_text(tag + "\n")
        self.set(running=tag)

    def run(self, script: str, tag: str = TAG) -> tuple[int, str]:
        text = "\n".join(
            [
                "#!/bin/bash",
                f'PATH="{shell_path(self.bin)}:$PATH"',  # Git Bash on Windows puts its own tools first
                *[f"{name}='{value}'" for name, value in self.values.items()],
                (MODULE / f"scripts/{script}.sh").read_text(),
            ]
        ).replace("{{ ImageTag }}", tag)
        (self.fake / "script.sh").write_text(text, newline="\n")
        env = {**os.environ, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}", "FAKE": self.fake.as_posix()}
        done = subprocess.run([BASH, (self.fake / "script.sh").as_posix()], env=env, capture_output=True, text=True, check=False)
        return done.returncode, done.stdout + done.stderr

    def read(self, name: str) -> str:
        path = self.fake / name
        return path.read_text().strip() if path.exists() else ""

    @property
    def current(self) -> str:
        path = self.state / "current"
        return path.read_text().strip() if path.exists() else ""


@pytest.fixture
def server(tmp_path):
    return Server(tmp_path)


def test_every_setting_the_scripts_use_is_defined_by_terraform():
    defined = set(settings())
    for script in ("deploy", "migrate"):
        used = set(re.findall(r"\$\{?([A-Z][A-Z_]+)", (MODULE / f"scripts/{script}.sh").read_text()))
        assert used <= defined, f"{script}.sh uses undefined settings: {used - defined}"


def test_a_healthy_version_is_deployed(server):
    server.deployed_before(OLD)
    code, output = server.run("deploy")
    assert (code, server.current, server.read("running")) == (0, TAG, TAG)
    assert (server.state / "db-password").read_text().strip() == PASSWORD
    assert PASSWORD not in output
    started = [line for line in server.read("docker.log").splitlines() if line.startswith("run -d")][-1]
    for safe in ("--read-only", "--cap-drop ALL", "--security-opt no-new-privileges", "-p 127.0.0.1:8000:8000", f"APP_VERSION={TAG}"):
        assert safe in started
    assert "--network host" not in server.read("docker.log")  # the container must not reach the server's credentials
    assert server.read("removed") == "id-" + "c" * 40  # only images that are neither current nor previous


@pytest.mark.parametrize("schema, expected", [("10", 10), ("1", 11)])
def test_nothing_changes_when_the_database_is_not_ready(server, schema, expected):
    server.deployed_before(OLD)
    server.set(schema_code=schema)
    code, _ = server.run("deploy")
    assert (code, server.current, server.read("running")) == (expected, OLD, OLD)
    assert "run -d" not in server.read("docker.log")


def test_an_unhealthy_version_is_replaced_by_the_previous_one(server):
    server.deployed_before(OLD)
    server.set(healthy=OLD)
    code, _ = server.run("deploy")
    assert (code, server.current, server.read("running")) == (20, OLD, OLD)


@pytest.mark.parametrize("problem", ["stale", "no_data"])
def test_healthy_means_the_new_version_answers_and_reads_data(server, problem):
    server.deployed_before(OLD)
    server.set(healthy=f"{TAG}\n{OLD}", **{problem: OLD if problem == "stale" else "yes"})
    if problem == "no_data":
        server.set(healthy=TAG)  # the previous version can't read data either: no way back
    code, _ = server.run("deploy")
    assert server.current == OLD and code in (20, 21)


@pytest.mark.parametrize("before", [None, OLD])
def test_without_a_working_version_the_container_is_removed(server, before):
    if before:
        server.deployed_before(before)
    server.set(healthy="nothing")
    code, _ = server.run("deploy")
    assert (code, server.read("running")) == (21, "")
    assert server.current == (before or "")


@pytest.mark.parametrize("failure", ["registry_down", "secret_down"])
def test_a_failure_before_the_start_changes_nothing(server, failure):
    server.deployed_before(OLD)
    server.set(**{failure: "yes"})
    code, _ = server.run("deploy")
    assert code not in (0, 20) and (server.current, server.read("running")) == (OLD, OLD)
    assert "run -d" not in server.read("docker.log")


def test_migrations_run_as_the_migration_login_and_leave_no_password_behind(server):
    code, output = server.run("migrate")
    assert code == 0
    command = [line for line in server.read("docker.log").splitlines() if "migrate.sh" in line][0]
    for part in (f"{REPOSITORY}:migrate-{TAG}", "PGUSER=shop_migrate", "PGSSLMODE=verify-full", "--read-only", "--cap-drop ALL"):
        assert part in command
    assert server.read("passfile_seen") == f"*:*:*:*:{PASSWORD}"
    assert PASSWORD not in output and PASSWORD not in command
    assert list(server.run_dir.glob("shop-migrate.*")) == []


def test_a_failed_migration_is_reported_and_leaves_no_password_behind(server):
    server.set(migrate_code="3")
    code, _ = server.run("migrate")
    assert code == 30 and list(server.run_dir.glob("shop-migrate.*")) == []


