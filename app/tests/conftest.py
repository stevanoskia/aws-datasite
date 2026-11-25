"""The app runs in a real web server during the tests, so that parallel requests are really parallel."""

import logging
import threading
import time

import httpx
import pytest
import uvicorn

from shop.main import create_app
from shop.settings import Settings

logging.getLogger("httpx").setLevel(logging.WARNING)  # the client's own log, not the app's


class RunningApp:
    def __init__(self, settings: Settings) -> None:
        app = create_app(settings)
        self.server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=0, log_config=None, access_log=False))
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        deadline = time.monotonic() + 20
        while not self.server.started:
            if time.monotonic() > deadline or not self.thread.is_alive():
                raise RuntimeError("the app did not start")
            time.sleep(0.02)
        port = self.server.servers[0].sockets[0].getsockname()[1]
        self.client = httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=60)

    def stop(self) -> None:
        self.client.close()
        self.server.should_exit = True
        self.thread.join(20)


@pytest.fixture(scope="session")
def run_app():
    """Starts an app with the given settings and returns an HTTP client for it."""
    running = []

    def start(settings: Settings) -> httpx.Client:
        app = RunningApp(settings)
        running.append(app)
        return app.client

    yield start
    for app in running:
        app.stop()
