"""Settings, read from environment variables."""

import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    db_host: str
    db_password_file: Path
    db_port: int = 5432
    db_name: str = "shop"
    db_user: str = "shop_app"
    db_sslmode: str = "verify-full"  # check the server's certificate and its name
    db_sslrootcert: str = ""
    pool_min: int = 2
    pool_max: int = 10
    pool_timeout: float = 5.0  # seconds a request waits for a free connection
    statement_timeout_ms: int = 30_000
    # A statement is prepared on the server after this many executions; None = never (PREPARE_THRESHOLD=off)
    prepare_threshold: int | None = 5
    version: str = "dev"

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> Settings:
        threshold = env.get("PREPARE_THRESHOLD", "5")
        return cls(
            db_host=env["DB_HOST"],
            db_password_file=Path(env["DB_PASSWORD_FILE"]),
            db_port=int(env.get("DB_PORT", "5432")),
            db_name=env.get("DB_NAME", "shop"),
            db_user=env.get("DB_USER", "shop_app"),
            db_sslmode=env.get("DB_SSLMODE", "verify-full"),
            db_sslrootcert=env.get("DB_SSLROOTCERT", ""),
            pool_min=int(env.get("POOL_MIN", "2")),
            pool_max=int(env.get("POOL_MAX", "10")),
            pool_timeout=float(env.get("POOL_TIMEOUT", "5")),
            statement_timeout_ms=int(env.get("STATEMENT_TIMEOUT_MS", "30000")),
            prepare_threshold=None if threshold == "off" else int(threshold),
            version=env.get("APP_VERSION", "dev"),
        )

    def connection_kwargs(self) -> dict:
        """Read for every new connection, so a changed password is picked up without a restart."""
        kwargs = {
            "host": self.db_host,
            "port": self.db_port,
            "dbname": self.db_name,
            "user": self.db_user,
            "password": self.db_password_file.read_text(encoding="utf-8").strip(),
            "sslmode": self.db_sslmode,
            "connect_timeout": 5,
            "application_name": "shop-app",
            "options": f"-c timezone=UTC -c statement_timeout={self.statement_timeout_ms}"
            " -c idle_in_transaction_session_timeout=30000",
            # Reads need no transaction; writes open one explicitly
            "autocommit": True,
            "prepare_threshold": self.prepare_threshold,
        }
        if self.db_sslrootcert:
            kwargs["sslrootcert"] = self.db_sslrootcert
        return kwargs
