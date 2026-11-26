# Runs on the app server through SSM Run Command, only for the pipeline's apply role (after an approval).
# Applies the migrations of the given version as the migration login, which owns the tables.
#
# Exit codes, the only thing the pipeline reads:
#    0  every migration is applied
#   30  a migration failed (each one runs in a transaction, so a failed one left nothing behind)
# Everything this script prints stays in AWS (SSM command output); it never reaches the pipeline log.
set -euo pipefail
umask 077
export HOME=/root # SSM runs without one; docker login keeps its login there

tag="{{ ImageTag }}"
image="$REPOSITORY:migrate-$tag"

exec 9> "$RUN_DIR/shop-deploy.lock" # never at the same time as a deploy
flock -w 600 9

registry="${REPOSITORY%%/*}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$registry" > /dev/null
docker pull --quiet "$image" > /dev/null

# The password exists only in memory (/run) and only while this runs
passfile="$(mktemp "$RUN_DIR/shop-migrate.XXXXXX")"
trap 'rm -f "$passfile"' EXIT
aws secretsmanager get-secret-value --region "$REGION" --secret-id "$MIGRATE_SECRET" --query SecretString --output text \
  | python3 -c 'import json, sys; print("*:*:*:*:" + json.load(sys.stdin)["password"])' > "$passfile"
db_host="$(aws ssm get-parameter --region "$REGION" --name "$DB_ADDRESS_PARAMETER" --query Parameter.Value --output text)"

if docker run --rm --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --memory 256m \
  -v "$passfile:/run/secrets/pgpass:ro" -e PGPASSFILE=/run/secrets/pgpass \
  -e "PGHOST=$db_host" -e PGDATABASE=shop -e PGUSER=shop_migrate \
  -e PGSSLMODE=verify-full -e PGSSLROOTCERT=/db/rds-ca.pem \
  "$image" bash /db/migrate.sh; then
  echo "migrated to $tag"
  exit 0
fi
echo "migration failed"
exit 30
