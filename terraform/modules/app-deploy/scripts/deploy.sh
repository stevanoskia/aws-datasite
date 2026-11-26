# Runs on the app server through SSM Run Command. The values above this line come from Terraform; ImageTag is the
# only input, and SSM accepts it only as 40 hexadecimal characters (a git commit).
#
# Exit codes, the only thing the pipeline reads:
#    0  deployed and healthy
#   10  the database lacks migrations that this version needs: nothing changed
#   11  the database could not be checked: nothing changed
#   20  the new version was unhealthy; the previous version runs again
#   21  the new version was unhealthy, and no earlier version could be started
# Everything this script prints stays in AWS (SSM command output); it never reaches the pipeline log.
set -euo pipefail
umask 077

tag="{{ ImageTag }}"
image="$REPOSITORY:$tag"

# One deploy at a time
exec 9> "$RUN_DIR/shop-deploy.lock"
flock -w 600 9

registry="${REPOSITORY%%/*}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$registry" > /dev/null
docker pull --quiet "$image" > /dev/null

# The app's password, readable only by root and by the user the container runs as
install -d -m 0750 -o "$APP_UID" -g "$APP_UID" "$STATE"
aws secretsmanager get-secret-value --region "$REGION" --secret-id "$APP_SECRET" --query SecretString --output text \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["password"])' > "$STATE/db-password.new"
chown "$APP_UID:$APP_UID" "$STATE/db-password.new"
chmod 0400 "$STATE/db-password.new"
mv -f "$STATE/db-password.new" "$STATE/db-password"
db_host="$(aws ssm get-parameter --region "$REGION" --name "$DB_ADDRESS_PARAMETER" --query Parameter.Value --output text)"

# Arguments for every container of the app: no rights, no writable disk, the server's credentials out of reach
container_args=(
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --memory 512m --pids-limit 200
  -v "$STATE/db-password:/run/secrets/db-password:ro"
  -e "DB_HOST=$db_host" -e DB_PASSWORD_FILE=/run/secrets/db-password -e DB_SSLROOTCERT=/app/rds-ca.pem
)

# The version must not need migrations that the database doesn't have
if docker run --rm "${container_args[@]}" "$image" python -m shop.schema_check; then
  echo "schema: ok"
else
  code=$?
  echo "schema check: exit $code"
  if [ "$code" -eq 10 ]; then exit 10; fi
  exit 11
fi

start() {
  docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" --restart unless-stopped "${container_args[@]}" \
    -e "APP_VERSION=$2" -p "127.0.0.1:$PORT:8000" "$1" > /dev/null
}

healthy() {
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/health" | grep -qF "\"version\":\"$1\"" \
      && curl -fsS --max-time 10 -o /dev/null "http://127.0.0.1:$PORT/orders?status=pending&limit=1"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

previous="$(cat "$STATE/current" 2> /dev/null || true)"
start "$image" "$tag"
if healthy "$tag"; then
  echo "$tag" > "$STATE/current"
  # Keep the images of this and the previous version, for a quick way back
  docker image ls "$REPOSITORY" --format json \
    | python3 -c 'import json, sys; [print(i["ID"]) for i in map(json.loads, sys.stdin) if i["Tag"] not in sys.argv[1:]]' "$tag" "$previous" \
    | sort -u | xargs -r docker image rm > /dev/null 2>&1 || true
  echo "deployed $tag"
  exit 0
fi

echo "unhealthy: $tag"
docker logs --tail 50 "$CONTAINER" 2>&1 || true
if [ -n "$previous" ] && [ "$previous" != "$tag" ]; then
  start "$REPOSITORY:$previous" "$previous"
  if healthy "$previous"; then
    echo "rolled back to $previous"
    exit 20
  fi
fi
docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
exit 21
