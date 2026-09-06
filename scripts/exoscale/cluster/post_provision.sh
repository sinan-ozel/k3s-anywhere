#!/usr/bin/env bash
set -euo pipefail

INFRA="/app/output/${CLUSTER_NAME}-infra.json"
KEY_FILE="/tmp/k3s-key.pem"
KUBECONFIG_FILE="/app/output/${CLUSTER_NAME}-kubeconfig.yaml"
OUTPUT_FILE="/app/output/${CLUSTER_NAME}.json"
LONGHORN_VERSION="${LONGHORN_VERSION:-1.7.2}"

# ── Extract infra outputs ─────────────────────────────────────────────────────

SERVER_IP=$(jq -r '.server_public_ips[0]' "$INFRA")
ELASTIC_IP_ADDR=$(jq -r '.elastic_ip // empty' "$INFRA")
SERVER_ADDR="${ELASTIC_IP_ADDR:-$SERVER_IP}"
SSH_KEY=$(jq -r '.ssh_private_key' "$INFRA")
BACKUP_BUCKET=$(jq -r '.backup_bucket' "$INFRA")
BACKUP_ENDPOINT=$(jq -r '.backup_endpoint' "$INFRA")
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
REPLICA_COUNT=$(( TOTAL_NODES < 3 ? TOTAL_NODES : 3 ))

# defaultSettings.defaultReplicaCount only sets the replica count Longhorn's
# own UI uses when creating a volume by hand — the chart's own values.yaml
# says so directly ("For Kubernetes configuration, modify the
# `numberOfReplicas` field in the StorageClass"). The StorageClass PVCs
# actually bind against (auto-created here via persistence.defaultClass)
# is controlled by persistence.defaultClassReplicaCount instead, which
# defaults to 3 regardless of defaultSettings.defaultReplicaCount. Without
# setting it too, every PVC below a 3-node cluster gets a StorageClass
# asking for more replicas than there are nodes, and Attach never
# succeeds — set both so the actual PVC path is fixed, not just the UI one.
echo "Installing Longhorn ${LONGHORN_VERSION} (replicas: ${REPLICA_COUNT})..."
helm repo add longhorn https://charts.longhorn.io
helm repo update

helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --version "${LONGHORN_VERSION}" \
    --set defaultSettings.defaultReplicaCount="${REPLICA_COUNT}" \
    --set persistence.defaultClassReplicaCount="${REPLICA_COUNT}" \
    --set defaultSettings.staleReplicaTimeout=2880 \
    --set persistence.defaultClass=true \
    --set persistence.reclaimPolicy=Retain \
    --wait --timeout 10m

kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  || true

# ── Longhorn backup target ────────────────────────────────────────────────────

echo "Configuring Longhorn backup target..."
kubectl create secret generic longhorn-backup-secret \
    -n longhorn-system \
    --from-literal=AWS_ACCESS_KEY_ID="${BACKUP_ACCESS_KEY}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${BACKUP_SECRET_KEY}" \
    --from-literal=AWS_ENDPOINTS="${BACKUP_ENDPOINT}" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl -n longhorn-system patch settings.longhorn.io backup-target \
    --type=merge -p "{\"value\":\"s3://${BACKUP_BUCKET}@${REGION}/\"}"

kubectl -n longhorn-system patch settings.longhorn.io backup-target-credential-secret \
    --type=merge -p '{"value":"longhorn-backup-secret"}'

# ── GPU runtime (RuntimeClass + device plugin) ────────────────────────────────
# Only when a GPU node was actually provisioned. Consumers get GPU access
# with nothing to install on their end beyond a normal pod-spec request:
# `resources.limits: {nvidia.com/gpu: 1}` + `runtimeClassName: nvidia`. See
# manifests/nvidia/runtimeclass.yaml for why "nvidia" can't just be the
# containerd default instead.

NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.17.0}"

if [ "${GPU_NODE_COUNT:-0}" -gt 0 ]; then
    echo "Installing nvidia RuntimeClass + device plugin (${NVIDIA_DEVICE_PLUGIN_VERSION})..."
    kubectl apply -f /app/manifests/nvidia/runtimeclass.yaml

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin
  template:
    metadata:
      labels:
        name: nvidia-device-plugin
    spec:
      runtimeClassName: nvidia
      nodeSelector:
        k3s-anywhere.io/gpu-node: "true"
      priorityClassName: system-node-critical
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nvidia-device-plugin
          image: "nvcr.io/nvidia/k8s-device-plugin:${NVIDIA_DEVICE_PLUGIN_VERSION}"
          securityContext:
            privileged: true
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "all"
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
EOF
fi

# ── Write final output JSON ───────────────────────────────────────────────────

echo "Writing output artifact..."
PROVISIONED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
KUBECONFIG_CONTENT=$(cat "$KUBECONFIG_FILE")
SERVER_IPS=$(jq '.server_public_ips' "$INFRA")
GPU_IPS=$(jq '.gpu_public_ips' "$INFRA")
PORTS=$(jq -c '.ports' "$INFRA")
PORT=$(jq -r '.ports[0]' "$INFRA")

jq -n \
    --arg  schema_version    "1" \
    --arg  cluster_name      "${CLUSTER_NAME}" \
    --arg  provider          "exoscale" \
    --arg  region            "${REGION}" \
    --arg  api_endpoint      "https://${SERVER_ADDR}:6443" \
    --arg  kubeconfig        "${KUBECONFIG_CONTENT}" \
    --argjson server_ips     "${SERVER_IPS}" \
    --argjson gpu_ips        "${GPU_IPS}" \
    --argjson default_nodes  "${DEFAULT_NODE_COUNT}" \
    --argjson gpu_nodes      "${GPU_NODE_COUNT}" \
    --argjson port           "${PORT}" \
    --argjson ports          "${PORTS}" \
    --arg  k3s_version       "${K3S_VERSION:-v1.31.4+k3s1}" \
    --arg  longhorn_version  "${LONGHORN_VERSION}" \
    --arg  provisioned_at    "${PROVISIONED_AT}" \
    --arg  backup_bucket              "${BACKUP_BUCKET}" \
    --arg  backup_endpoint            "${BACKUP_ENDPOINT}" \
    --arg  backup_access_key          "${BACKUP_ACCESS_KEY}" \
    --arg  backup_secret_key          "${BACKUP_SECRET_KEY}" \
    --arg  elastic_ip "${ELASTIC_IP_ADDR}" \
    '{
        schema_version:    $schema_version,
        cluster_name:      $cluster_name,
        provider:          $provider,
        region:            $region,
        api_endpoint:      $api_endpoint,
        elastic_ip:        $elastic_ip,
        kubeconfig:        $kubeconfig,
        server_public_ips: $server_ips,
        gpu_public_ips:    $gpu_ips,
        default_node_count: $default_nodes,
        gpu_node_count:    $gpu_nodes,
        port:              $port,
        ports:             $ports,
        k3s_version:       $k3s_version,
        longhorn_version:  $longhorn_version,
        provisioned_at:    $provisioned_at,
        backup: {
            bucket:     $backup_bucket,
            endpoint:   $backup_endpoint,
            access_key: $backup_access_key,
            secret_key: $backup_secret_key
        },
        externaldns: {
            access_key: "",
            secret_key: ""
        }
    }' > "$OUTPUT_FILE"

echo "Cluster ready. Output: ${OUTPUT_FILE}"
