# Changelog

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
