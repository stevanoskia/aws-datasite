#!/usr/bin/env bash
# Runs one of the fixed SSM documents on the app server and waits for it. Used by the pipeline.
#
#   bash scripts/ci_send_command.sh <document> <commit>
#
# Prints only fixed fields: the command ID, the status, the exit code and the duration. What the server prints stays
# in AWS. Exits with the server's exit code, or 2 (not a commit), 3 (server not online), 4 (no result in time).
set -euo pipefail

document="$1"
tag="$2"
target="${APP_SERVER_NAME:-aws-datasite-app}"
timeout="${WAIT_SECONDS:-1500}"

if ! [[ "$tag" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::not a commit (40 hexadecimal characters): refused"
  exit 2
fi

# A stopped server would only time out later: say why right away
online="$(aws ssm describe-instance-information --filters "Key=tag:Name,Values=$target" \
  --query 'length(InstanceInformationList[?PingStatus==`Online`])' --output text)"
if [ "$online" != "1" ]; then
  echo "::error::the app server is not online (it runs on weekdays 07:00-19:00 Berlin time)"
  exit 3
fi

started=$SECONDS
command_id="$(aws ssm send-command --document-name "$document" --targets "Key=tag:Name,Values=$target" \
  --parameters "ImageTag=$tag" --timeout-seconds 120 --query Command.CommandId --output text)"
echo "SSM command $command_id ($document) started"

status=""
instance=""
while :; do
  sleep "${POLL_SECONDS:-5}"
  # Without --details: the list has no output of the server in it
  if line="$(aws ssm list-command-invocations --command-id "$command_id" \
    --query 'CommandInvocations[0].[Status,InstanceId]' --output text)"; then
    read -r status instance <<< "$line"
  fi
  case "$status" in
    "" | None | Pending | InProgress | Delayed | Cancelling) ;;
    *) break ;;
  esac
  if ((SECONDS - started > timeout)); then
    echo "::error::no result after $timeout s (SSM command $command_id)"
    exit 4
  fi
done

# Only the exit code is asked for; the server's output never reaches this log
code="$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance" \
  --query ResponseCode --output text)"
echo "status $status, exit code $code, $((SECONDS - started)) s"
if ! [[ "$code" =~ ^[0-9]+$ ]]; then
  exit 5
fi
exit "$code"
