# k3s-anywhere — Design Document

**k3s-anywhere** is a reusable GitHub Actions workflow and container that provisions k3s clusters on any supported cloud provider and hands the caller a working kubeconfig.

Reference from another repo:
```
sinan-ozel/k3s-anywhere/.github/workflows/cluster.yaml@main
```

Container image:
```
sinanozel/k3s-anywhere:latest
```

## Principles

**Opinionated.** Instance types, OS images, k3s version, CNI, and storage layer are fixed per provider. The goal is to make the common case trivially simple, not to make everything possible.

**Simple.** One `.env` file configures a cluster. One `docker run` provisions it. One `docker run` tears it down.

**Reusable.** The same GitHub workflow step can be called from any workflow in the same repo, passing the cluster by name and receiving a kubeconfig in return. No cross-repo IAM sharing, no artifact downloads.

**Containerized.** The container is the provisioner. GitHub Actions runs the same image locally you would run yourself. There is no logic in the runner that is not in the container.

**Cloud-agnostic.** Once provisioned, the kubeconfig works identically regardless of provider. k3s and Longhorn are the abstraction layer: Kubernetes API on top, local disks underneath, no cloud-specific storage drivers exposed to the user.


## What This Provides

A caller (a workflow step, a VS Code task, or a local `docker run`) passes a handful of parameters and receives a working kubeconfig file. The kubeconfig points to the k3s API server on a public IP, with cluster-admin privileges. Longhorn is installed and configured as the default StorageClass. The caller can immediately run `kubectl apply` or `helm install` without any further setup.


## Directory Structure

```
pulumi/
  exoscale/          ← k3s on Exoscale compute (cloud-init based)
  aws/               ← k3s on EC2 (cloud-init based, replaces EKS)
  gcp/               ← k3s on GCE (cloud-init based, planned)

scripts/
  exoscale/
    setup.sh         ← first-time setup: state bucket + least-privilege IAM role
    cluster/
      teardown_load_balancer.py
    volume/
      provision.py
      teardown.py
  aws/
    setup.sh
    cluster/
      teardown_load_balancer.py
    volume/
      provision.py
      teardown.py
  gcp/               ← planned
    cluster/
    volume/

configs/
  my-cluster.env                  ← shared base (cluster_name, node counts, port)
  exoscale/
    my-cluster-ch-gva-2.env       ← zone override
  aws/
    my-cluster-ca-central-1.env   ← region override
  gcp/
    my-cluster-us-central1.env    ← region override (planned)

manifests/
  longhorn/
    longhorn-storage-class.yaml
    longhorn-config.yaml

.github/
  workflows/
    cluster.yaml     ← reusable workflow (workflow_call)
    volume.yaml

Dockerfile           ← the provisioner image
entrypoint.sh        ← dispatches ACTION + PROVIDER

helpers/
  __init__.py        ← shared env parsing utilities
```

The `-k3s` suffix is dropped from all provider names. All implementations use k3s.


## Networking Model

The cluster exposes **one public port** through **one LoadBalancer**. Everything else routes through Ingress.

```
internet
    │
    ▼
  PORT=8888  (the only open port besides 22/SSH and 6443/k8s API)
    │
    ▼
k3s ServiceLB  (built-in, no cloud-managed LB needed)
    │
    ▼
Traefik  (k3s default Ingress controller, already installed)
    │
    ├── /app-a  →  Service A
    ├── /app-b  →  Service B
    └── /app-c  →  Service C
```

k3s ships with both ServiceLB (formerly klipper-lb) and Traefik. Neither requires separate installation or cloud-specific configuration. ServiceLB listens on the single public port; Traefik handles all internal routing via `Ingress` resources. Users deploy services and write `Ingress` rules — they never touch the networking layer below.

**Why this constraint makes the abstraction work:**

A parameter like `PORT=8888` is a complete networking specification. Compare it to the alternative:

```bash
# what you avoid:
INGRESS=true
TLS=true
LB_COUNT=3
SUBNET_PUBLIC=true
SECURITY_GROUP_RULES=80,443,8080-8090
```

Each additional networking parameter is a choice that has to be made consistently across Exoscale, AWS, and GCP — three different load balancer APIs, three different security group models, three different Ingress controller installation paths. The single-port constraint collapses all of that into one firewall rule per provider, identical in intent regardless of where it runs.

The practical implication: if a user needs HTTPS, they terminate TLS at Traefik, not at the cloud load balancer. If they need multiple services on different hostnames, they write `Ingress` rules. The port never changes.


## Parameters

These are the only knobs exposed to the caller. Everything else is fixed.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `cluster_name` | string | yes | Unique identifier; maps to the Pulumi stack name |
| `default_node_count` | int | yes | Number of standard CPU nodes |
| `gpu_node_count` | int | no (default 0) | Number of GPU nodes |
| `port` | int | yes | The single public port; ServiceLB + Traefik route everything through it |
| `region` | string | yes | Provider-specific: zone for Exoscale, region for AWS/GCP |
| `use_public_dns` | bool | no (default `false`) | AWS, Azure: use the cloud-assigned public DNS name as the kubeconfig server address and `api_endpoint`. The TLS certificate always includes both the IP and the DNS name in its SANs, so either works regardless of this flag. Ignored on Exoscale and GCP, which do not assign public DNS names to instances. |

The following are fixed per provider and not configurable:

| Setting | Exoscale | AWS | GCP (planned) |
|---|---|---|---|
| CPU instance | `standard.medium` | `t3.medium` | `e2-standard-2` |
| GPU instance | `gpua30.small` | `g4dn.2xlarge` | `n1-standard-4` + T4 |
| OS image | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| k3s version | pinned (`K3S_VERSION`) | same | same |
| CNI | Flannel (k3s default) | Flannel | Flannel |
| Storage | Longhorn | Longhorn | Longhorn |
| Backup bucket | provisioned alongside cluster | same | same |

The backup bucket is named `<cluster_name>-backups` and is always provisioned. Its name is derived from `cluster_name` — no additional parameter is needed. Credentials are generated by Pulumi and passed to Longhorn automatically; they also appear in the output artifact so the deployer can use them independently (e.g. for `pg_dump` to the same bucket).

The pinned versions live as environment variables in the workflow, so they can be bumped in one place:

```yaml
# .github/workflows/cluster.yaml
env:
  K3S_VERSION: "v1.31.4+k3s1"
  LONGHORN_VERSION: "1.7.2"
```


## Output Contract

Every successful `provision` run writes `output/<cluster_name>.json`. This schema is stable — downstream workflows depend on it and should not need to handle provider-specific variations.

```json
{
  "schema_version": "1",
  "cluster_name": "my-cluster",
  "provider": "exoscale",
  "region": "ch-gva-2",
  "api_endpoint": "https://1.2.3.4:6443",
  "kubeconfig": "apiVersion: v1\nkind: Config\n...",
  "server_public_ips": ["1.2.3.4", "1.2.3.5"],
  "gpu_public_ips": [],
  "default_node_count": 2,
  "gpu_node_count": 0,
  "port": 8888,
  "k3s_version": "v1.31.4+k3s1",
  "longhorn_version": "1.7.2",
  "provisioned_at": "2026-06-04T10:00:00Z",
  "backup": {
    "bucket": "my-cluster-backups",
    "endpoint": "https://sos-ch-gva-2.exo.io",
    "access_key": "EXO...",
    "secret_key": "..."
  }
}
```

### Field definitions

| Field | Type | Notes |
|---|---|---|
| `schema_version` | string | Bumped on breaking changes. Currently `"1"`. |
| `cluster_name` | string | Matches the `CLUSTER_NAME` input. |
| `provider` | string | `exoscale` \| `aws` \| `gcp` |
| `region` | string | Exoscale zone, AWS region, or GCP region. |
| `api_endpoint` | string | `https://<public-ip>:6443`. Usable directly without parsing kubeconfig. |
| `kubeconfig` | string | Raw YAML. Always cluster-admin. Encrypted in Pulumi state via `Output.secret()`; present in plaintext in this output file only. |
| `server_public_ips` | array | Public IPs of all server (control-plane) nodes. |
| `gpu_public_ips` | array | Empty list when `gpu_node_count` is 0. |
| `default_node_count` | int | As provisioned. |
| `gpu_node_count` | int | As provisioned. |
| `port` | int | The single public port configured on the cluster. |
| `k3s_version` | string | Exact k3s version installed. |
| `longhorn_version` | string | Exact Longhorn Helm chart version installed. |
| `provisioned_at` | string | ISO 8601 UTC timestamp of when `pulumi up` completed. |
| `backup.bucket` | string | Bucket name. Always `<cluster_name>-backups`. |
| `backup.endpoint` | string | S3-compatible endpoint URL. Provider-specific. Omitted for AWS S3 (uses default). |
| `backup.access_key` | string | S3 access key with write access to the backup bucket. |
| `backup.secret_key` | string | S3 secret key. Treat as a credential. |

The `backup` object gives the deployer everything needed to write to the same bucket independently — for application-level backups (`pg_dump`, etc.) alongside Longhorn's volume backups, without requiring `kubectl` or access to the Kubernetes secret.

### What is not in this file

The SSH private key used during provisioning is written separately to `output/<cluster_name>-ssh.pem` with mode `0600`. It is not part of the stable contract — it is an operational escape hatch for emergency node access and is not consumed by downstream workflows.

### Consuming the contract

```bash
# Extract kubeconfig
jq -r '.kubeconfig' output/my-cluster.json > ~/.kube/my-cluster.yaml

# Health-check the API endpoint directly
curl -k $(jq -r '.api_endpoint' output/my-cluster.json)/version

# In a GitHub Actions step
- name: Use cluster
  run: |
    jq -r '.kubeconfig' output/${{ env.CLUSTER_NAME }}.json > kubeconfig.yaml
    KUBECONFIG=kubeconfig.yaml kubectl get nodes
```

`schema_version` allows future consumers to assert the version they were written against:

```bash
VERSION=$(jq -r '.schema_version' output/my-cluster.json)
[ "$VERSION" = "1" ] || { echo "Unexpected schema version $VERSION"; exit 1; }
```


## Container Design

The container is the unit of work. The host (runner or local machine) only passes environment variables, mounts two volumes, and handles git after the container exits.

```dockerfile
# Dockerfile
FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    curl openssh-client git jq age \
    && curl -fsSL https://get.helm.sh/helm-v3.17.0-linux-amd64.tar.gz | tar -xz \
    && mv linux-amd64/helm /usr/local/bin/ \
    && curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && chmod +x kubectl && mv kubectl /usr/local/bin/ \
    && curl -fsSL https://get.pulumi.com | sh \
    && curl -Lo /usr/local/bin/sops https://github.com/getsops/sops/releases/latest/download/sops-linux-amd64 \
    && chmod +x /usr/local/bin/sops

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY pulumi/     /app/pulumi/
COPY scripts/    /app/scripts/
COPY manifests/  /app/manifests/
COPY helpers/    /app/helpers/
COPY entrypoint.sh /app/

WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
```

`entrypoint.sh` reads `ACTION` and `PROVIDER`, decrypts the state archive, runs Pulumi, re-encrypts state, and writes outputs to `/app/output/`. The host (runner or local machine) commits the updated archive after the container exits.

```bash
# entrypoint.sh (sketch)
set -euo pipefail

STATE_ARCHIVE=/app/pulumi-state.tar.gz.enc
STATE_DIR=/app/.pulumi-state

# Decrypt state archive if it exists; otherwise start fresh
if [ -f "$STATE_ARCHIVE" ]; then
    sops --input-type binary --output-type binary --decrypt "$STATE_ARCHIVE" \
        | tar -xzf - -C /app
else
    mkdir -p "$STATE_DIR"
fi

pulumi login "file://${STATE_DIR}"
cd /app/pulumi/${PROVIDER}
pulumi stack init ${CLUSTER_NAME} --non-interactive 2>/dev/null || true
pulumi stack select ${CLUSTER_NAME} --non-interactive

case "$ACTION" in
  provision)
    pulumi up --yes --non-interactive
    pulumi stack output --show-secrets --json > /app/output/${CLUSTER_NAME}.json
    /app/scripts/${PROVIDER}/cluster/post_provision.sh
    ;;
  teardown)
    python /app/scripts/${PROVIDER}/cluster/teardown_load_balancer.py
    pulumi destroy --yes --non-interactive
    ;;
  refresh)
    pulumi refresh --yes --non-interactive
    ;;
  reset)
    # Remove only the stack entry from state — does not touch cloud resources
    pulumi stack rm ${CLUSTER_NAME} --yes --non-interactive || true
    ;;
esac

# Re-encrypt state — runs for all actions, including failed ones (always block)
tar -czf - -C /app .pulumi-state/ \
    | sops --input-type binary --output-type binary --encrypt /dev/stdin \
    > "$STATE_ARCHIVE"
```


## Input Validation and Error Handling

`entrypoint.sh` validates all required inputs before touching Pulumi or any cloud API. A missing or empty value exits immediately with a clear message. This runs as the first block in the script, before any state decryption.

```bash
# entrypoint.sh — validation block (runs first)
set -euo pipefail

error() { echo "ERROR: $1" >&2; exit 1; }

# Required for all actions
[ -n "${ACTION:-}"       ] || error "ACTION is not set. Valid values: provision | teardown | refresh | reset"
[ -n "${PROVIDER:-}"     ] || error "PROVIDER is not set. Valid values: exoscale | aws | gcp"
[ -n "${CLUSTER_NAME:-}" ] || error "CLUSTER_NAME is not set. Set it in your .env file."
[ -n "${SOPS_AGE_KEY:-}" ] || error "SOPS_AGE_KEY is not set. This is a secret — add it to .env.secrets or GitHub Secrets."
[ -n "${PULUMI_CONFIG_PASSPHRASE:-}" ] || error "PULUMI_CONFIG_PASSPHRASE is not set. Add it to .env.secrets or GitHub Secrets."

# Validate ACTION value
case "$ACTION" in
  provision|teardown|refresh|reset) ;;
  *) error "Unknown ACTION '${ACTION}'. Valid values: provision | teardown | refresh | reset" ;;
esac

# Validate PROVIDER value
case "$PROVIDER" in
  exoscale|aws|gcp) ;;
  *) error "Unknown PROVIDER '${PROVIDER}'. Valid values: exoscale | aws | gcp" ;;
esac

# Provider-specific required secrets
case "$PROVIDER" in
  exoscale)
    [ -n "${EXOSCALE_API_KEY:-}"    ] || error "EXOSCALE_API_KEY is not set."
    [ -n "${EXOSCALE_API_SECRET:-}" ] || error "EXOSCALE_API_SECRET is not set."
    [ -n "${EXOSCALE_ZONE:-}"       ] || error "EXOSCALE_ZONE is not set. Set it in your provider .env file (e.g. ch-gva-2)."
    ;;
  aws)
    [ -n "${AWS_ACCESS_KEY_ID:-}"     ] || error "AWS_ACCESS_KEY_ID is not set."
    [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || error "AWS_SECRET_ACCESS_KEY is not set."
    [ -n "${AWS_REGION:-}"            ] || error "AWS_REGION is not set. Set it in your provider .env file (e.g. ca-central-1)."
    ;;
  gcp)
    [ -n "${GCP_SERVICE_ACCOUNT_KEY:-}" ] || error "GCP_SERVICE_ACCOUNT_KEY is not set."
    [ -n "${GCP_REGION:-}"              ] || error "GCP_REGION is not set."
    ;;
esac

# Required cluster parameters
[ -n "${DEFAULT_NODE_COUNT:-}" ] || error "DEFAULT_NODE_COUNT is not set. Set it in your .env file."
[ -n "${PORT:-}"               ] || error "PORT is not set. Set it in your .env file."
```

The same validation runs whether the container is invoked locally or from GitHub Actions. A caller who forgets `EXOSCALE_ZONE` sees `ERROR: EXOSCALE_ZONE is not set. Set it in your provider .env file (e.g. ch-gva-2).` immediately, not a cryptic Pulumi or cloud API error several minutes into the run.

The reusable workflow (`cluster.yaml`) performs a parallel check at the workflow level before launching the container, so the error appears in the GitHub Actions UI step summary rather than buried in container logs:

```yaml
- name: Validate inputs
  run: |
    error() { echo "::error::$1"; exit 1; }

    [ -n "${{ inputs.provider }}" ] || error "provider input is required."
    [ -n "${{ inputs.config }}"   ] || error "config input is required."
    [ -n "${{ inputs.action }}"   ] || error "action input is required."

    # Verify the config file exists in the repo
    [ -f "configs/${{ inputs.config }}.env" ] \
      || error "Config file configs/${{ inputs.config }}.env not found in k3s-anywhere."
```


## Local Usage

### `.env` file

```bash
# configs/my-cluster.env
CLUSTER_NAME=my-cluster
PROJECT_NAME=my-cluster
DEFAULT_NODE_COUNT=2
GPU_NODE_COUNT=0
PORT=8888
EXOSCALE_ZONE=ch-gva-2
```

Credentials go in a separate gitignored file:

```bash
# .env.secrets  (gitignored)
EXOSCALE_API_KEY=EXO...
EXOSCALE_API_SECRET=...
PULUMI_CONFIG_PASSPHRASE=...
SOPS_AGE_KEY=AGE-SECRET-KEY-1...   # age private key, generated once per repo
```

### `docker run`

```bash
# Provision
docker run --rm \
  --env-file configs/my-cluster.env \
  --env-file .env.secrets \
  -e ACTION=provision \
  -e PROVIDER=exoscale \
  -v $(pwd)/pulumi-state.tar.gz.enc:/app/pulumi-state.tar.gz.enc \
  -v $(pwd)/output:/app/output \
  ghcr.io/your-org/iac:latest

# Kubeconfig is now at output/my-cluster.json
# Extract it:
jq -r '.kubeconfig' output/my-cluster.json > ~/.kube/my-cluster.yaml
export KUBECONFIG=~/.kube/my-cluster.yaml
kubectl get nodes
```

After the container exits, commit the updated encrypted archive:

```bash
git add pulumi-state.tar.gz.enc
git commit -m "Update Pulumi state after provision"
```

The `.pulumi-state/` directory is a decrypted working copy and is gitignored.

### `tasks.json`

VS Code tasks wire the two steps together with `dependsOn`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Provision cluster",
      "type": "shell",
      "command": "docker run --rm --env-file configs/my-cluster.env --env-file .env.secrets -e ACTION=provision -e PROVIDER=exoscale -v ${workspaceFolder}/pulumi-state.tar.gz.enc:/app/pulumi-state.tar.gz.enc -v ${workspaceFolder}/output:/app/output ghcr.io/your-org/iac:latest"
    },
    {
      "label": "Commit state",
      "type": "shell",
      "command": "git add pulumi-state.tar.gz.enc && git commit -m 'Update Pulumi state after provision' || echo 'No state changes'",
      "dependsOn": ["Provision cluster"]
    },
    {
      "label": "Get kubeconfig",
      "type": "shell",
      "command": "jq -r '.kubeconfig' output/my-cluster.json > ~/.kube/my-cluster.yaml && echo 'Kubeconfig written to ~/.kube/my-cluster.yaml'",
      "dependsOn": ["Commit state"]
    }
  ]
}
```


## GitHub Actions Usage

### Reusable workflow interface

```yaml
# .github/workflows/cluster.yaml
on:
  workflow_call:
    inputs:
      provider:
        required: true
        type: string
      config:
        required: true
        type: string       # path to the .env file in configs/
      action:
        required: true
        type: string       # provision | teardown | refresh | reset
    secrets:
      EXOSCALE_API_KEY:
        required: false
      EXOSCALE_API_SECRET:
        required: false
      AWS_ACCESS_KEY_ID:
        required: false
      AWS_SECRET_ACCESS_KEY:
        required: false
      PULUMI_PASSPHRASE:
        required: true
      SOPS_AGE_KEY:
        required: true
```

### Calling from another workflow in the same repo

Each job runs on a fresh runner with an empty workspace. The output file written in the provision job is not visible to subsequent jobs unless explicitly passed. The mechanism is `actions/upload-artifact` / `actions/download-artifact` — same-run artifact transfer, no GitHub API call, no cross-run dependency.

```yaml
# .github/workflows/deploy-jupyterlab.yaml
jobs:
  cluster:
    uses: ./.github/workflows/cluster.yaml
    with:
      provider: exoscale
      config: configs/kubyterlab-gpu-ephemeral.env
      action: provision
    secrets: inherit
    # cluster.yaml uploads output/<cluster_name>.json as artifact named:
    # cluster-output-<cluster_name>

  deploy:
    needs: cluster
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Download cluster output
        uses: actions/download-artifact@v4
        with:
          name: cluster-output-${{ needs.cluster.outputs.cluster_name }}
          path: output/

      - name: Apply manifests
        run: |
          jq -r '.kubeconfig' output/${{ needs.cluster.outputs.cluster_name }}.json > kubeconfig.yaml
          KUBECONFIG=kubeconfig.yaml kubectl apply -f manifests/
```

The reusable `cluster.yaml` workflow must upload the artifact and expose `cluster_name` as a job output so the caller can reference it:

```yaml
# Inside cluster.yaml — after the container step
- name: Upload cluster output
  if: steps.provision.conclusion == 'success'
  uses: actions/upload-artifact@v4
  with:
    name: cluster-output-${{ env.CLUSTER_NAME }}
    path: output/${{ env.CLUSTER_NAME }}.json
    retention-days: 1   # ephemeral — consumed within this workflow run
```

```yaml
# cluster.yaml job-level outputs
jobs:
  provision-teardown:
    outputs:
      cluster_name: ${{ env.CLUSTER_NAME }}
```

**For local use and cross-run use**: the output file lives at `output/<cluster_name>.json` on disk from the `docker run`. No artifact, no API call. This is the intended path for local administration and for re-using a cluster provisioned in a previous run — exactly the pattern used for the Headscale cluster. The `dawidd6/action-download-artifact` pattern used in the current repo (which calls the GitHub API to retrieve artifacts from previous runs) is replaced by the local `docker run` output file.

### Calling from another repo

```yaml
# .github/workflows/deploy.yaml  (in repo: sinan-ozel/jupyterlab-on-kubernetes)

name: Deploy JupyterLab

on:
  workflow_dispatch:
    inputs:
      action:
        description: "Action to perform"
        type: choice
        options: [provision, teardown]
        default: provision

jobs:
  cluster:
    uses: sinan-ozel/k3s-anywhere/.github/workflows/cluster.yaml@main
    with:
      provider: exoscale
      config: kubyterlab-gpu-ephemeral
      action: ${{ inputs.action }}
    secrets:
      EXOSCALE_API_KEY: ${{ secrets.EXOSCALE_API_KEY }}
      EXOSCALE_API_SECRET: ${{ secrets.EXOSCALE_API_SECRET }}
      # PULUMI_PASSPHRASE and SOPS_AGE_KEY are secrets in k3s-anywhere, not here

  deploy:
    if: ${{ inputs.action == 'provision' }}
    needs: cluster
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          name: cluster-output-kubyterlab-gpu-ephemeral
          path: output/

      - name: Deploy JupyterLab
        run: |
          jq -r '.kubeconfig' output/kubyterlab-gpu-ephemeral.json > kubeconfig.yaml
          KUBECONFIG=kubeconfig.yaml helm upgrade --install jupyterlab ./charts/jupyterlab \
            --set ingress.port=$(jq -r '.port' output/kubyterlab-gpu-ephemeral.json)
```

**Secret ownership:**

| Secret | Lives in | Reason |
|---|---|---|
| `PULUMI_PASSPHRASE` | `k3s-anywhere` | State is committed to k3s-anywhere |
| `SOPS_AGE_KEY` | `k3s-anywhere` | Encrypts/decrypts k3s-anywhere's state archive |
| `EXOSCALE_API_KEY` | calling repo | Cloud credentials belong to the caller |
| `EXOSCALE_API_SECRET` | calling repo | Same |

The calling repo is stateless from the infrastructure perspective — it passes cloud credentials and receives a kubeconfig. It knows nothing about Pulumi, SOPS, or SSH keys.

### What the workflow does with the container

```yaml
jobs:
  provision-teardown:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # for AWS OIDC
      contents: write   # for committing Pulumi state
    steps:
      - uses: actions/checkout@v4

      - name: Load config
        run: |
          grep -v '^#' "configs/${{ inputs.config }}" | grep '=' >> $GITHUB_ENV

      - name: Run provisioner container
        run: |
          docker run --rm \
            --env-file configs/${{ inputs.config }} \
            -e ACTION=${{ inputs.action }} \
            -e PROVIDER=${{ inputs.provider }} \
            -e PULUMI_CONFIG_PASSPHRASE=${{ secrets.PULUMI_PASSPHRASE }} \
            -e SOPS_AGE_KEY=${{ secrets.SOPS_AGE_KEY }} \
            -e EXOSCALE_API_KEY=${{ secrets.EXOSCALE_API_KEY }} \
            -e EXOSCALE_API_SECRET=${{ secrets.EXOSCALE_API_SECRET }} \
            -v ${{ github.workspace }}/pulumi-state.tar.gz.enc:/app/pulumi-state.tar.gz.enc \
            -v ${{ github.workspace }}/output:/app/output \
            ghcr.io/your-org/iac:latest

      - name: Commit Pulumi state
        if: always()
        run: |
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git config user.name "github-actions[bot]"
          git add pulumi-state.tar.gz.enc
          git commit -m "Update Pulumi state after ${{ inputs.action }}" || echo "No state changes"
          # retry logic for concurrent pushes (existing pattern from cluster.yaml lines 211-224)
          MAX_RETRIES=5
          RETRY_COUNT=0
          while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            git pull --no-rebase --no-edit && git push && break
            RETRY_COUNT=$((RETRY_COUNT + 1))
            sleep $((RETRY_COUNT * 2))
          done
```


## Kubeconfig Delivery

The container writes `output/<cluster_name>.json` containing the kubeconfig and SSH private key (for debugging). The kubeconfig is the real one — retrieved from the server via SSH after k3s is ready, with `127.0.0.1` replaced by the public IP.

This is derived from the existing pattern in `cluster.yaml` lines 341–347:

```bash
REAL_KUBECONFIG=$(ssh -i ~/.ssh/k3s_temp_key -o StrictHostKeyChecking=no root@$SERVER_IP \
  "cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/$SERVER_IP/g")

jq --arg kubeconfig "$REAL_KUBECONFIG" '.kubeconfig = $kubeconfig' \
  ${CLUSTER_NAME}.json > ${CLUSTER_NAME}.json.tmp
mv ${CLUSTER_NAME}.json.tmp ${CLUSTER_NAME}.json
```

**Locally**: the file is on disk at `output/<cluster_name>.json`. No GitHub API needed.

**In CI (same-repo workflow)**: subsequent jobs read it from the workspace.

**For administration**: `jq -r '.kubeconfig' output/my-cluster.json > ~/.kube/my-cluster.yaml`. This is the same pattern used for the Headscale cluster.

The SSH key used during provisioning is ephemeral — generated per run, stored in the JSON for emergency SSH access, and not persisted to the repo. The kubeconfig token is the long-lived credential.


## State Storage

Pulumi state lives in an S3-compatible bucket, not in git. The bucket is created once by a local setup script (see **First-Time Setup**) before any cluster is provisioned.

`entrypoint.sh` connects to the state bucket at the start of every run:

```bash
# entrypoint.sh — state backend
case "$PROVIDER" in
  exoscale)
    pulumi login "s3://${STATE_BUCKET_NAME}?endpoint=https://sos-${EXOSCALE_ZONE}.exo.io"
    ;;
  aws)
    pulumi login "s3://${STATE_BUCKET_NAME}"
    ;;
  gcp)
    pulumi login "gs://${STATE_BUCKET_NAME}"
    ;;
esac
```

`STATE_BUCKET_NAME` is added to GitHub Secrets alongside the cloud credentials. The scoped provisioner role (created by the setup script) is given read/write access to this bucket.

Sensitive Pulumi exports (kubeconfig, backup credentials) are still wrapped in `Output.secret()` and protected by `PULUMI_CONFIG_PASSPHRASE`. The state bucket handles persistence; the passphrase handles the secret values within that state.

```python
# pulumi/exoscale/__main__.py — always wrap sensitive exports
pulumi.export("kubeconfig", pulumi.Output.secret(
    server_nodes[0].public_ip_address.apply(generate_kubeconfig)
))
```


## Idempotency and State

Pulumi's stack maps `cluster_name` to a unique stack. Running `provision` again on an existing stack is a no-op if nothing changed, or a reconciliation if configuration drifted. This is the core Pulumi guarantee.

**The idempotency gap is pre-Pulumi**: the SSH key generation step must be conditional on whether the stack already has outputs. If the stack already exists, skip key generation and reuse the existing SSH key from the previous output.

```bash
# In entrypoint.sh, before pulumi up:
EXISTING_OUTPUT=$(pulumi stack output --json 2>/dev/null || echo "{}")
if echo "$EXISTING_OUTPUT" | jq -e '.server_public_ips' > /dev/null 2>&1; then
  echo "Stack already provisioned — reusing existing SSH key"
  # read SSH_PUBLIC_KEY from existing stack output rather than generating a new keypair
fi
```

The encrypted state archive is committed after every operation (provision, teardown, refresh, reset):
- State is versioned and recoverable via `git log`
- State is accessible without GitHub API (it's in the checkout)
- Rolling back is `git revert` on the archive + re-decrypt on next run

The retry-on-push logic (existing in `cluster.yaml` lines 211–224) handles concurrent runs attempting to commit state simultaneously.


## Reset Action

Three levels of failure require different responses:

| Situation | Action |
|---|---|
| State drifted from reality | `ACTION=refresh` — runs `pulumi refresh` |
| State is corrupted / unrecoverable | `ACTION=reset` — removes the stack entry from state only |
| Archive commit is wrong | `git revert` the `pulumi-state.tar.gz.enc` commit |

`reset` deletes only the Pulumi stack record. It does **not** destroy cloud resources — those are left as-is for manual cleanup (or they may already be gone). This is the escape hatch when `pulumi destroy` itself cannot run.

```bash
# reset in entrypoint.sh — state deletion only
pulumi stack rm ${CLUSTER_NAME} --yes --non-interactive || true
# state is re-encrypted and committed with the stack entry removed
```

After a reset, the next `provision` initialises a fresh stack.


## Storage: Longhorn

Longhorn is installed by the provisioning workflow as part of `ACTION=provision`. It is not optional. Users receive a cluster with Longhorn already running as the default StorageClass, with backup already configured. They create PVCs; Longhorn handles storage and backup.

### What Pulumi provisions

Pulumi provisions two things alongside the cluster:

1. **The k3s nodes** (compute, networking, SSH keys)
2. **An S3-compatible object storage bucket** named `<cluster_name>-backups`

The bucket is created in the same provider and region as the cluster. Pulumi generates scoped access credentials for the bucket (write access only — the backup user cannot delete the bucket or access other buckets). These credentials are exported from Pulumi as `Output.secret()` and flow into `post_provision.sh` and the output artifact.

```python
# pulumi/exoscale/__main__.py — bucket alongside compute
backup_bucket = exoscale.S3Bucket(
    f'{CLUSTER_NAME}-backups',
    bucket=f'{CLUSTER_NAME}-backups',
    acl='private',
)

# Scoped IAM key for backup writes only
backup_key = exoscale.IamAccessKey(
    f'{CLUSTER_NAME}-backup-key',
    username=f'{CLUSTER_NAME}-backup',
)

pulumi.export("backup_bucket", backup_bucket.bucket)
pulumi.export("backup_endpoint", f"https://sos-{REGION}.exo.io")
pulumi.export("backup_access_key", pulumi.Output.secret(backup_key.access_key_id))
pulumi.export("backup_secret_key", pulumi.Output.secret(backup_key.secret_access_key))
```

### What the infrastructure requires on nodes

Two things must be true on every node for Longhorn to function, and only cloud-init can provide them:

```yaml
# In get_k3s_cloud_init() — pulumi/exoscale/__main__.py line 248
packages:
  - open-iscsi       # required by Longhorn for volume operations
  - nfs-common       # required for NFS backup targets
  - cryptsetup       # required for volume encryption
  - util-linux       # provides lsblk, needed for disk detection
```

cluster-admin kubeconfig is also required — Longhorn installs CRDs, ClusterRoles, and DaemonSets with privileged containers. k3s generates cluster-admin by default.

### What post_provision.sh installs and configures

```bash
# post_provision.sh — runs after pulumi up
# Reads backup credentials from Pulumi stack output

export KUBECONFIG=/app/output/kubeconfig.yaml

BACKUP_BUCKET=$(pulumi stack output backup_bucket --show-secrets)
BACKUP_ENDPOINT=$(pulumi stack output backup_endpoint --show-secrets)
BACKUP_ACCESS_KEY=$(pulumi stack output backup_access_key --show-secrets)
BACKUP_SECRET_KEY=$(pulumi stack output backup_secret_key --show-secrets)

helm repo add longhorn https://charts.longhorn.io && helm repo update

TOTAL_NODES=$((DEFAULT_NODE_COUNT + GPU_NODE_COUNT))
REPLICA_COUNT=1
[ "$TOTAL_NODES" -ge 3 ] && REPLICA_COUNT=3

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --version ${LONGHORN_VERSION} \
  --set defaultSettings.defaultReplicaCount=${REPLICA_COUNT} \
  --wait --timeout 10m

# Displace k3s's default local-path StorageClass
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'

kubectl apply -f /app/manifests/longhorn/longhorn-storage-class.yaml

# Configure backup target
kubectl create secret generic longhorn-backup-secret \
  -n longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID="${BACKUP_ACCESS_KEY}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${BACKUP_SECRET_KEY}" \
  --from-literal=AWS_ENDPOINTS="${BACKUP_ENDPOINT}"

kubectl -n longhorn-system patch settings.longhorn.io backup-target \
  --type=merge -p "{\"value\": \"s3://${BACKUP_BUCKET}@${REGION}/\"}"

kubectl -n longhorn-system patch settings.longhorn.io backup-target-credential-secret \
  --type=merge -p '{"value": "longhorn-backup-secret"}'
```

### Teardown behaviour

The backup bucket is **not destroyed** when the cluster is torn down. This is intentional — teardown should not silently delete backup data. The bucket persists and must be removed manually if no longer needed. Pulumi's teardown will warn that the bucket still exists but will not fail.

### Backup/restore ownership

| Responsibility | Owner |
|---|---|
| Bucket provisioned and credentials generated | Infrastructure (Pulumi) |
| Longhorn installed and backup target configured | Infrastructure (post_provision.sh) |
| Which PVCs to create | Deployer |
| Backup schedule (Longhorn RecurringJob) | Deployer |
| Restore decision — when, from which snapshot | Deployer |
| Application-level backups (pg_dump, etc.) | Deployer, using `backup.*` credentials from output |

The infrastructure hands the deployer a working backup system and the credentials to extend it. Scheduling policy and restore decisions are application concerns.

### What users can do

With the output artifact in hand, a deployer can:

```bash
# Use the backup bucket for application-level backups (pg_dump, etc.)
ENDPOINT=$(jq -r '.backup.endpoint' output/my-cluster.json)
ACCESS_KEY=$(jq -r '.backup.access_key' output/my-cluster.json)
SECRET_KEY=$(jq -r '.backup.secret_key' output/my-cluster.json)
BUCKET=$(jq -r '.backup.bucket' output/my-cluster.json)

AWS_ACCESS_KEY_ID=$ACCESS_KEY \
AWS_SECRET_ACCESS_KEY=$SECRET_KEY \
aws --endpoint-url=$ENDPOINT s3 cp dump.sql s3://$BUCKET/postgres/

# Schedule Longhorn volume backups (once every 6h, retain 10)
kubectl -n longhorn-system apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
spec:
  cron: "0 */6 * * *"
  task: backup
  retain: 10
EOF
```

**Important**: block-level snapshots of the underlying disk do not work with Longhorn. Longhorn's own backup system (to the provisioned S3 bucket) must be used for volume data. See `manifests/longhorn/README.md`.


## Required Privileges

### Exoscale

Secrets required:
- `EXOSCALE_API_KEY`
- `EXOSCALE_API_SECRET`

The API key needs the following Exoscale IAM permissions:
- `compute` — create/delete instances, security groups, SSH keys
- `object-storage` — create bucket, generate scoped access keys for backup
- `block-storage` — attach/detach volumes (if using external volumes)

No additional role configuration is needed. Exoscale uses API key scoping rather than role assumption.

### AWS

> **Note**: The current AWS implementation uses EKS. The k3s-on-EC2 implementation will require a significantly reduced privilege set. The EKS-specific policies below (AmazonEKSClusterPolicy, AmazonEKSWorkerNodePolicy, etc.) will be replaced. This section will be updated when the AWS k3s implementation is written. The goal is least-privilege roles created through the packaged setup script (`scripts/aws/setup.sh`, run locally via `ACTION=setup`).

Secrets required:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Current role `github-actions-iac` (EKS — to be replaced for k3s):

Amazon-managed policies attached:
- `AmazonEBSCSIDriverPolicy`
- `AmazonEC2FullAccess`
- `AmazonEKSClusterPolicy`
- `AmazonEKSLoadBalancingPolicy`
- `AmazonEKSNetworkingPolicy`
- `AmazonEKSServicePolicy`
- `AmazonEKSWorkerNodePolicy`
- `AutoScalingFullAccess`

Inline policies: IAM role creation for EKS node groups, EKS access entry management. See `README.md` for full JSON.

**Target for AWS k3s**: The EKS-specific policies above will not be needed. The actual policy will be determined by implementing and testing, then distilled into a least-privilege role via `scripts/aws/setup.sh`. A practical k3s deployment on EC2 will require permissions across EC2, VPC, security groups, Elastic IPs, and potentially load balancers — do not assume the list is short. This section will be filled in once the implementation exists.

Trust policy (OIDC, GitHub Actions):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:*"
      }
    }
  }]
}
```

### GCP (planned)

Secrets required (anticipated):
- `GCP_SERVICE_ACCOUNT_KEY` (JSON key for a service account)

Anticipated IAM roles:
- `roles/compute.admin` — create/delete GCE instances, firewall rules, networks
- `roles/iam.serviceAccountUser` — pass service account to instances

To be determined when implementation is written.


## First-Time Setup

All ongoing operations (provision, teardown, refresh) run in GitHub Actions with least-privilege credentials. The setup that creates those credentials — and the Pulumi state bucket — requires broader permissions. This work is done **locally, once, under supervision**. The elevated credentials are never stored in GitHub Secrets.

The setup scripts live in `scripts/<provider>/setup.sh` and ship inside the container image, invoked with `ACTION=setup`. The privileged step is therefore versioned and distributed with the product, but still executed locally: admin credentials are passed at invocation (mounted `~/.aws` or env vars) and never stored. VS Code tasks wrap the same `docker run` commands.

### Privilege model

| Step | Who runs it | Credentials used | Stored in |
|---|---|---|---|
| Create state bucket | Operator, locally | Admin/owner key | Never committed |
| Create least-privilege role | Operator, locally | Admin/owner key | Never committed |
| Provision / teardown clusters | GitHub Actions | Scoped key | GitHub Secrets |

### Invocation

```bash
# Exoscale
docker run --rm \
  -e ACTION=setup -e PROVIDER=exoscale -e EXOSCALE_ZONE=ch-gva-2 \
  -e EXOSCALE_API_KEY=<org-admin key> -e EXOSCALE_API_SECRET=<org-admin secret> \
  sinanozel/k3s-anywhere:latest

# AWS
docker run --rm \
  -e ACTION=setup -e PROVIDER=aws -e AWS_REGION=us-east-1 \
  -v ~/.aws:/root/.aws:ro \
  sinanozel/k3s-anywhere:latest
```

### What each setup script does

Each `scripts/<provider>/setup.sh`:

1. Creates the Pulumi state bucket
2. Creates a least-privilege IAM role/user scoped to what the provisioner needs
3. Generates access credentials for that role
4. Prints the values to add to GitHub Secrets

The scripts read admin credentials from the invocation environment — they are never written to any file in this repo or stored in the image.

Setup is idempotent: rerunning it refreshes the provisioner policy (required after upgrading to an image version that needs new permissions) but keeps existing access keys unless `ROTATE_KEY=true` is set. The entrypoint also verifies the state bucket is reachable before any other action and, if it is not, fails with the exact setup command to run — so a consumer who skips setup gets a self-documenting error rather than an opaque Pulumi failure.

After setup, the operator's admin credentials are no longer needed for day-to-day operations.


## What Goes in Pulumi vs Scripts

The decision rule: **Pulumi owns anything it can read back as state. Scripts own everything else.**

| Work | Owner | Reason |
|---|---|---|
| VPC / network / firewall | Pulumi | Declarative, stable state |
| Compute instances | Pulumi | Declarative, stable state |
| Security groups / rules | Pulumi | Declarative, stable state |
| SSH key registration | Pulumi | Stable cloud resource |
| Cloud-init script generation | Pulumi | Part of instance definition |
| Waiting for SSH to become available | Script | Imperative polling, no cloud state |
| Waiting for k3s to be ready | Script | Imperative polling, no cloud state |
| Retrieving kubeconfig via SSH | Script | Imperative SSH, not cloud state |
| Installing Longhorn via Helm | Script | Post-provisioning, imperative |
| Longhorn StorageClass patching | Script | Post-provisioning, imperative |
| Teardown of load balancers created by Helm | Script | Pulumi cannot discover these |
| Volume snapshot before teardown | Script | Imperative, order-dependent |

The existing `pulumi/exoscale/__main__.py` already follows this pattern cleanly. The `get_k3s_cloud_init()` function (line 215) generates the cloud-init script inline — Pulumi manages it as part of the instance `user_data` field. Everything after the instance is up is script territory.


## Adding a New Cloud Provider

1. Create `pulumi/<provider>/__main__.py` following the structure of `pulumi/exoscale/__main__.py`:
   - Read the same env vars (`CLUSTER_NAME`, `DEFAULT_NODE_COUNT`, `GPU_NODE_COUNT`, `PORT`, region)
   - Use the same `get_k3s_cloud_init()` function (or import it from a shared module)
   - Export `server_public_ips`, `kubeconfig` (placeholder), `cluster_name`
   - Fix the instance types for that provider

2. Create `scripts/<provider>/cluster/teardown_load_balancer.py`

3. Create `scripts/<provider>/cluster/post_provision.sh` with the Longhorn installation (identical across providers — this is the point)

4. Add provider to the `PROVIDER` choice in `cluster.yaml`

5. Add a `configs/<provider>/` directory for region-specific env overrides

6. Document required privileges in this file under **Required Privileges**

The cloud-init script, Longhorn installation, and kubeconfig retrieval are identical across all providers. Only the Pulumi resource types change.
