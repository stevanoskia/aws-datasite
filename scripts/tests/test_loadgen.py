"""The traffic generator (loadgen/). What would hurt: background traffic that scans whole tables all day (CPU credits,
disk burst, every measurement disturbed), profiles that are not the mix they claim, or requests the app doesn't have.
k6 itself runs in the loadgen workflow (the laptop has no k6); these checks read the files."""

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = json.loads((ROOT / "loadgen/profiles.json").read_text(encoding="utf-8"))
SCRIPT = (ROOT / "loadgen/shop.js").read_text(encoding="utf-8")
ENDPOINTS, PROFILES = SETTINGS["endpoints"], SETTINGS["profiles"]


def mix(profile: str) -> dict[str, int]:
    value = PROFILES[profile]["mix"]
    return PROFILES[value]["mix"] if isinstance(value, str) else value


def requests_in_script() -> dict[str, tuple[str, str]]:
    """Endpoint name -> (method, path without query, ${...} as {}), from the ENDPOINTS object of shop.js."""
    body = SCRIPT.split("const ENDPOINTS = {\n", 1)[1].split("\n};\n", 1)[0]
    found = {}
    for name, chunk in re.findall(r"^  ([a-z_]+): (.*?)(?=^  [a-z_]+: |\Z)", body, re.MULTILINE | re.DOTALL):
        request = re.search(r"get\([`']([^`']+)|send\('([A-Z]+)', [`']([^`']+)", chunk)
        method, path = ("GET", request.group(1)) if request.group(1) else (request.group(2), request.group(3))
        found[name] = (method, re.sub(r"\$\{[^}]*\}", "{}", path.split("?")[0]))
    return found


def app_routes() -> set[tuple[str, str]]:
    main = (ROOT / "app/shop/main.py").read_text(encoding="utf-8")
    return {(m.upper(), re.sub(r"\{[a-z_]+\}", "{}", p)) for m, p in re.findall(r'@app\.(get|post|put)\("([^"]+)"', main)}


def test_background_traffic_needs_no_full_scan():
    scans = [name for name in mix("background") if ENDPOINTS[name]["cost"] != "cheap"]
    assert not scans, f"background traffic would scan whole tables all day: {scans}"


@pytest.mark.parametrize("profile, reads", [("background", 90), ("read-heavy", 90), ("write-heavy", 30), ("mixed", 60)])
def test_each_profile_is_the_mix_it_claims(profile, reads):
    weights = mix(profile)
    assert sum(weights.values()) == 100
    assert sum(w for name, w in weights.items() if ENDPOINTS[name]["kind"] == "read") == reads


def test_every_profile_has_a_known_shape_and_endpoints():
    for name, profile in PROFILES.items():
        assert profile["shape"] in ("constant", "spike"), name
        assert re.fullmatch(r"\d+(s|m|h)", profile["duration"]), name
        assert profile["rate"] > 0 and set(mix(name)) <= set(ENDPOINTS), name
        assert all(weight > 0 for weight in mix(name).values()), name


def test_the_script_has_a_request_for_every_endpoint_and_no_other():
    assert set(requests_in_script()) == set(ENDPOINTS)


def test_every_request_is_a_route_of_the_app_with_the_right_kind():
    routes = app_routes()
    for name, (method, path) in requests_in_script().items():
        assert (method, path) in routes, f"{name}: the app has no {method} {path}"
        assert (method == "GET") == (ENDPOINTS[name]["kind"] == "read"), f"{name}: a {method} is not a {ENDPOINTS[name]['kind']}"


def test_the_full_data_set_is_assumed_unless_told_otherwise():
    # The same numbers as gen.init('full') in db/seed/functions.sql: else the picks miss the hot rows
    full = re.search(r"values \(true, 'full', \d+, '[^']+', '([^']+)', \d+, (\d+), (\d+), (\d+),", (ROOT / "db/seed/functions.sql").read_text())
    last, customers, products, orders = full.groups()
    data = SETTINGS["data"]
    assert (data["customers"], data["products"], data["orders"]) == (int(customers), int(products), int(orders))
    assert last.startswith(data["last_day"])


def test_the_workflow_tests_with_the_images_and_flags_of_the_servers():
    workflow = (ROOT / ".github/workflows/loadgen.yml").read_text(encoding="utf-8")
    variables = (ROOT / "terraform/modules/observability/variables.tf").read_text(encoding="utf-8")
    for name, key in (("PROMETHEUS_IMAGE", "prometheus"), ("K6_IMAGE", "k6")):
        tested = re.search(rf"^  {name}: (\S+)$", workflow, re.MULTILINE).group(1)
        used = re.search(rf'^    {key}\s+= "([^"]+)"$', variables, re.MULTILINE).group(1)
        assert tested == used, f"the workflow tests {tested}, the servers run {used}"
    compose = (ROOT / "terraform/modules/observability/files/obs/compose.yaml").read_text(encoding="utf-8")
    for flag in re.findall(r"- (--web\.enable-[a-z-]+)", compose):
        assert flag in workflow, f"Prometheus on the server has {flag}, the workflow's has not"
