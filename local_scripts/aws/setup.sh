#!/usr/bin/env bash
# First-time setup for AWS. Run once with admin credentials.
# Requires: aws CLI authenticated with an IAM admin user/role.
# Reads: AWS_REGION (defaults to us-east-1), STATE_BUCKET_NAME (defaults to k3s-anywhere-state-<account-id>)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${STATE_BUCKET_NAME:-k3s-anywhere-state-${ACCOUNT_ID}}"
USER_NAME="k3s-anywhere-provisioner"
POLICY_NAME="k3s-anywhere-provisioner-policy"

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
POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Statebucket",
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ]
    },
    {
      "Sid": "ClusterBuckets",
      "Effect": "Allow",
      "Action": ["s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketAcl",
                 "s3:PutBucketPublicAccessBlock", "s3:GetBucketLocation",
                 "s3:ListBucket", "s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::*-backups", "arn:aws:s3:::*-backups/*"]
    },
    {
      "Sid": "EC2",
      "Effect": "Allow",
      "Action": [
        "ec2:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMBackupUser",
      "Effect": "Allow",
      "Action": [
        "iam:CreateUser", "iam:DeleteUser",
        "iam:PutUserPolicy", "iam:DeleteUserPolicy",
        "iam:CreateAccessKey", "iam:DeleteAccessKey",
        "iam:GetUser", "iam:GetUserPolicy", "iam:ListAccessKeys"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:user/*-backup"
    }
  ]
}
EOF
)

aws iam put-user-policy \
    --user-name "${USER_NAME}" \
    --policy-name "${POLICY_NAME}" \
    --policy-document "$POLICY_DOC"
echo "      Policy attached."

# ── Access key ────────────────────────────────────────────────────────────────

echo "[4/4] Creating access key..."
KEY_OUTPUT=$(aws iam create-access-key --user-name "${USER_NAME}")
ACCESS_KEY=$(echo "$KEY_OUTPUT" | jq -r '.AccessKey.AccessKeyId')
SECRET_KEY=$(echo "$KEY_OUTPUT" | jq -r '.AccessKey.SecretAccessKey')

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Add the following to GitHub Secrets ==="
echo ""
echo "  AWS_ACCESS_KEY_ID     = ${ACCESS_KEY}"
echo "  AWS_SECRET_ACCESS_KEY = ${SECRET_KEY}"
echo "  AWS_REGION            = ${REGION}"
echo "  STATE_BUCKET_NAME     = ${BUCKET}"
echo "  PULUMI_CONFIG_PASSPHRASE = <choose a strong passphrase>"
echo ""
echo "=== Add to your local .env.secrets ==="
echo ""
echo "  AWS_ACCESS_KEY_ID=${ACCESS_KEY}"
echo "  AWS_SECRET_ACCESS_KEY=${SECRET_KEY}"
echo "  AWS_REGION=${REGION}"
echo "  STATE_BUCKET_NAME=${BUCKET}"
echo "  PULUMI_CONFIG_PASSPHRASE=<same passphrase>"
echo ""
echo "Setup complete."
