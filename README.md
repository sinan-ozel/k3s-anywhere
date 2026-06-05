# k3s-anywhere

Provision a k3s cluster on any supported cloud provider and get back a working kubeconfig. One config file in, one JSON artifact out.

## Provider status

| Provider | Implemented | Tested w/ Default Nodes | Tested w/ GPU Nodes |
|---|---|---|---|
| Exoscale | ✓ | | |
| AWS | ✓ | | |
| GCP | | | |

## How it works

A Docker container reads a handful of environment variables, runs Pulumi to create compute and storage resources, installs k3s and Longhorn, and writes `output/<cluster-name>.json`. That file contains the kubeconfig, API endpoint, and backup bucket credentials. Tear down by running the same container with `ACTION=teardown`.

Longhorn is always installed as the default StorageClass. If you want a stateless cluster, simply do not create any PersistentVolumeClaims.

## Prerequisites

- Docker
- For Exoscale: `exo` CLI (for first-time setup)
- For AWS: `aws` CLI (for first-time setup)

## First-time setup

Run once per repo, locally, with admin credentials. This creates the Pulumi state bucket and a least-privilege IAM role for ongoing operations.

```bash
# Exoscale
EXOSCALE_ZONE=ch-gva-2 bash local_scripts/exoscale/setup.sh

# AWS
AWS_REGION=us-east-1 bash local_scripts/aws/setup.sh
```

The script prints the values to add to GitHub Secrets and your local `.env.secrets`.

VS Code: use the **k3s: First-time setup** tasks.

## Local usage

Create a config file:

```bash
# configs/my-cluster.env
CLUSTER_NAME=my-cluster
DEFAULT_NODE_COUNT=1
GPU_NODE_COUNT=0
PORT=8888
STATE_BUCKET_NAME=my-k3s-anywhere-state
```

Add a provider zone/region override:

```bash
# configs/exoscale/my-cluster-ch-gva-2.env
EXOSCALE_ZONE=ch-gva-2
```

Create `.env.secrets` (gitignored):

```bash
EXOSCALE_API_KEY=EXO...
EXOSCALE_API_SECRET=...
PULUMI_CONFIG_PASSPHRASE=...
```

Provision:

```bash
mkdir -p output
docker run --rm \
  --env-file configs/my-cluster.env \
  --env-file configs/exoscale/my-cluster-ch-gva-2.env \
  --env-file .env.secrets \
  -e ACTION=provision \
  -e PROVIDER=exoscale \
  -v $(pwd)/output:/app/output \
  ghcr.io/sinan-ozel/k3s-anywhere:latest
```

Get the kubeconfig:

```bash
jq -r '.kubeconfig' output/my-cluster.json > ~/.kube/my-cluster.yaml
export KUBECONFIG=~/.kube/my-cluster.yaml
kubectl get nodes
```

Tear down:

```bash
docker run --rm \
  --env-file configs/my-cluster.env \
  --env-file configs/exoscale/my-cluster-ch-gva-2.env \
  --env-file .env.secrets \
  -e ACTION=teardown \
  -e PROVIDER=exoscale \
  -v $(pwd)/output:/app/output \
  ghcr.io/sinan-ozel/k3s-anywhere:latest
```

VS Code: use the **k3s: Provision** and **k3s: Teardown** tasks (edit `tasks.json` to point at your config file).

## GitHub Actions usage

### Same-repo workflow

```yaml
# .github/workflows/deploy.yaml
jobs:
  cluster:
    uses: ./.github/workflows/cluster.yaml
    with:
      provider: exoscale
      config: configs/my-cluster
      action: provision
    secrets: inherit

  deploy:
    needs: cluster
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          name: cluster-output-${{ needs.cluster.outputs.cluster_name }}
          path: output/

      - name: Apply manifests
        run: |
          jq -r '.kubeconfig' output/${{ needs.cluster.outputs.cluster_name }}.json > kubeconfig.yaml
          KUBECONFIG=kubeconfig.yaml kubectl apply -f manifests/
```

### Cross-repo workflow

```yaml
# In repo: your-org/your-app
jobs:
  cluster:
    uses: sinan-ozel/k3s-anywhere/.github/workflows/cluster.yaml@main
    with:
      provider: aws
      config: configs/my-cluster
      action: ${{ inputs.action }}
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      PULUMI_CONFIG_PASSPHRASE: ${{ secrets.PULUMI_CONFIG_PASSPHRASE }}
      STATE_BUCKET_NAME: ${{ secrets.STATE_BUCKET_NAME }}
```

Required secrets in GitHub:

| Secret | Provider |
|---|---|
| `EXOSCALE_API_KEY` + `EXOSCALE_API_SECRET` | Exoscale |
| `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` | AWS |
| `PULUMI_CONFIG_PASSPHRASE` | All |
| `STATE_BUCKET_NAME` | All |

## Configuration reference

**Base config** (`configs/<name>.env`):

| Variable | Required | Description |
|---|---|---|
| `CLUSTER_NAME` | yes | Unique name; becomes the Pulumi stack name |
| `DEFAULT_NODE_COUNT` | yes | Number of standard CPU nodes |
| `GPU_NODE_COUNT` | no (default 0) | Number of GPU nodes |
| `PORT` | yes | Single public port routed through Traefik |
| `STATE_BUCKET_NAME` | yes | Pulumi state bucket (created by setup script) |
| `USE_PUBLIC_DNS` | no (default `false`) | AWS, Azure: use the cloud-assigned public DNS name in the kubeconfig and `api_endpoint` instead of the IP. The TLS certificate always covers both, so either works. Ignored on Exoscale and GCP. |

**Provider overrides** (`configs/<provider>/<name>.env`):

| Variable | Provider |
|---|---|
| `EXOSCALE_ZONE` | Exoscale |
| `AWS_REGION` | AWS |

## Output reference

`output/<cluster-name>.json` contains everything needed to use the cluster:

```bash
# Extract kubeconfig
jq -r '.kubeconfig' output/my-cluster.json > ~/.kube/my-cluster.yaml

# Check the API endpoint
curl -k $(jq -r '.api_endpoint' output/my-cluster.json)/version

# Write to backup bucket (application-level)
ENDPOINT=$(jq -r '.backup.endpoint' output/my-cluster.json)
ACCESS_KEY=$(jq -r '.backup.access_key' output/my-cluster.json)
SECRET_KEY=$(jq -r '.backup.secret_key' output/my-cluster.json)
BUCKET=$(jq -r '.backup.bucket' output/my-cluster.json)

AWS_ACCESS_KEY_ID=$ACCESS_KEY AWS_SECRET_ACCESS_KEY=$SECRET_KEY \
  aws ${ENDPOINT:+--endpoint-url=$ENDPOINT} s3 cp dump.sql s3://$BUCKET/postgres/
```

The `output/` directory is gitignored. SSH keys and kubeconfigs stay local.
