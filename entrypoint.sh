#!/usr/bin/env bash
set -euo pipefail

error() { echo "ERROR: $1" >&2; exit 1; }

# ── Validation ────────────────────────────────────────────────────────────────

[ -n "${ACTION:-}" ] || error "ACTION is not set. Valid: setup | purge | fetch | provision | teardown | refresh | reset"

case "$ACTION" in
  setup|purge|fetch|provision|teardown|refresh|reset) ;;
  *) error "Unknown ACTION '${ACTION}'. Valid: setup | purge | fetch | provision | teardown | refresh | reset" ;;
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

if [ "$ACTION" = "purge" ]; then
  [ -f "/app/scripts/${PROVIDER}/purge.sh" ] \
    || error "Purge is not implemented for provider '${PROVIDER}'."
  exec "/app/scripts/${PROVIDER}/purge.sh"
fi

[ -n "${CLUSTER_NAME:-}" ] || error "CLUSTER_NAME is not set."
[ -n "${STATE_BUCKET_NAME:-}" ] || error "STATE_BUCKET_NAME is not set."
[ -n "${PULUMI_CONFIG_PASSPHRASE:-}" ] || error "PULUMI_CONFIG_PASSPHRASE is not set."

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
[ -n "${PORT:-}"               ] || error "PORT is not set."

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
    pulumi up --yes --non-interactive
    pulumi stack output --show-secrets --json > "/app/output/${CLUSTER_NAME}-infra.json"
    "/app/scripts/${PROVIDER}/cluster/post_provision.sh"
    ;;
  teardown)
    if [ -f "/app/output/${CLUSTER_NAME}-kubeconfig.yaml" ]; then
      python "/app/scripts/${PROVIDER}/cluster/teardown_load_balancer.py"
    fi
    pulumi destroy --yes --non-interactive
    rm -f "/app/output/${CLUSTER_NAME}-infra.json" \
          "/app/output/${CLUSTER_NAME}-kubeconfig.yaml" \
          "/app/output/${CLUSTER_NAME}-ssh.pem"
    ;;
  refresh)
    pulumi refresh --yes --non-interactive
    ;;
  reset)
    pulumi stack rm "${CLUSTER_NAME}" --yes --force --non-interactive || true
    ;;
esac
