# Two images from the repository root, both for the ARM app server:
#   --target app      the shop's API
#   --target migrate  psql with the migrations, run once per version by the pipeline's migrate step
# Base images are pinned by digest and the database's certificates by checksum: the same file always builds the same thing.

# --- The app ------------------------------------------------------------------------------
FROM python:3.14-slim@sha256:22eafb370920ad8b429e0aec3fff433e0669968519f5d60469d83729c138b28b AS app

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app

COPY app/requirements.txt ./
RUN pip install --no-cache-dir --require-hashes -r requirements.txt

# The certificate authorities of the database's region: the app checks who it talks to (sslmode=verify-full)
ADD --checksum=sha256:8d8dc42958c7b9351846609d552b4b38f3b19c92c9d4816b2f814fd148fe18be \
    https://truststore.pki.rds.amazonaws.com/eu-north-1/eu-north-1-bundle.pem /app/rds-ca.pem
COPY db/migrations /app/migrations
COPY app/shop /app/shop

# An ordinary user, number 10001: the deploy script gives the password file to exactly this user
RUN chmod 0644 /app/rds-ca.pem \
 && useradd --uid 10001 --user-group --no-create-home --shell /usr/sbin/nologin app
USER 10001
EXPOSE 8000
CMD ["python", "-m", "shop.server_rehearsal_broken"]

# --- The migrations -----------------------------------------------------------------------
FROM postgres:18.6@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42 AS migrate

ADD --checksum=sha256:8d8dc42958c7b9351846609d552b4b38f3b19c92c9d4816b2f814fd148fe18be \
    https://truststore.pki.rds.amazonaws.com/eu-north-1/eu-north-1-bundle.pem /db/rds-ca.pem
COPY db/migrate.sh /db/migrate.sh
COPY db/migrations /db/migrations
RUN chmod 0644 /db/rds-ca.pem
ENTRYPOINT []
CMD ["bash", "/db/migrate.sh", "--status"]
