"""The container files of the monitoring server and the app server's collector (terraform/modules/observability/files).

What would hurt: a port open beyond the server, a container without memory limit taking the 2 GB server down,
an image that changes under us, or dashboards that query metrics the app does not have.
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / "terraform/modules/observability/files"
OBS = (FILES / "obs/compose.yaml").read_text(encoding="utf-8")
APP = (FILES / "app/compose.yaml").read_text(encoding="utf-8")


def services(compose: str) -> dict[str, str]:
    """Each service's block of text, by name (two-space indented names under 'services:')."""
    body = compose.split("\nservices:\n", 1)[1].split("\nvolumes:\n", 1)[0]
    parts = re.split(r"^  ([a-z0-9-]+):\n", body, flags=re.MULTILINE)
    return dict(zip(parts[1::2], parts[2::2]))


def published_ports(block: str) -> list[str]:
    match = re.search(r"^    ports:\n((?:      - .*\n)+)", block, re.MULTILINE)
    return re.findall(r'- "([^"]+)"', match.group(1)) if match else []


def test_every_container_has_a_memory_limit_and_restarts():
    for compose in (OBS, APP):
        for name, block in services(compose).items():
            assert re.search(r"^    mem_limit: \d+m$", block, re.MULTILINE), f"{name}: no memory limit"
            assert "restart: unless-stopped" in block, f"{name}: does not come back after a restart of the server"


def test_every_image_comes_from_the_pinned_list():
    for compose in (OBS, APP):
        for name, block in services(compose).items():
            assert re.search(r"^    image: \$\{images\.[a-z]+\}$", block, re.MULTILINE), f"{name}: image not from var.images"


def test_only_prometheus_is_reachable_from_other_servers():
    obs = services(OBS)
    assert published_ports(obs["prometheus"]) == ["${prometheus_port}:9090"]
    for name, block in obs.items():
        if name != "prometheus":
            assert all(port.startswith("127.0.0.1:") for port in published_ports(block)), f"{name}: port beyond localhost"


def test_grafana_listens_on_localhost_only():
    assert published_ports(services(OBS)["grafana"]) == ["127.0.0.1:${grafana_port}:3000"]


def test_the_collector_opens_no_port():
    alloy = services(APP)["alloy"]
    assert "ports:" not in alloy
    assert "--server.http.listen-addr=127.0.0.1:" in alloy  # host network: its status page must stay on localhost


def test_prometheus_accepts_remote_write_and_keeps_its_disk_share():
    prometheus = services(OBS)["prometheus"]
    assert "--web.enable-remote-write-receiver" in prometheus  # Alloy and k6 push, nothing is scraped across servers
    assert re.search(r"--storage\.tsdb\.retention\.size=\d+GB", prometheus)


def jobs_that_exist() -> set[str]:
    """Values of the job label that really arrive in Prometheus."""
    jobs = set(re.findall(r"job_name: (\S+)", (FILES / "obs/prometheus.yml").read_text(encoding="utf-8")))
    alloy = (FILES / "app/config.alloy").read_text(encoding="utf-8")
    for block in re.findall(r'^prometheus\.scrape "[^"]+" \{\n(.*?)^\}', alloy, re.MULTILINE | re.DOTALL):
        # An exporter's targets carry their own job label ("integrations/..."): job_name does not replace it
        if "prometheus.exporter." not in block:
            jobs.update(re.findall(r'job_name\s*=\s*"([^"]+)"', block))
    for rule in re.findall(r"rule \{(.*?)\}", alloy, re.DOTALL):
        if re.search(r'target_label\s*=\s*"job"', rule):
            jobs.update(re.findall(r'replacement\s*=\s*"([^"]+)"', rule))
    return jobs


def test_dashboards_filter_only_on_jobs_that_exist():
    jobs = jobs_that_exist()
    for path in (FILES / "obs/grafana").glob("*.json"):
        for panel in json.loads(path.read_text(encoding="utf-8"))["panels"]:
            for target in panel["targets"]:
                for job in re.findall(r'job="([^"]+)"', target["expr"]):
                    assert job in jobs, f"{path.name}, {panel['title']}: no job {job!r} arrives (jobs: {sorted(jobs)})"


def test_dashboards_use_the_provisioned_datasource_and_the_app_s_metrics():
    datasource_uid = re.search(r"^\s*uid: (\S+)$", (FILES / "obs/grafana/datasources.yaml").read_text(), re.MULTILINE).group(1)
    observe = (ROOT / "app/shop/observe.py").read_text(encoding="utf-8")
    defined = set(re.findall(r'(?:Counter|Histogram|Gauge)\(\s*"([a-z_]+)"', observe))
    assert defined, "no metrics found in app/shop/observe.py"

    for path in (FILES / "obs/grafana").glob("*.json"):
        dashboard = json.loads(path.read_text(encoding="utf-8"))
        for panel in dashboard["panels"]:
            assert panel["datasource"]["uid"] == datasource_uid, f"{path.name}: {panel['title']}"
            for target in panel["targets"]:
                for metric in re.findall(r"\b(shop_[a-z_]+)", target["expr"]):
                    base = re.sub(r"_(total|bucket|sum|count)$", "", metric)
                    assert base in defined, f"{path.name}: {metric} is not a metric of the app"
