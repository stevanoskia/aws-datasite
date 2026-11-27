# Runs on a server through an SSM association, after the lines above have written the files into "$new".
# PROJECT is set above. Everything printed stays in AWS (the association's command output).
export HOME=/root
dir="/opt/datasite/$PROJECT"
trap 'rm -rf "$new"' EXIT

# At the first boot Docker is still being installed: wait for it
for _ in $(seq 1 60); do
  if docker compose version > /dev/null 2>&1 && systemctl is-active --quiet docker; then break; fi
  sleep 5
done
docker compose version > /dev/null

# Readable by the containers' own users, writable by root only
chmod -R u=rwX,go=rX "$new"

# The new files replace the old ones as a whole: no file of an earlier version is left behind
install -d -m 0755 /opt/datasite
rm -rf "$dir.old"
if [ -d "$dir" ]; then mv "$dir" "$dir.old"; fi
mv "$new" "$dir"
trap - EXIT

cd "$dir"
docker compose --project-name "$PROJECT" config --quiet
docker compose --project-name "$PROJECT" pull --quiet
# Recreated, so that changed configuration files are read; the data stays in named volumes
docker compose --project-name "$PROJECT" up --detach --force-recreate --remove-orphans

# Every container must be running after 60 seconds, else the apply fails
sleep 60
# (no Go templates for --format: SSM would read double braces as a document parameter)
states() {
  docker compose --project-name "$PROJECT" ps --all --format json \
    | python3 -c 'import json, sys; [print(c["Service"], c["State"]) for c in map(json.loads, filter(None, sys.stdin.read().splitlines()))]'
}
not_running="$(states | awk '$2 != "running"')"
if [ -n "$not_running" ]; then
  echo "not running: $not_running"
  docker compose --project-name "$PROJECT" logs --tail 30
  exit 1
fi
rm -rf "$dir.old"
echo "$PROJECT running: $(states | awk '{print $1}' | tr '\n' ' ')"
