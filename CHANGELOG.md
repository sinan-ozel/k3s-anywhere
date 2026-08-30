# Changelog

## [0.2.5] - 2026-08-30

- **AWS, Exoscale** Fix GPU nodes never actually granting containers GPU access despite joining Ready and `nvidia-smi` working on the host: the v0.2.3 fix prepends `{{ template "base" . }}` to nvidia-ctk's drop-in stub, but the stub's `imports = [...]` line only pulls in `/etc/containerd/conf.d/*.toml` at containerd's own load time — a cross-file merge that, verified by hand, merges the new `runtimes.nvidia` table fine but silently drops `default_runtime_name = "nvidia"` because k3s's base template already declares the same `[plugins."io.containerd.grpc.v1.cri".containerd]` table for its own snapshotter settings. Every pod without an explicit RuntimeClass then still ran under plain runc — no `/dev/nvidia*` devices, `nvidia-device-plugin` crash-looping with "Incompatible strategy detected auto" — with no indication anything was wrong at the node level. Now resolves the stub's `imports` pointer to the actual drop-in file and inlines its real content instead of the pointer, restoring the single-file structure nvidia-ctk used before it switched to drop-in mode, which k3s templates and merges correctly in one pass.

## [0.2.4] - 2026-08-22

- **AWS, Exoscale** Fix Longhorn PVCs stuck permanently in `AttachVolume.Attach failed ... not ready for workloads` on clusters with fewer than 3 nodes: `post_provision.sh` already computed a node-count-aware `REPLICA_COUNT = min(TOTAL_NODES, 3)`, but passed it only via `defaultSettings.defaultReplicaCount`, a Helm value that (per the Longhorn chart's own values.yaml) only controls the replica count for volumes created by hand through Longhorn's UI. The StorageClass that PVCs actually bind against is controlled by the separate `persistence.defaultClassReplicaCount` value, which was never set and silently kept the chart's own default of 3 regardless of cluster size — so every PVC on a 1- or 2-node cluster asked for more replicas than there were nodes to place them on, and never attached. Now sets both.

## [0.2.3] - 2026-08-21

- **AWS, Exoscale** Fix GPU agent nodes joining but never going Ready: current `nvidia-ctk` releases write `config.toml.tmpl` as a drop-in stub (`imports = [...]; version = 2`) instead of an inline runtime block, with no `{{ template "base" . }}` directive. k3s's templating only injects its own required settings — notably the CNI `bin_dir`/`conf_dir` pointing at `/var/lib/rancher/k3s/agent/etc/cni/net.d` — by expanding that directive, so without it k3s passes the stub straight through unchanged. containerd's CRI plugin then falls back to its upstream default CNI `conf_dir` (`/etc/cni/net.d`), which k3s never populates, and kubelet hangs forever on "cni plugin not initialized" even though `k3s-agent` is running and the node has a pod CIDR. After `nvidia-ctk` writes the stub, drop its `version` line (the base template supplies its own) and prepend `{{ template "base" . }}` so k3s still injects its own settings around nvidia-ctk's `imports` line.

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
