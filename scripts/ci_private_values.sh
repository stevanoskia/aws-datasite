# Sourced by the pipeline (not run): tells scripts/safe_log.py which values are private in this run.
# They stay inside the step: GitHub prints the environment of a step at its beginning.
#
# Needs TF_STATE_BUCKET and OPERATOR_ALLOWED_CIDRS (a JSON list of addresses) from the GitHub secrets.

account="$(aws sts get-caller-identity --query Account --output text)"
ranges="$(jq -r '.[]' <<< "$OPERATOR_ALLOWED_CIDRS" | tr -d '\r')"
addresses="$(for range in $ranges; do echo "$range"; echo "${range%/*}"; done)"
if [ -z "$account" ] || [ -z "$addresses" ] || [ -z "$TF_STATE_BUCKET" ]; then
  echo "::error::the private values for the log filter are missing"
  exit 1
fi

# GitHub hides a secret only as a whole, and this one is a list: every address becomes a mask of its own
while read -r address; do echo "::add-mask::$address"; done <<< "$addresses"

export LOG_REDACT="$account"$'\n'"$TF_STATE_BUCKET"
export LOG_FORBID="$addresses"
