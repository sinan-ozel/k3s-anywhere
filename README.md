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

That's it — the provider CLIs ship inside the container.

## First-time setup

Run once per cloud account, locally, with admin credentials. This creates the Pulumi state bucket and a least-privilege IAM role for ongoing operations. Admin credentials are passed at invocation and never stored anywhere — by design, this step never runs in GitHub Actions.

```bash
# Exoscale (org-admin API key)
docker run --rm \
  -e ACTION=setup -e PROVIDER=exoscale -e EXOSCALE_ZONE=ch-gva-2 \
  -e EXOSCALE_API_KEY=<org-admin key> -e EXOSCALE_API_SECRET=<org-admin secret> \
  sinanozel/k3s-anywhere:latest

# AWS (admin profile from ~/.aws, or pass AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY instead)
docker run --rm \
  -e ACTION=setup -e PROVIDER=aws -e AWS_REGION=us-east-1 \
  -v ~/.aws:/root/.aws:ro \
  sinanozel/k3s-anywhere:latest
```

The container prints the values to add to GitHub Secrets and your local `.env.secrets`.

If you skip this step, any other action fails fast with the exact setup command to run.

VS Code: use the **k3s: First-time setup** tasks.

### Rerunning setup

Setup is idempotent. Rerun it **after upgrading the image tag** — newer versions may require additional provisioner permissions, and rerunning refreshes the IAM policy. Existing access keys (and therefore your GitHub Secrets) are kept as-is; add `-e ROTATE_KEY=true` to revoke them and issue a new key.

### Purging the setup

To decommission k3s-anywhere from a cloud account entirely — for example, after a team's environment is no longer needed — run `ACTION=purge`. This deletes the provisioner IAM user (and its access keys and policy) and the Pulumi state bucket.

**Destroy all clusters first** (`ACTION=teardown` per cluster). Purging while clusters are still running removes the credentials needed to manage them via Pulumi, leaving orphaned infrastructure.

```bash
# Interactive (prompts for confirmation)
docker run --rm -it \
  -e ACTION=purge -e PROVIDER=aws -e AWS_REGION=us-east-1 \
  -v ~/.aws:/root/.aws:ro \
  sinanozel/k3s-anywhere:latest

# Non-interactive (skip prompt — use in scripts)
docker run --rm \
  -e ACTION=purge -e PROVIDER=aws -e AWS_REGION=us-east-1 \
  -e FORCE=true \
  -v ~/.aws:/root/.aws:ro \
  sinanozel/k3s-anywhere:latest
```

The confirmation prompt requires you to type the IAM username (`k3s-anywhere-provisioner`) before anything is deleted. The `-it` flag is required for the prompt; omit it only with `FORCE=true`.

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
  sinanozel/k3s-anywhere:latest
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
  sinanozel/k3s-anywhere:latest
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
      provider_config: configs/exoscale/my-cluster-ch-gva-2
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
      provider_config: configs/aws/my-cluster-us-east-1
      action: ${{ inputs.action }}
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      PULUMI_CONFIG_PASSPHRASE: ${{ secrets.PULUMI_CONFIG_PASSPHRASE }}
      STATE_BUCKET_NAME: ${{ secrets.STATE_BUCKET_NAME }}
```

`provider_config` is required for AWS (`AWS_REGION`) and Exoscale (`EXOSCALE_ZONE`). It mirrors the local `--env-file` layering pattern and its variables override the base config.

Required secrets in GitHub:

| Secret | Provider |
|---|---|
| `EXOSCALE_API_KEY` + `EXOSCALE_API_SECRET` | Exoscale |
| `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` | AWS |
| `PULUMI_CONFIG_PASSPHRASE` | All |
| `STATE_BUCKET_NAME` | All |

## Releasing the image

The container is published to [Docker Hub](https://hub.docker.com/r/sinanozel/k3s-anywhere) by `.github/workflows/build.yaml`.

**Releases.** Pushing a `vX.Y.Z` git tag builds and pushes `sinanozel/k3s-anywhere:X.Y.Z`, `:X.Y`, and `:latest`:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Release tags are write-once: if `:X.Y.Z` already exists on Docker Hub, the build fails instead of overwriting it. To republish, cut a new version.

**Dev builds.** Every commit to `main` is pushed as `:X.Y.Z-dev.N`, where `X.Y.Z` is the next patch after the latest release tag and `N` is the number of commits since it (e.g. after `v0.1.0`, the 14th commit on `main` builds `0.1.1-dev.14`). The version is derived entirely from git history — no tags are written back, so rebuilding a commit reproduces the same version, and concurrent merges can never collide. Dev builds never move `:latest`.

**Pull requests** that touch the image contents build it (without pushing) to validate the Dockerfile.

Git tags use a `v` prefix (`v0.1.0`); Docker tags are bare (`0.1.0`).

Requires two repository secrets: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Docker Hub access token scoped to read/write on this one repository — it grants no cloud access).

The image is `linux/amd64` only; on Apple Silicon, run it with Rosetta emulation (Docker does this automatically) and build locally with `docker build --platform linux/amd64` if you ever bypass CI.

## Repository layout

```
.github/workflows/
  build.yaml          ← builds and pushes the Docker image (CI)
  cluster.yaml        ← reusable workflow: provision / teardown (CI)

pulumi/
  exoscale/           ← Pulumi program: k3s on Exoscale compute
  aws/                ← Pulumi program: k3s on EC2

scripts/
  exoscale/
    setup.sh          ← operator-run, admin credentials, never in CI
    cluster/
      post_provision.sh          ← run by the container during provision
      teardown_load_balancer.py  ← run by the container during teardown
  aws/
    setup.sh                ← operator-run, admin credentials, never in CI
    provisioner-policy.json ← IAM policy document read by setup.sh
    cluster/
      post_provision.sh
      teardown_load_balancer.py

configs/
  <name>.env                      ← shared base config (cluster name, node counts, port)
  exoscale/<name>-<zone>.env      ← zone override
  aws/<name>-<region>.env         ← region override
```

`scripts/<provider>/setup.sh` runs **locally** via `ACTION=setup` with admin credentials; it is never called from GitHub Actions. Everything under `scripts/<provider>/cluster/` runs **inside the container** as part of the provision and teardown actions, with least-privilege credentials, in CI.

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
| `K3S_VERSION` | no (default `v1.31.4+k3s1`) | k3s release to install on all nodes. |
| `LONGHORN_VERSION` | no (default `1.7.2`) | Longhorn Helm chart version to install. |

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
