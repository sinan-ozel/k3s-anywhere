# Changelog

## [0.2.2] - 2026-08-01

- **AWS, Exoscale** Fix GPU agent nodes still never joining the cluster after v0.2.1: with no pre-existing containerd base config to merge into, `nvidia-ctk runtime configure` defines an `nvidia` containerd runtime but no `runc` one. containerd's CRI plugin defaults `default_runtime_name` to `"runc"` internally, finds no matching runtime block, and refuses to load — `k3s-agent` hangs forever on "Waiting for containerd startup" even though the driver loaded correctly. Pass `--set-as-default` so `nvidia-ctk` points `default_runtime_name` at `nvidia` instead, which is safe for non-GPU pods too since `nvidia-container-runtime` transparently behaves like plain `runc` unless a container actually requests a GPU.

## [0.2.1] - 2026-08-01

- **AWS, Exoscale** Fix GPU agent nodes never joining the cluster: `ubuntu-drivers autoinstall` can pull in a newer kernel package as a dependency without the instance rebooting into it, leaving the installed nvidia `.ko` built only for the new kernel. `nvidia-smi` then fails against the still-running old kernel, nvidia-ctk's containerd config points at a runtime that can never initialize, and `k3s-agent` hangs forever on "Waiting for containerd startup" — the node never registers with the cluster. Now reboots unconditionally right after the driver install and finishes `nvidia-container-toolkit` setup + the k3s agent join from a oneshot systemd unit on the next boot.

## [0.2.0] - 2026-07-25

- **AWS** Default node instance type changed from `t3.medium` to `m6i.large`: `t3.medium`'s burstable 2 vCPU / 4 GiB was insufficient to reliably host the k3s control plane. `m6i.large` (2 vCPU, unthrottled / 8 GiB) removes the CPU-credit throttling risk for etcd and doubles available memory, at roughly 2.3x the on-demand hourly cost.

## [0.1.11] - 2026-07-10

- **AWS** Fix orphan-key-pair guard deleting the live key pair on every re-provision: piping `pulumi stack export` into `grep -q` triggered SIGPIPE under `pipefail` once state exceeded the pipe buffer, so the check always reported "not found" and deleted the in-use key pair, breaking the following `pulumi up` with `InvalidKeyPair.NotFound`. Replaced with a pipe-free bash substring match that only deletes when the export succeeds and positively lacks the key pair.

## [0.1.10] - 2026-07-10

- Fix provisioning output left root-owned on Linux runners: the container runs as root, so the SSH key and cluster JSON written to the bind-mounted `output/` dir were unreadable by the non-root runner user in later workflow steps (e.g. sops-encrypt), causing permission-denied failures. `chmod -R a+r /app/output` after provisioning.

## [0.1.9] - 2026-07-09

- New `ACTION=check`: prints current stack outputs and runs `pulumi preview` to report drift between live infrastructure and the config files, without changing anything
- **AWS, Exoscale** Fix k3s agent install command on agent/GPU nodes: the `runcmd` entry used a plain multi-line YAML scalar instead of a literal block (`- |`), so YAML folded the line continuations into one broken command and k3s never installed on any agent node
- **AWS, Exoscale** Fix GPU driver install: replace pinned `nvidia-driver-545` (a jammy/22.04 branch, unavailable on the noble/24.04 image this project provisions) with `ubuntu-drivers-common` + `ubuntu-drivers autoinstall`, which always matches the running release
- Upload the provisioning SSH private key (`<cluster>-ssh.pem`, sops-encrypted when `sops_age_recipient` is set) as a GitHub Actions artifact alongside the cluster output JSON — previously it was written only to the ephemeral runner and lost once the job ended

## [0.1.6] - 2026-07-04

- Version corrected to match the `0.1.6-dev.*` pre-release series; identical code to 0.1.5

## [0.1.5] - 2026-07-04

- **AWS** Provisioner IAM policy covers `*-externaldns` users so `EXTERNAL_DNS=true` provisions succeed without a setup re-run
- **AWS** Remove `HOSTED_ZONE_ID`; Route53 external-dns policy uses wildcard resource (`"Resource": "*"`)
- **AWS** Consistent `Name`, `ManagedBy` (with version), and `Cleanup` tags on all provisioned resources
- **AWS** `setup` rejects provisioner credentials at startup with a clear error message
- **AWS** Decommission: enumerate all inline policies before `delete-user`; suppress `head-bucket` and `get-user` JSON from stdout
- **AWS** Provision auto-imports the backup S3 bucket and removes orphaned key pairs before `pulumi up` — re-provision after decommission requires no manual cleanup
- **AWS** Teardown also deletes orphaned EC2 key pair and backup IAM user left by a failed or interrupted provision
- Version baked into `/app/VERSION` at build time; used in resource tags

## [0.1.5-dev.0] - 2026-06-25

- **AWS** Provisioner IAM policy extended to allow creating and managing `*-externaldns` IAM users

## [0.1.4] - 2026-07-02

- **AWS** Enforce IMDSv2 (`http_tokens=required`, hop-limit=1) on all EC2 instances to block pod-level IMDS access
- **AWS** `EXTERNAL_DNS=true` provisions a dedicated IAM user with the Route 53 external-dns policy; `HOSTED_ZONE_ID` optionally scopes it to a single zone
- **Exoscale** `EXTERNAL_DNS=true` includes an `externaldns` block in the output JSON (credentials managed separately)

## [0.1.3] - 2026-06-25

- Fix `sops --decrypt` to force JSON output type for non-`.json` extensions

## [0.1.2] - 2026-06-25

- `PORT` / `PORTS` (comma-separated) open additional security-group ingress ports; `port` (int) and `ports` (array) both present in output JSON
- Protect backup S3 bucket from `pulumi destroy`; make Longhorn backup secret creation idempotent
- `pulumi destroy` skips protected resources instead of failing

## [0.1.1] - 2026-06-24

- `ELASTIC_IP_COUNT` (alias `ELASTIC_IP`) allocates a static public IP on AWS and Exoscale; `api_endpoint` and kubeconfig remain stable across node replacement

## [0.1.0] - 2026-06-24

- Initial release — AWS and Exoscale provisioning, Longhorn storage, S3/SOS backup target, SOPS/age encrypted output artifact
