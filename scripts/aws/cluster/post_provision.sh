#!/usr/bin/env bash
set -euo pipefail

INFRA="/app/output/${CLUSTER_NAME}-infra.json"
KEY_FILE="/tmp/k3s-key.pem"
KUBECONFIG_FILE="/app/output/${CLUSTER_NAME}-kubeconfig.yaml"
OUTPUT_FILE="/app/output/${CLUSTER_NAME}.json"
LONGHORN_VERSION="${LONGHORN_VERSION:-1.7.2}"

# ── Extract infra outputs ─────────────────────────────────────────────────────

SERVER_IP=$(jq -r '.server_public_ips[0]' "$INFRA")
SERVER_DNS=$(jq -r '.server_public_dns[0] // empty' "$INFRA")

if [ "${USE_PUBLIC_DNS:-false}" = "true" ] && [ -n "$SERVER_DNS" ]; then
    SERVER_ADDR="$SERVER_DNS"
else
    SERVER_ADDR="$SERVER_IP"
fi
SSH_KEY=$(jq -r '.ssh_private_key' "$INFRA")
BACKUP_BUCKET=$(jq -r '.backup_bucket' "$INFRA")
BACKUP_ACCESS_KEY=$(jq -r '.backup_access_key' "$INFRA")
BACKUP_SECRET_KEY=$(jq -r '.backup_secret_key' "$INFRA")

echo "$SSH_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
install -m 600 "$KEY_FILE" "/app/output/${CLUSTER_NAME}-ssh.pem"

SSH="ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@${SERVER_IP}"

# ── Wait for SSH ──────────────────────────────────────────────────────────────

echo "Waiting for SSH on ${SERVER_IP}..."
MAX_WAIT=300
ELAPSED=0
until $SSH "echo ok" &>/dev/null; do
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    [ $ELAPSED -lt $MAX_WAIT ] || { echo "Timeout waiting for SSH"; exit 1; }
done

# ── Wait for k3s ──────────────────────────────────────────────────────────────

echo "Waiting for k3s to be ready..."
ELAPSED=0
until $SSH "sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q Ready"; do
    sleep 15
    ELAPSED=$((ELAPSED + 15))
    [ $ELAPSED -lt 600 ] || { echo "Timeout waiting for k3s"; exit 1; }
done

# ── Kubeconfig ────────────────────────────────────────────────────────────────

echo "Retrieving kubeconfig..."
$SSH "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s/127.0.0.1/${SERVER_ADDR}/g" \
    > "$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

# ── Longhorn ──────────────────────────────────────────────────────────────────

TOTAL_NODES=$((DEFAULT_NODE_COUNT + GPU_NODE_COUNT))
REPLICA_COUNT=1
[ "$TOTAL_NODES" -ge 3 ] && REPLICA_COUNT=3

echo "Installing Longhorn ${LONGHORN_VERSION} (replicas: ${REPLICA_COUNT})..."
helm repo add longhorn https://charts.longhorn.io
helm repo update

helm install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --version "${LONGHORN_VERSION}" \
    --set defaultSettings.defaultReplicaCount="${REPLICA_COUNT}" \
    --wait --timeout 10m

kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
    --ignore-not-found

kubectl apply -f /app/manifests/longhorn/longhorn-storage-class.yaml

# ── Longhorn backup target (AWS S3) ───────────────────────────────────────────

echo "Configuring Longhorn backup target..."
kubectl create secret generic longhorn-backup-secret \
    -n longhorn-system \
    --from-literal=AWS_ACCESS_KEY_ID="${BACKUP_ACCESS_KEY}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${BACKUP_SECRET_KEY}"

kubectl -n longhorn-system patch settings.longhorn.io backup-target \
    --type=merge -p "{\"value\":\"s3://${BACKUP_BUCKET}@${REGION}/\"}"

kubectl -n longhorn-system patch settings.longhorn.io backup-target-credential-secret \
    --type=merge -p '{"value":"longhorn-backup-secret"}'

# ── Write final output JSON ───────────────────────────────────────────────────

echo "Writing output artifact..."
PROVISIONED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
KUBECONFIG_CONTENT=$(cat "$KUBECONFIG_FILE")
SERVER_IPS=$(jq '.server_public_ips' "$INFRA")
GPU_IPS=$(jq '.gpu_public_ips' "$INFRA")

jq -n \
    --arg  schema_version    "1" \
    --arg  cluster_name      "${CLUSTER_NAME}" \
    --arg  provider          "aws" \
    --arg  region            "${REGION}" \
    --arg  api_endpoint      "https://${SERVER_ADDR}:6443" \
    --arg  kubeconfig        "${KUBECONFIG_CONTENT}" \
    --argjson server_ips     "${SERVER_IPS}" \
    --argjson gpu_ips        "${GPU_IPS}" \
    --argjson default_nodes  "${DEFAULT_NODE_COUNT}" \
    --argjson gpu_nodes      "${GPU_NODE_COUNT}" \
    --argjson port           "${PORT}" \
    --arg  k3s_version       "${K3S_VERSION:-v1.31.4+k3s1}" \
    --arg  longhorn_version  "${LONGHORN_VERSION}" \
    --arg  provisioned_at    "${PROVISIONED_AT}" \
    --arg  backup_bucket     "${BACKUP_BUCKET}" \
    --arg  backup_endpoint   "" \
    --arg  backup_access_key "${BACKUP_ACCESS_KEY}" \
    --arg  backup_secret_key "${BACKUP_SECRET_KEY}" \
    '{
        schema_version:    $schema_version,
        cluster_name:      $cluster_name,
        provider:          $provider,
        region:            $region,
        api_endpoint:      $api_endpoint,
        kubeconfig:        $kubeconfig,
        server_public_ips: $server_ips,
        gpu_public_ips:    $gpu_ips,
        default_node_count: $default_nodes,
        gpu_node_count:    $gpu_nodes,
        port:              $port,
        k3s_version:       $k3s_version,
        longhorn_version:  $longhorn_version,
        provisioned_at:    $provisioned_at,
        backup: {
            bucket:     $backup_bucket,
            endpoint:   $backup_endpoint,
            access_key: $backup_access_key,
            secret_key: $backup_secret_key
        }
    }' > "$OUTPUT_FILE"

echo "Cluster ready. Output: ${OUTPUT_FILE}"
