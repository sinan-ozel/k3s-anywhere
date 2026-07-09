#!/usr/bin/env bash
set -euo pipefail

error() { echo "ERROR: $1" >&2; exit 1; }

# ── Validation ────────────────────────────────────────────────────────────────

[ -n "${ACTION:-}" ] || error "ACTION is not set. Valid: setup | decommission | fetch | provision | teardown | refresh | check | reset"

case "$ACTION" in
  setup|decommission|fetch|provision|teardown|refresh|check|reset) ;;
  *) error "Unknown ACTION '${ACTION}'. Valid: setup | decommission | fetch | provision | teardown | refresh | check | reset" ;;
esac

# ── Provider-agnostic actions ─────────────────────────────────────────────────

if [ "$ACTION" = "fetch" ]; then
  exec "/app/scripts/fetch/fetch.sh"
fi

# ── Provider-specific actions ─────────────────────────────────────────────────

[ -n "${PROVIDER:-}" ] || error "PROVIDER is not set. Valid: exoscale | aws | gcp"

case "$PROVIDER" in
  exoscale|aws|gcp) ;;
  *) error "Unknown PROVIDER '${PROVIDER}'. Valid: exoscale | aws | gcp" ;;
esac

if [ "$ACTION" = "setup" ]; then
  [ -f "/app/scripts/${PROVIDER}/setup.sh" ] \
    || error "First-time setup is not implemented for provider '${PROVIDER}'."
  exec "/app/scripts/${PROVIDER}/setup.sh"
fi

if [ "$ACTION" = "decommission" ]; then
  [ -f "/app/scripts/${PROVIDER}/decommission.sh" ] \
    || error "Decommission is not implemented for provider '${PROVIDER}'."
  exec "/app/scripts/${PROVIDER}/decommission.sh"
fi

[ -n "${CLUSTER_NAME:-}" ] || error "CLUSTER_NAME is not set."
[ -n "${PULUMI_CONFIG_PASSPHRASE:-}" ] || error "PULUMI_CONFIG_PASSPHRASE is not set."

# Strip stray whitespace/newlines — e.g. a pasted GitHub Secret or a
# CRLF-edited .env file — so a hidden trailing \r doesn't make head-bucket
# fail with a confusing "bucket not found" against a bucket that exists.
STATE_BUCKET_NAME="$(printf '%s' "${STATE_BUCKET_NAME:-}" | tr -d '[:space:]')"
[ -n "${STATE_BUCKET_NAME}" ] || error "STATE_BUCKET_NAME is not set."

case "$PROVIDER" in
  exoscale)
    [ -n "${EXOSCALE_API_KEY:-}"    ] || error "EXOSCALE_API_KEY is not set."
    [ -n "${EXOSCALE_API_SECRET:-}" ] || error "EXOSCALE_API_SECRET is not set."
    [ -n "${EXOSCALE_ZONE:-}"       ] || error "EXOSCALE_ZONE is not set."
    ;;
  aws)
    [ -n "${AWS_ACCESS_KEY_ID:-}"     ] || error "AWS_ACCESS_KEY_ID is not set."
    [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || error "AWS_SECRET_ACCESS_KEY is not set."
    [ -n "${AWS_REGION:-}"            ] || error "AWS_REGION is not set."
    ;;
  gcp)
    [ -n "${GCP_SERVICE_ACCOUNT_KEY:-}" ] || error "GCP_SERVICE_ACCOUNT_KEY is not set."
    [ -n "${GCP_REGION:-}"              ] || error "GCP_REGION is not set."
    ;;
esac

[ -n "${DEFAULT_NODE_COUNT:-}" ] || error "DEFAULT_NODE_COUNT is not set."
[ -n "${PORT:-}" ] || [ -n "${PORTS:-}" ] || error "PORT or PORTS is not set."

# ── Normalise region ──────────────────────────────────────────────────────────

case "$PROVIDER" in
  exoscale) export REGION="${EXOSCALE_ZONE}" ;;
  aws)      export REGION="${AWS_REGION}" ;;
  gcp)      export REGION="${GCP_REGION}" ;;
esac

# ── Pulumi state backend ──────────────────────────────────────────────────────

setup_missing() {
  cat >&2 <<EOF
ERROR: Cannot reach Pulumi state bucket '${STATE_BUCKET_NAME}'.

This usually means one of:
  - first-time setup has never been run for this ${PROVIDER} account, or
  - the credentials provided here are not the provisioner credentials
    that setup printed (check your GitHub Secrets / .env.secrets), or
  - STATE_BUCKET_NAME does not match the bucket setup created.

First-time setup runs once per account, locally, with admin credentials
(never in CI):

EOF
  case "$PROVIDER" in
    exoscale)
      cat >&2 <<EOF
  docker run --rm \\
    -e ACTION=setup -e PROVIDER=exoscale -e EXOSCALE_ZONE=${EXOSCALE_ZONE} \\
    -e EXOSCALE_API_KEY=<org-admin key> -e EXOSCALE_API_SECRET=<org-admin secret> \\
    sinanozel/k3s-anywhere:latest
EOF
      ;;
    aws)
      cat >&2 <<EOF
  docker run --rm \\
    -e ACTION=setup -e PROVIDER=aws -e AWS_REGION=${AWS_REGION} \\
    -v ~/.aws:/root/.aws:ro \\
    sinanozel/k3s-anywhere:latest
EOF
      ;;
  esac
  cat >&2 <<EOF

Then add the values it prints to GitHub Secrets and your local .env.secrets.
See https://github.com/sinan-ozel/k3s-anywhere#first-time-setup
EOF
  exit 1
}

case "$PROVIDER" in
  exoscale)
    # Pulumi S3 backend against Exoscale SOS — use Exoscale keys as AWS creds
    export AWS_ACCESS_KEY_ID="${EXOSCALE_API_KEY}"
    export AWS_SECRET_ACCESS_KEY="${EXOSCALE_API_SECRET}"
    BACKEND_URL="s3://${STATE_BUCKET_NAME}?endpoint=https://sos-${EXOSCALE_ZONE}.exo.io&awssdk=v2&region=us-east-1"
    aws s3api head-bucket --bucket "${STATE_BUCKET_NAME}" \
      --endpoint-url "https://sos-${EXOSCALE_ZONE}.exo.io" --region us-east-1 \
      >/dev/null 2>&1 || setup_missing
    ;;
  aws)
    BACKEND_URL="s3://${STATE_BUCKET_NAME}"
    aws s3api head-bucket --bucket "${STATE_BUCKET_NAME}" >/dev/null 2>&1 || setup_missing
    ;;
  gcp)
    BACKEND_URL="gs://${STATE_BUCKET_NAME}"
    ;;
esac

pulumi login "${BACKEND_URL}"

# ── Stack ─────────────────────────────────────────────────────────────────────

cd "/app/pulumi/${PROVIDER}"
pulumi stack init "${CLUSTER_NAME}" --non-interactive 2>/dev/null || true
pulumi stack select "${CLUSTER_NAME}" --non-interactive

# ── Run action ────────────────────────────────────────────────────────────────

case "$ACTION" in
  provision)
    if [ "$PROVIDER" = "aws" ]; then
      # The backup bucket has protect=True so teardown skips it. After a
      # decommission (state wipe) the bucket still exists in S3 but Pulumi has
      # no memory of it. Import it so pulumi up treats it as already managed
      # instead of trying to create it (which would 409).
      _BACKUP_BUCKET="${BUCKET_PREFIX:-}${CLUSTER_NAME}-backups"
      if aws s3api head-bucket --bucket "${_BACKUP_BUCKET}" >/dev/null 2>&1; then
        pulumi import --yes --non-interactive "aws:s3/bucket:Bucket" \
          "${CLUSTER_NAME}-backups" "${_BACKUP_BUCKET}" >/dev/null 2>&1 || true
      fi

      # Delete orphaned key pair left by an interrupted provision; Pulumi will
      # recreate it with a fresh key. Skip if the key pair is already tracked
      # in state (normal re-provision path).
      _KEY_NAME="${CLUSTER_NAME}-key"
      if aws ec2 describe-key-pairs --key-names "${_KEY_NAME}" \
          >/dev/null 2>&1; then
        _STACK_JSON=$(pulumi stack export 2>/dev/null || echo "{}")
        if ! echo "${_STACK_JSON}" | grep -q 'aws:ec2/keyPair:KeyPair'; then
          echo "Removing orphaned key pair ${_KEY_NAME} (will be recreated)..."
          aws ec2 delete-key-pair --key-name "${_KEY_NAME}"
        fi
      fi
    fi
    pulumi up --yes --non-interactive
    pulumi stack output --show-secrets --json > "/app/output/${CLUSTER_NAME}-infra.json"
    "/app/scripts/${PROVIDER}/cluster/post_provision.sh"
    ;;
  teardown)
    if [ -f "/app/output/${CLUSTER_NAME}-kubeconfig.yaml" ]; then
      python "/app/scripts/${PROVIDER}/cluster/teardown_load_balancer.py"
    fi
    # --exclude-protected: without it, destroy fails its preview entirely
    # the moment ANY resource is protect=True (e.g. the backup bucket) —
    # it doesn't just skip that resource, it blocks the whole operation.
    pulumi destroy --yes --non-interactive --exclude-protected

    # After a failed or state-wiped provision some resources can exist in AWS
    # but not in Pulumi state. pulumi destroy skips them. Delete them here so
    # the next provision starts clean. All commands use || true — idempotent.
    if [ "$PROVIDER" = "aws" ]; then
      _BU="${CLUSTER_NAME}-backup"
      # Key pair: regenerated with a fresh SSH key on each provision.
      aws ec2 delete-key-pair --key-name "${CLUSTER_NAME}-key" \
        >/dev/null 2>&1 || true
      # Backup IAM user: recreated by provision; access keys and inline
      # policies must be removed before the user can be deleted.
      for _K in $(aws iam list-access-keys --user-name "${_BU}" \
          --query 'AccessKeyMetadata[].AccessKeyId' \
          --output text 2>/dev/null || true); do
        aws iam delete-access-key --user-name "${_BU}" \
          --access-key-id "${_K}" 2>/dev/null || true
      done
      for _P in $(aws iam list-user-policies --user-name "${_BU}" \
          --query 'PolicyNames[]' --output text 2>/dev/null || true); do
        aws iam delete-user-policy --user-name "${_BU}" \
          --policy-name "${_P}" 2>/dev/null || true
      done
      aws iam delete-user --user-name "${_BU}" 2>/dev/null || true
    fi

    rm -f "/app/output/${CLUSTER_NAME}-infra.json" \
          "/app/output/${CLUSTER_NAME}-kubeconfig.yaml" \
          "/app/output/${CLUSTER_NAME}-ssh.pem"
    ;;
  refresh)
    pulumi refresh --yes --non-interactive
    ;;
  check)
    echo "== Cluster status (stack outputs) =="
    pulumi stack output --json 2>/dev/null || echo "{}"
    echo
    echo "== Checking live infrastructure against configuration (pulumi preview) =="
    pulumi preview --non-interactive --diff
    ;;
  reset)
    pulumi stack rm "${CLUSTER_NAME}" --yes --force --non-interactive || true
    ;;
esac
