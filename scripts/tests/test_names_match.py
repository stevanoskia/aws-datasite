"""Names that several stacks and pipelines must agree on, and that AWS must accept. Two applies failed on these."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def value(file: str, name: str) -> str:
    return re.search(rf'^\s*{name}\s*=\s*"([^"]+)"', (ROOT / file).read_text(encoding="utf-8"), re.MULTILINE).group(1)


PREFIX = value("terraform/live/30-app/main.tf", "document_prefix")
PARAMETER = re.search(
    r'resource "aws_ssm_parameter" "db_address" \{.*?\n\s*name\s*=\s*"([^"]+)"', (ROOT / "terraform/live/20-data/main.tf").read_text(), re.DOTALL
).group(1)


def test_the_deploy_user_may_run_the_document_that_30_app_makes():
    assert value("terraform/live/00-bootstrap/main.tf", "deploy_document_name") == f"{PREFIX}-deploy"


def test_the_pipelines_run_the_documents_that_30_app_makes():
    used = set(re.findall(r"ci_send_command\.sh (\S+)", "".join(p.read_text() for p in (ROOT / ".github/workflows").glob("*.yml"))))
    assert used == {f"{PREFIX}-deploy", f"{PREFIX}-migrate"}


def test_the_server_reads_the_parameter_that_20_data_makes():
    assert value("terraform/live/30-app/main.tf", "db_address_parameter") == PARAMETER


def test_no_ssm_name_is_reserved_by_aws():
    for name in (PREFIX, PARAMETER.lstrip("/")):
        assert not re.match(r"(aws|amazon|amzn|ssm)", name, re.IGNORECASE), name
