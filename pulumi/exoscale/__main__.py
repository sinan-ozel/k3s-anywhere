import os
import textwrap
import pulumi
import pulumiverse_exoscale as exoscale
import pulumi_tls as tls
import pulumi_random as random

CLUSTER_NAME   = os.environ["CLUSTER_NAME"]
DEFAULT_NODES  = int(os.environ.get("DEFAULT_NODE_COUNT", "1"))
GPU_NODES      = int(os.environ.get("GPU_NODE_COUNT", "0"))
PORT           = int(os.environ["PORT"])
ZONE           = os.environ["EXOSCALE_ZONE"]
K3S_VERSION    = os.environ.get("K3S_VERSION", "v1.31.4+k3s1")
DISK_SIZE_GB   = int(os.environ.get("DISK_SIZE_GB", "25"))

# ── SSH key ───────────────────────────────────────────────────────────────────

ssh_key = tls.PrivateKey(f"{CLUSTER_NAME}-ssh-key", algorithm="RSA", rsa_bits=4096)

exo_ssh_key = exoscale.SshKey(
    f"{CLUSTER_NAME}-key",
    name=f"{CLUSTER_NAME}-key",
    public_key=ssh_key.public_key_openssh,
)

# ── k3s cluster token ─────────────────────────────────────────────────────────

k3s_token = random.RandomPassword(
    f"{CLUSTER_NAME}-k3s-token",
    length=32,
    special=False,
)

# ── Security group ────────────────────────────────────────────────────────────

sg = exoscale.SecurityGroup(
    f"{CLUSTER_NAME}-sg",
    name=f"{CLUSTER_NAME}-sg",
    description=f"k3s-anywhere {CLUSTER_NAME}",
)

_sg_rules = [
    ("ssh",               "TCP", 22,   22),
    ("k8s-api",           "TCP", 6443, 6443),
    ("app-port",          "TCP", PORT, PORT),
    ("flannel-vxlan",     "UDP", 8472, 8472),
    ("longhorn-rep",      "TCP", 9500, 9520),
    ("kubelet",           "TCP", 10250, 10250),
]

for name, proto, start, end in _sg_rules:
    exoscale.SecurityGroupRule(
        f"{CLUSTER_NAME}-{name}",
        security_group_id=sg.id,
        description=name,
        protocol=proto,
        start_port=start,
        end_port=end,
        cidr="0.0.0.0/0",
    )

# ── OS template ───────────────────────────────────────────────────────────────

ubuntu = exoscale.get_template_output(
    zone=ZONE,
    name="Linux Ubuntu 24.04 LTS 64-bit",
    visibility="public",
)

# ── Cloud-init helpers ────────────────────────────────────────────────────────

def _base_packages() -> str:
    return textwrap.dedent("""\
        packages:
          - open-iscsi
          - nfs-common
          - cryptsetup
          - util-linux
          - curl
        """)

def cloud_init_server_0(token: str) -> str:
    return f"""#cloud-config
{_base_packages()}
runcmd:
  - systemctl enable --now open-iscsi
  - |
    PUBLIC_IP=$(curl -sf http://169.254.169.254/1.0/meta-data/public-ipv4 || \
                curl -sf http://169.254.169.254/latest/meta-data/public-ipv4)
    curl -sfL https://get.k3s.io | \\
      INSTALL_K3S_VERSION="{K3S_VERSION}" \\
      K3S_TOKEN="{token}" \\
      sh -s - server --cluster-init --tls-san "$PUBLIC_IP"
"""

def cloud_init_server_join(token: str, server_ip: str) -> str:
    return f"""#cloud-config
{_base_packages()}
runcmd:
  - systemctl enable --now open-iscsi
  - |
    PUBLIC_IP=$(curl -sf http://169.254.169.254/1.0/meta-data/public-ipv4 || \
                curl -sf http://169.254.169.254/latest/meta-data/public-ipv4)
    curl -sfL https://get.k3s.io | \\
      INSTALL_K3S_VERSION="{K3S_VERSION}" \\
      K3S_TOKEN="{token}" \\
      K3S_URL="https://{server_ip}:6443" \\
      sh -s - server --server "https://{server_ip}:6443" --tls-san "$PUBLIC_IP"
"""

def cloud_init_agent(token: str, server_ip: str, gpu: bool = False) -> str:
    gpu_pkg = "\n  - nvidia-driver-545\n  - nvidia-cuda-toolkit" if gpu else ""
    gpu_cmd = "\n  - nvidia-smi" if gpu else ""
    return f"""#cloud-config
{_base_packages().rstrip()}{gpu_pkg}
runcmd:
  - systemctl enable --now open-iscsi{gpu_cmd}
  - curl -sfL https://get.k3s.io | \\
    INSTALL_K3S_VERSION="{K3S_VERSION}" \\
    K3S_TOKEN="{token}" \\
    K3S_URL="https://{server_ip}:6443" \\
    sh -s - agent
"""

# ── Compute instances ─────────────────────────────────────────────────────────

_common = dict(
    zone=ZONE,
    disk_size=DISK_SIZE_GB,
    security_group_ids=[sg.id],
    ssh_key=exo_ssh_key.name,
    template_id=ubuntu.id,
)

server_0_init = k3s_token.result.apply(cloud_init_server_0)

server_0 = exoscale.ComputeInstance(
    f"{CLUSTER_NAME}-server-0",
    name=f"{CLUSTER_NAME}-server-0",
    type="standard.medium",
    user_data=server_0_init,
    **_common,
)

server_nodes = [server_0]

for i in range(1, DEFAULT_NODES):
    init = pulumi.Output.all(k3s_token.result, server_0.public_ip_address).apply(
        lambda args: cloud_init_server_join(args[0], args[1])
    )
    node = exoscale.ComputeInstance(
        f"{CLUSTER_NAME}-server-{i}",
        name=f"{CLUSTER_NAME}-server-{i}",
        type="standard.medium",
        user_data=init,
        **_common,
    )
    server_nodes.append(node)

gpu_node_list = []

for i in range(GPU_NODES):
    init = pulumi.Output.all(k3s_token.result, server_0.public_ip_address).apply(
        lambda args: cloud_init_agent(args[0], args[1], gpu=True)
    )
    node = exoscale.ComputeInstance(
        f"{CLUSTER_NAME}-gpu-{i}",
        name=f"{CLUSTER_NAME}-gpu-{i}",
        type="gpua30.small",
        user_data=init,
        **_common,
    )
    gpu_node_list.append(node)

# ── Backup bucket ─────────────────────────────────────────────────────────────

backup_bucket = exoscale.StorageBucket(
    f"{CLUSTER_NAME}-backups",
    bucket=f"{CLUSTER_NAME}-backups",
    acl="private",
)

backup_role = exoscale.IamRole(
    f"{CLUSTER_NAME}-backup-role",
    name=f"{CLUSTER_NAME}-backup",
    description=f"Longhorn backup for {CLUSTER_NAME}",
    editable=False,
    permissions=[],
)

backup_key = exoscale.IamApiKey(
    f"{CLUSTER_NAME}-backup-key",
    name=f"{CLUSTER_NAME}-backup-key",
    role_id=backup_role.id,
)

# ── Exports ───────────────────────────────────────────────────────────────────

server_ips = pulumi.Output.all(*[n.public_ip_address for n in server_nodes])
gpu_ips = (
    pulumi.Output.all(*[n.public_ip_address for n in gpu_node_list])
    if gpu_node_list
    else pulumi.Output.from_input([])
)

pulumi.export("cluster_name",     CLUSTER_NAME)
pulumi.export("provider",         "exoscale")
pulumi.export("region",           ZONE)
pulumi.export("server_public_ips", server_ips)
pulumi.export("gpu_public_ips",    gpu_ips)
pulumi.export("default_node_count", DEFAULT_NODES)
pulumi.export("gpu_node_count",    GPU_NODES)
pulumi.export("port",              PORT)
pulumi.export("ssh_private_key",   pulumi.Output.secret(ssh_key.private_key_pem))
pulumi.export("backup_bucket",     backup_bucket.bucket)
pulumi.export("backup_endpoint",   f"https://sos-{ZONE}.exo.io")
pulumi.export("backup_access_key", pulumi.Output.secret(backup_key.key))
pulumi.export("backup_secret_key", pulumi.Output.secret(backup_key.secret))
