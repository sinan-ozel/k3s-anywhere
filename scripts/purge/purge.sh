#!/usr/bin/env bash
set -euo pipefail

error() { echo "ERROR: $1" >&2; exit 1; }

[ -n "${CLUSTER_NAME:-}" ] || error "CLUSTER_NAME is not set."

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ARTIFACT="${OUTPUT_DIR}/${CLUSTER_NAME}.json"

[ -f "${ARTIFACT}" ] || error \
  "No cluster artifact at ${ARTIFACT}. Run ACTION=fetch (or provision) first" \
  "and mount its output at ${OUTPUT_DIR}."

KUBECONFIG_FILE="/tmp/${CLUSTER_NAME}-kubeconfig.yaml"
jq -r '.kubeconfig' "${ARTIFACT}" > "${KUBECONFIG_FILE}"
export KUBECONFIG="${KUBECONFIG_FILE}"

echo "=== purge: orphaned (Released) PersistentVolumes ==="

# A Released PV has already lost its claim and, by definition, backs no
# running workload — deleting it can never affect anything currently in
# use. But with reclaimPolicy: Retain (Longhorn's default here),
# Kubernetes never automatically deletes it OR its backing volume:
# `kubectl delete pv` on a Retain-policy PV only removes the Kubernetes
# bookkeeping object — it does NOT invoke the CSI driver's delete, so the
# actual Longhorn volume (and the disk space it holds) survives, now
# completely invisible to `kubectl get pv`. The PV's .spec.csi.volumeHandle
# is the Longhorn Volume CR's name, so both must be deleted explicitly to
# actually reclaim disk space.
RELEASED_PVS=$(kubectl get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}')

if [ -z "${RELEASED_PVS}" ]; then
  echo "No orphaned PVs found."
  exit 0
fi

while IFS= read -r PV; do
  [ -n "${PV}" ] || continue
  VOLUME_HANDLE=$(kubectl get pv "${PV}" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true)
  echo "Deleting ${PV} (Longhorn volume: ${VOLUME_HANDLE:-none})..."
  if [ -n "${VOLUME_HANDLE}" ]; then
    kubectl delete volumes.longhorn.io "${VOLUME_HANDLE}" -n longhorn-system --ignore-not-found
  fi
  kubectl delete pv "${PV}" --ignore-not-found
done <<< "${RELEASED_PVS}"

echo "Purge complete."
