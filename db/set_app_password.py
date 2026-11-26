"""Gives a login of the pipeline a new random password and stores it in Secrets Manager.
Run it again to change the password.

    python db/set_app_password.py                      the app's login (shop_app)
    python db/set_app_password.py --role shop_migrate  the migration login

The password is never shown and never on a command line, and the database only receives its SCRAM
verifier: a readable password in ALTER ROLE could end up in the server log or in pg_stat_statements.

The connection comes from PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD, PGSSLMODE; AWS from AWS_PROFILE."""
import argparse, base64, hashlib, hmac, json, os, secrets, subprocess, sys, tempfile

# Only these logins, each with its own secret: never the administrator
SECRETS = {"shop_app": "aws-datasite/app-db", "shop_migrate": "aws-datasite/migrate-db"}


def scram_verifier(password, salt, iterations=4096):
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    stored_key = hashlib.sha256(hmac.digest(salted, b"Client Key", "sha256")).digest()
    server_key = hmac.digest(salted, b"Server Key", "sha256")
    salt64, stored64, server64 = (base64.b64encode(x).decode() for x in (salt, stored_key, server_key))
    return f"SCRAM-SHA-256${iterations}:{salt64}${stored64}:{server64}"


def psql(sql, **env):
    return subprocess.run(["psql", "-X", "-q", "-At", "-w", "-v", "ON_ERROR_STOP=1"], input=sql, text=True,
                          capture_output=True, env={**os.environ, **env})


def aws(*arguments):
    return subprocess.run(["aws", "secretsmanager", *arguments], text=True, capture_output=True)


def stop_if_failed(result, message):
    if result.returncode != 0:
        sys.exit(f"ERROR: {message}\n{result.stderr.strip()}")


def main():
    parser = argparse.ArgumentParser(description="Set a new password for a login of the pipeline")
    parser.add_argument("--role", choices=SECRETS, default="shop_app")
    ROLE = parser.parse_args().role
    SECRET = os.environ.get("APP_DB_SECRET", SECRETS[ROLE])

    # Both sides must be ready before anything changes
    found = psql(f"select 1 from pg_roles where rolname = '{ROLE}'")
    stop_if_failed(found, "no connection to the database. Nothing was changed.")
    if found.stdout.strip() != "1":
        sys.exit(f"ERROR: the login {ROLE} does not exist; run db/migrate.sh first. Nothing was changed.")
    stop_if_failed(aws("describe-secret", "--secret-id", SECRET), "the secret cannot be reached. Nothing was changed.")

    password = secrets.token_urlsafe(32)
    verifier = scram_verifier(password, secrets.token_bytes(16))
    stop_if_failed(psql(f"alter role {ROLE} password '{verifier}'"), "the password was not set. Nothing was changed.")

    login = psql("select session_user", PGUSER=ROLE, PGPASSWORD=password)  # current_user can be the role it works as
    stop_if_failed(login, "the new password does not work, and the old one is gone. Run this again.")
    if login.stdout.strip() != ROLE:
        sys.exit("ERROR: connected as somebody else. Run this again.")

    with tempfile.TemporaryDirectory() as folder:  # in the user's own temp folder, deleted right after
        path = os.path.join(folder, "value.json")
        with open(path, "w", encoding="utf-8") as file:
            json.dump({"username": ROLE, "password": password}, file)
        stored = aws("put-secret-value", "--secret-id", SECRET, "--secret-string", f"file://{path}")
    stop_if_failed(stored, "the database has the new password, but it was not stored. Run this again.")
    print(f"{ROLE}: new password set, login tested, stored in {SECRET}")


if __name__ == "__main__":
    main()
