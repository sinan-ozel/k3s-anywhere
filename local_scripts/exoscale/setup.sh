#!/usr/bin/env bash
# First-time setup for Exoscale. Run once with admin credentials.
# Requires: exo CLI authenticated with an org-admin key.
# Reads: EXOSCALE_ZONE (defaults to ch-gva-2), STATE_BUCKET_NAME (defaults to k3s-anywhere-state)
set -euo pipefail

ZONE="${EXOSCALE_ZONE:-ch-gva-2}"
BUCKET="${STATE_BUCKET_NAME:-k3s-anywhere-state}"
ROLE_NAME="k3s-anywhere-provisioner"
KEY_NAME="k3s-anywhere-key"

echo "=== k3s-anywhere first-time setup: Exoscale ==="
echo "Zone:         ${ZONE}"
echo "State bucket: ${BUCKET}"
echo ""

# ── Pulumi state bucket ───────────────────────────────────────────────────────

echo "[1/3] Creating Pulumi state bucket..."
exo storage create "${BUCKET}" --zone "${ZONE}" 2>/dev/null \
    && echo "      Created: ${BUCKET}" \
    || echo "      Already exists: ${BUCKET}"

# ── IAM role ──────────────────────────────────────────────────────────────────

echo "[2/3] Creating least-privilege IAM role..."
exo iam role create "${ROLE_NAME}" \
    --description "k3s-anywhere GitHub Actions provisioner" \
    --policy '{
        "default-service-strategy": "deny",
        "services": {
            "compute": {"type": "allow"},
            "object-storage": {"type": "allow"}
        }
    }' 2>/dev/null \
    && echo "      Created role: ${ROLE_NAME}" \
    || echo "      Role already exists: ${ROLE_NAME}"

# ── API key ───────────────────────────────────────────────────────────────────

echo "[3/3] Creating scoped API key..."
KEY_OUTPUT=$(exo iam api-key create "${KEY_NAME}" --role "${ROLE_NAME}" --output-format json)
API_KEY=$(echo "$KEY_OUTPUT" | jq -r '.key')
API_SECRET=$(echo "$KEY_OUTPUT" | jq -r '.secret')

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Add the following to GitHub Secrets ==="
echo ""
echo "  EXOSCALE_API_KEY     = ${API_KEY}"
echo "  EXOSCALE_API_SECRET  = ${API_SECRET}"
echo "  STATE_BUCKET_NAME    = ${BUCKET}"
echo "  PULUMI_CONFIG_PASSPHRASE = <choose a strong passphrase>"
echo ""
echo "=== Add to your local .env.secrets ==="
echo ""
echo "  EXOSCALE_API_KEY=${API_KEY}"
echo "  EXOSCALE_API_SECRET=${API_SECRET}"
echo "  STATE_BUCKET_NAME=${BUCKET}"
echo "  PULUMI_CONFIG_PASSPHRASE=<same passphrase>"
echo ""
echo "Setup complete."
