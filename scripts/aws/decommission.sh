#!/usr/bin/env bash
# Purge AWS setup: reverses everything setup.sh created.
# Run locally with admin credentials (requires -it for the confirmation prompt):
#
#   docker run --rm -it \
#     -e ACTION=decommission -e PROVIDER=aws -e AWS_REGION=us-east-1 \
#     -v ~/.aws:/root/.aws:ro \
#     sinanozel/k3s-anywhere:latest
#
# Skip the prompt (e.g. in a script):
#
#   docker run --rm \
#     -e ACTION=decommission -e PROVIDER=aws -e AWS_REGION=us-east-1 \
#     -e FORCE=true \
#     -v ~/.aws:/root/.aws:ro \
#     sinanozel/k3s-anywhere:latest
#
# WARNING: Destroy all clusters first (ACTION=teardown per cluster).
# Deleting the provisioner credentials while clusters are still running
# leaves orphaned infrastructure with no way to clean it up via Pulumi.
#
# IMPORTANT: Keep in sync with setup.sh. Anything setup.sh creates,
# decommission.sh must delete. See the MANAGED_POLICIES array in particular.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
    || { echo "ERROR: admin credentials not found. Mount ~/.aws or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY." >&2; exit 1; }
BUCKET="${STATE_BUCKET_NAME:-k3s-anywhere-state-${ACCOUNT_ID}}"
USER_NAME="k3s-anywhere-provisioner"
POLICY_NAME="k3s-anywhere-provisioner-policy"

# AWS-managed policies attached by setup.sh — must match setup.sh exactly.
MANAGED_POLICIES=()

echo "=== k3s-anywhere decommission: AWS ==="
echo "Region:       ${REGION}"
echo "Account:      ${ACCOUNT_ID}"
echo "IAM user:     ${USER_NAME}"
echo "State bucket: ${BUCKET}"
echo ""

# ── Active-stack check ────────────────────────────────────────────────────────

if aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
    OBJECT_COUNT=$(aws s3api list-objects-v2 --bucket "${BUCKET}" \
        --query 'KeyCount' --output text 2>/dev/null || echo "0")
    OBJECT_COUNT="${OBJECT_COUNT/None/0}"
    if [ "${OBJECT_COUNT}" -gt 0 ]; then
        echo "WARNING: state bucket '${BUCKET}' contains ${OBJECT_COUNT} object(s)."
        echo "         Active Pulumi stacks (live clusters) may still exist."
        echo "         Run ACTION=teardown for each cluster before decommissioning, or"
        echo "         you will lose the ability to manage them via Pulumi."
        echo ""
    fi
fi

# ── Confirmation ──────────────────────────────────────────────────────────────
# Pass CONFIRM=<iam-username> as an env var to confirm without a TTY.
# Pass FORCE=true to skip confirmation entirely (use in scripts).

if [ "${FORCE:-false}" != "true" ]; then
    echo "This will permanently delete:"
    echo "  IAM user    ${USER_NAME} (access keys, inline policy, managed policies)"
    echo "  S3 bucket   s3://${BUCKET} (and all contents)"
    echo ""
    if [ -z "${CONFIRM:-}" ]; then
        printf 'Type "%s" to confirm (or set CONFIRM env var): ' "${USER_NAME}"
        read -r CONFIRM < /dev/tty
    fi
    if [ "${CONFIRM}" != "${USER_NAME}" ]; then
        echo "Aborted."
        exit 1
    fi
    echo ""
fi

# ── IAM user ──────────────────────────────────────────────────────────────────

echo "[1/2] Deleting IAM user ${USER_NAME}..."

if aws iam get-user --user-name "${USER_NAME}" --output text --query 'User.UserName' 2>/dev/null | grep -q .; then
    KEYS=$(aws iam list-access-keys --user-name "${USER_NAME}" \
        --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true)
    for KEY_ID in ${KEYS}; do
        aws iam delete-access-key --user-name "${USER_NAME}" --access-key-id "${KEY_ID}"
        echo "      Deleted access key: ${KEY_ID}"
    done

    for POLICY_ARN in "${MANAGED_POLICIES[@]}"; do
        aws iam detach-user-policy --user-name "${USER_NAME}" \
            --policy-arn "${POLICY_ARN}" 2>/dev/null || true
        echo "      Detached: ${POLICY_ARN##*/}"
    done

    # Delete all inline policies (not just the expected one — names can drift).
    INLINE_POLICIES=$(aws iam list-user-policies --user-name "${USER_NAME}" \
        --query 'PolicyNames[]' --output text 2>/dev/null || true)
    for POL in ${INLINE_POLICIES}; do
        aws iam delete-user-policy --user-name "${USER_NAME}" --policy-name "${POL}"
        echo "      Deleted inline policy: ${POL}"
    done

    aws iam delete-user --user-name "${USER_NAME}"
    echo "      Deleted user: ${USER_NAME}"
else
    echo "      User not found (already deleted?)."
fi

# ── Pulumi state bucket ───────────────────────────────────────────────────────

echo "[2/2] Deleting state bucket s3://${BUCKET}..."

if aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
    aws s3 rm "s3://${BUCKET}" --recursive --quiet
    aws s3 rb "s3://${BUCKET}"
    echo "      Deleted: s3://${BUCKET}"
else
    echo "      Bucket not found (already deleted?)."
fi

echo ""
echo "Decommission complete."
