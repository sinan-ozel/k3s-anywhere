#!/usr/bin/env bash
# First-time setup for Exoscale. Run once with admin credentials, locally:
#
#   docker run --rm \
#     -e ACTION=setup -e PROVIDER=exoscale -e EXOSCALE_ZONE=ch-gva-2 \
#     -e EXOSCALE_API_KEY=<org-admin key> -e EXOSCALE_API_SECRET=<org-admin secret> \
#     sinanozel/k3s-anywhere:latest
#
# Requires: an org-admin API key via EXOSCALE_API_KEY/EXOSCALE_API_SECRET.
# Reads: EXOSCALE_ZONE (defaults to ch-gva-2), STATE_BUCKET_NAME (defaults to k3s-anywhere-state),
#        ROTATE_KEY (set to "true" to replace the provisioner's API key)
#
# Idempotent: rerun after upgrading the image to refresh the provisioner
# role policy. Existing API keys are kept unless ROTATE_KEY=true.
set -euo pipefail

ZONE="${EXOSCALE_ZONE:-ch-gva-2}"
BUCKET="${STATE_BUCKET_NAME:-k3s-anywhere-state}"
ROLE_NAME="k3s-anywhere-provisioner"
KEY_NAME="k3s-anywhere-key"

[ -n "${EXOSCALE_API_KEY:-}" ] && [ -n "${EXOSCALE_API_SECRET:-}" ] \
    || { echo "ERROR: admin credentials not found. Set EXOSCALE_API_KEY / EXOSCALE_API_SECRET to an org-admin key." >&2; exit 1; }

echo "=== k3s-anywhere first-time setup: Exoscale ==="
echo "Zone:         ${ZONE}"
echo "State bucket: ${BUCKET}"
echo ""

ROLE_POLICY='{
    "default-service-strategy": "deny",
    "services": {
        "compute": {"type": "allow"},
        "object-storage": {"type": "allow"}
    }
}'

# ── Pulumi state bucket ───────────────────────────────────────────────────────

echo "[1/3] Creating Pulumi state bucket..."
exo storage create "${BUCKET}" --zone "${ZONE}" 2>/dev/null \
    && echo "      Created: ${BUCKET}" \
    || echo "      Already exists: ${BUCKET}"

# ── IAM role ──────────────────────────────────────────────────────────────────

echo "[2/3] Creating least-privilege IAM role..."
if exo iam role create "${ROLE_NAME}" \
    --description "k3s-anywhere provisioner" \
    --policy "${ROLE_POLICY}" 2>/dev/null; then
    echo "      Created role: ${ROLE_NAME}"
else
    echo "      Role already exists: ${ROLE_NAME}; refreshing policy..."
    exo iam role update "${ROLE_NAME}" --policy "${ROLE_POLICY}" 2>/dev/null \
        && echo "      Policy refreshed." \
        || echo "      WARNING: could not update the role policy automatically." \
                "If this image version added permissions, update role '${ROLE_NAME}' in the Exoscale console."
fi

# ── API key ───────────────────────────────────────────────────────────────────

echo "[3/3] Creating scoped API key..."
EXISTING_KEY=$(exo iam api-key list --output-format json \
    | jq -r --arg name "${KEY_NAME}" '.[] | select(.name == $name) | .key' | head -n1)

if [ -n "${EXISTING_KEY}" ] && [ "${ROTATE_KEY:-false}" != "true" ]; then
    echo "      API key already exists (${EXISTING_KEY}); keeping it."
    echo "      Rerun with ROTATE_KEY=true to issue a new key."
    echo ""
    echo "Setup complete. Existing GitHub Secrets / .env.secrets remain valid."
    exit 0
fi

if [ -n "${EXISTING_KEY}" ]; then
    exo iam api-key delete "${EXISTING_KEY}" --force
    echo "      Rotated out old key: ${EXISTING_KEY}"
fi

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
