"""Starts the app in its container: one process, and only JSON log lines (the web server's own log included)."""

import uvicorn

from .main import create_app


def main() -> None:
    uvicorn.run(
        create_app(),
        host="0.0.0.0",  # noqa: S104 - inside the container; the server publishes the port on 127.0.0.1 only
        port=8000,
        log_config=None,
        access_log=False,
        server_header=False,
        proxy_headers=False,
    )


if __name__ == "__main__":
    main()
