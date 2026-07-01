#!/usr/bin/env bash
set -euo pipefail

error() { echo "ERROR: $1" >&2; exit 1; }

[ -n "${GITHUB_TOKEN:-}"  ] || error "GITHUB_TOKEN is not set."
[ -n "${GITHUB_REPO:-}"   ] || error "GITHUB_REPO is not set (e.g. your-org/your-app)."
[ -n "${CLUSTER_NAME:-}"  ] || error "CLUSTER_NAME is not set."

ARTIFACT_NAME="cluster-output-${CLUSTER_NAME}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "=== fetch-cluster-output ==="
echo "Repo:     ${GITHUB_REPO}"
echo "Artifact: ${ARTIFACT_NAME}"
echo ""

# ── Find the most recent non-expired artifact with this name ─────────────────

RESPONSE=$(curl -sf \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPO}/actions/artifacts?name=${ARTIFACT_NAME}&per_page=5")

ARTIFACT=$(echo "${RESPONSE}" | jq -r '
  .artifacts[]
  | select(.expired == false)
  | {url: .archive_download_url, created_at: .created_at}
' | jq -rs 'first // empty')

[ -n "${ARTIFACT}" ] || error \
  "No unexpired artifact named '${ARTIFACT_NAME}' found in ${GITHUB_REPO}. "\
  "Re-run the provision workflow or check CLUSTER_NAME."

ARTIFACT_URL=$(echo "${ARTIFACT}" | jq -r '.url')
CREATED_AT=$(echo "${ARTIFACT}" | jq -r '.created_at')
echo "Found artifact created at ${CREATED_AT}"

# ── Download ──────────────────────────────────────────────────────────────────

echo "Downloading..."
curl -sfL \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  "${ARTIFACT_URL}" -o /tmp/artifact.zip

# ── Extract and optionally decrypt ───────────────────────────────────────────

mkdir -p "${OUTPUT_DIR}"

if unzip -l /tmp/artifact.zip | grep -q "${CLUSTER_NAME}.json.enc"; then
  echo "Artifact is encrypted — decrypting with sops + age..."
  [ -n "${SOPS_AGE_KEY:-}" ] \
    || error "Artifact is encrypted but SOPS_AGE_KEY is not set."
  unzip -p /tmp/artifact.zip "${CLUSTER_NAME}.json.enc" > /tmp/cluster.json.enc
  SOPS_AGE_KEY="${SOPS_AGE_KEY}" sops --decrypt --output-type json \
    /tmp/cluster.json.enc > "${OUTPUT_DIR}/${CLUSTER_NAME}.json"
  rm -f /tmp/cluster.json.enc
elif unzip -l /tmp/artifact.zip | grep -q "${CLUSTER_NAME}.json"; then
  echo "Artifact is plaintext."
  unzip -p /tmp/artifact.zip "${CLUSTER_NAME}.json" > "${OUTPUT_DIR}/${CLUSTER_NAME}.json"
else
  error "Neither ${CLUSTER_NAME}.json nor ${CLUSTER_NAME}.json.enc found in artifact."
fi

rm -f /tmp/artifact.zip

echo ""
echo "Written to ${OUTPUT_DIR}/${CLUSTER_NAME}.json"
echo ""
echo "Quick-start:"
echo "  jq -r '.kubeconfig' ${OUTPUT_DIR}/${CLUSTER_NAME}.json > ~/.kube/${CLUSTER_NAME}.yaml"
echo "  export KUBECONFIG=~/.kube/${CLUSTER_NAME}.yaml"
echo "  kubectl get nodes"
