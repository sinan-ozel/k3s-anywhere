#!/usr/bin/env bash
# First-time setup for AWS. Run once with admin credentials, locally:
#
#   docker run --rm \
#     -e ACTION=setup -e PROVIDER=aws -e AWS_REGION=us-east-1 \
#     -v ~/.aws:/root/.aws:ro \
#     sinanozel/k3s-anywhere:latest
#
# Requires: admin credentials via mounted ~/.aws or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY.
# Reads: AWS_REGION (defaults to us-east-1), STATE_BUCKET_NAME (defaults to k3s-anywhere-state-<account-id>),
#        ROTATE_KEY (set to "true" to replace the provisioner's access key)
#
# Idempotent: rerun after upgrading the image to refresh the provisioner
# policy. Existing access keys are kept unless ROTATE_KEY=true.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
    || { echo "ERROR: admin credentials not found. Mount ~/.aws or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY." >&2; exit 1; }
BUCKET="${STATE_BUCKET_NAME:-k3s-anywhere-state-${ACCOUNT_ID}}"
USER_NAME="k3s-anywhere-provisioner"
POLICY_NAME="k3s-anywhere-provisioner-policy"

# AWS-managed policies to attach to the provisioner user.
# k3s-on-EC2 requires none. Add ARNs here if future features need them.
# IMPORTANT: If you change this list, update decommission.sh to match — it must
# detach whatever this script attaches.
MANAGED_POLICIES=()

echo "=== k3s-anywhere first-time setup: AWS ==="
echo "Region:       ${REGION}"
echo "Account:      ${ACCOUNT_ID}"
echo "State bucket: ${BUCKET}"
echo ""

# ── Pulumi state bucket ───────────────────────────────────────────────────────

echo "[1/4] Creating Pulumi state bucket..."
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
    echo "      Already exists: ${BUCKET}"
else
    aws s3 mb "s3://${BUCKET}" --region "${REGION}"
    aws s3api put-public-access-block \
        --bucket "${BUCKET}" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    echo "      Created: ${BUCKET}"
fi

# ── IAM user ──────────────────────────────────────────────────────────────────

echo "[2/4] Creating IAM user..."
aws iam create-user --user-name "${USER_NAME}" 2>/dev/null \
    && echo "      Created: ${USER_NAME}" \
    || echo "      Already exists: ${USER_NAME}"

# ── IAM policy ────────────────────────────────────────────────────────────────

echo "[3/4] Attaching least-privilege policy..."

POLICY_DOC=$(sed \
    -e "s|{{ACCOUNT_ID}}|${ACCOUNT_ID}|g" \
    -e "s|{{BUCKET}}|${BUCKET}|g" \
    "${SCRIPT_DIR}/provisioner-policy.json")

aws iam put-user-policy \
    --user-name "${USER_NAME}" \
    --policy-name "${POLICY_NAME}" \
    --policy-document "${POLICY_DOC}"

for POLICY_ARN in "${MANAGED_POLICIES[@]}"; do
    aws iam attach-user-policy --user-name "${USER_NAME}" --policy-arn "${POLICY_ARN}"
    echo "      Attached: ${POLICY_ARN##*/}"
done

echo "      Policy attached."

# ── Access key ────────────────────────────────────────────────────────────────

echo "[4/4] Creating access key..."
EXISTING_KEYS=$(aws iam list-access-keys --user-name "${USER_NAME}" \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text)

if [ -n "${EXISTING_KEYS}" ] && [ "${ROTATE_KEY:-false}" != "true" ]; then
    echo "      Access key already exists (${EXISTING_KEYS}); keeping it."
    echo "      Policy has been refreshed. Rerun with ROTATE_KEY=true to issue a new key."
    echo ""
    echo "Setup complete. Existing GitHub Secrets / .env.secrets remain valid."
    exit 0
fi

if [ -n "${EXISTING_KEYS}" ]; then
    for KEY_ID in ${EXISTING_KEYS}; do
        aws iam delete-access-key --user-name "${USER_NAME}" --access-key-id "${KEY_ID}"
        echo "      Rotated out old key: ${KEY_ID}"
    done
fi

KEY_OUTPUT=$(aws iam create-access-key --user-name "${USER_NAME}")
ACCESS_KEY=$(echo "$KEY_OUTPUT" | jq -r '.AccessKey.AccessKeyId')
SECRET_KEY=$(echo "$KEY_OUTPUT" | jq -r '.AccessKey.SecretAccessKey')

# ── Passphrase ────────────────────────────────────────────────────────────────

PULUMI_CONFIG_PASSPHRASE="${PULUMI_CONFIG_PASSPHRASE:-$(python3 -c "import secrets,re; w=re.findall(r'\b[a-z]{4,7}\b', open('/usr/share/dict/words').read()); print('-'.join(secrets.choice(w) for _ in range(4)))")}"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Add the following to GitHub Secrets ==="
echo "AWS_ACCESS_KEY_ID=${ACCESS_KEY}"
echo "AWS_SECRET_ACCESS_KEY=${SECRET_KEY}"
echo "STATE_BUCKET_NAME=${BUCKET}"
echo "PULUMI_CONFIG_PASSPHRASE=${PULUMI_CONFIG_PASSPHRASE}"
echo "==="
echo ""
echo "Note: AWS_REGION belongs in your provider config file (e.g. configs/aws/my-cluster-us-east-1.env), not in GitHub Secrets."
echo ""
echo "=== Copy into .env.secrets ==="
echo "AWS_ACCESS_KEY_ID=${ACCESS_KEY}"
echo "AWS_SECRET_ACCESS_KEY=${SECRET_KEY}"
echo "STATE_BUCKET_NAME=${BUCKET}"
echo "PULUMI_CONFIG_PASSPHRASE=${PULUMI_CONFIG_PASSPHRASE}"
echo "==="
echo ""
echo "Setup complete."
