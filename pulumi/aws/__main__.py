import json
import os
import textwrap
import pulumi
import pulumi_aws as aws
import pulumi_tls as tls
import pulumi_random as random

CLUSTER_NAME   = os.environ["CLUSTER_NAME"]
DEFAULT_NODES  = int(os.environ.get("DEFAULT_NODE_COUNT", "1"))
GPU_NODES      = int(os.environ.get("GPU_NODE_COUNT", "0"))
PORT           = int(os.environ["PORT"])
# Comma-separated extra TCP ports to open in the security group, e.g. for a
# port the configurable PORT doesn't cover (ACME HTTP-01 on 80, TLS on 443).
EXTRA_PORTS    = [int(p) for p in os.environ.get("PORTS", "").split(",") if p.strip()]
REGION         = os.environ["AWS_REGION"]
K3S_VERSION    = os.environ.get("K3S_VERSION", "v1.31.4+k3s1")
DISK_SIZE_GB   = int(os.environ.get("DISK_SIZE_GB", "25"))
ELASTIC_IP     = int(os.environ.get("ELASTIC_IP_COUNT", os.environ.get("ELASTIC_IP", "0")))
# S3 bucket names are global. If <CLUSTER_NAME>-backups is already taken by
# another account, set BUCKET_PREFIX to a unique value (e.g. your org name
# followed by a dash). The provisioner IAM policy in setup.sh covers *-backups,
# so the prefix does not require a setup rerun.
BUCKET_PREFIX  = os.environ.get("BUCKET_PREFIX", "")

# ── SSH key ───────────────────────────────────────────────────────────────────

ssh_key = tls.PrivateKey(f"{CLUSTER_NAME}-ssh-key", algorithm="RSA", rsa_bits=4096)

key_pair = aws.ec2.KeyPair(
    f"{CLUSTER_NAME}-keypair",
    key_name=f"{CLUSTER_NAME}-key",
    public_key=ssh_key.public_key_openssh,
)

# ── k3s cluster token ─────────────────────────────────────────────────────────

k3s_token = random.RandomPassword(
    f"{CLUSTER_NAME}-k3s-token",
    length=32,
    special=False,
)

# ── VPC ───────────────────────────────────────────────────────────────────────

vpc = aws.ec2.Vpc(
    f"{CLUSTER_NAME}-vpc",
    cidr_block="10.0.0.0/16",
    enable_dns_hostnames=True,
    enable_dns_support=True,
    tags={"Name": f"{CLUSTER_NAME}-vpc"},
)

subnet = aws.ec2.Subnet(
    f"{CLUSTER_NAME}-subnet",
    vpc_id=vpc.id,
    cidr_block="10.0.0.0/24",
    availability_zone=f"{REGION}a",
    map_public_ip_on_launch=True,
    tags={"Name": f"{CLUSTER_NAME}-subnet"},
)

igw = aws.ec2.InternetGateway(
    f"{CLUSTER_NAME}-igw",
    vpc_id=vpc.id,
    tags={"Name": f"{CLUSTER_NAME}-igw"},
)

route_table = aws.ec2.RouteTable(
    f"{CLUSTER_NAME}-rt",
    vpc_id=vpc.id,
    routes=[aws.ec2.RouteTableRouteArgs(cidr_block="0.0.0.0/0", gateway_id=igw.id)],
    tags={"Name": f"{CLUSTER_NAME}-rt"},
)

aws.ec2.RouteTableAssociation(
    f"{CLUSTER_NAME}-rta",
    subnet_id=subnet.id,
    route_table_id=route_table.id,
)

# ── Security group ────────────────────────────────────────────────────────────
# PORT plus any PORTS extras, deduplicated, each opened to 0.0.0.0/0.
_web_ports = sorted({PORT, *EXTRA_PORTS})

sg = aws.ec2.SecurityGroup(
    f"{CLUSTER_NAME}-sg",
    name=f"{CLUSTER_NAME}-sg",
    description=f"k3s-anywhere {CLUSTER_NAME}",
    vpc_id=vpc.id,
    ingress=[
        aws.ec2.SecurityGroupIngressArgs(from_port=22,    to_port=22,    protocol="tcp", cidr_blocks=["0.0.0.0/0"]),
        aws.ec2.SecurityGroupIngressArgs(from_port=6443,  to_port=6443,  protocol="tcp", cidr_blocks=["0.0.0.0/0"]),
        *[
            aws.ec2.SecurityGroupIngressArgs(from_port=p, to_port=p, protocol="tcp", cidr_blocks=["0.0.0.0/0"])
            for p in _web_ports
        ],
        aws.ec2.SecurityGroupIngressArgs(from_port=8472,  to_port=8472,  protocol="udp", cidr_blocks=["0.0.0.0/0"]),
        aws.ec2.SecurityGroupIngressArgs(from_port=9500,  to_port=9520,  protocol="tcp", cidr_blocks=["0.0.0.0/0"]),
        aws.ec2.SecurityGroupIngressArgs(from_port=10250, to_port=10250, protocol="tcp", cidr_blocks=["0.0.0.0/0"]),
        # etcd peer/client — required for k3s HA embedded etcd, VPC-only
        aws.ec2.SecurityGroupIngressArgs(from_port=2379,  to_port=2380,  protocol="tcp", cidr_blocks=["10.0.0.0/16"]),
    ],
    egress=[
        aws.ec2.SecurityGroupEgressArgs(from_port=0, to_port=0, protocol="-1", cidr_blocks=["0.0.0.0/0"]),
    ],
    tags={"Name": f"{CLUSTER_NAME}-sg"},
)

# ── AMI ───────────────────────────────────────────────────────────────────────

ubuntu_ami = aws.ec2.get_ami_output(
    most_recent=True,
    owners=["099720109477"],
    filters=[
        aws.ec2.GetAmiFilterArgs(name="name",              values=["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]),
        aws.ec2.GetAmiFilterArgs(name="virtualization-type", values=["hvm"]),
        aws.ec2.GetAmiFilterArgs(name="architecture",       values=["x86_64"]),
    ],
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

def cloud_init_server_0(token: str, extra_san: str = "") -> str:
    eip_san = f"--tls-san {extra_san}" if extra_san else ""
    return f"""#cloud-config
{_base_packages()}
runcmd:
  - systemctl enable --now open-iscsi
  - |
    IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
    PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
    PUBLIC_DNS=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-hostname || true)
    [ -n "$PUBLIC_DNS" ] && EXTRA_SAN="--tls-san $PUBLIC_DNS" || EXTRA_SAN=""
    curl -sfL https://get.k3s.io | \\
      INSTALL_K3S_VERSION="{K3S_VERSION}" \\
      K3S_TOKEN="{token}" \\
      sh -s - server --cluster-init --tls-san "$PUBLIC_IP" {eip_san} $EXTRA_SAN
"""

def cloud_init_server_join(token: str, server_ip: str) -> str:
    return f"""#cloud-config
{_base_packages()}
runcmd:
  - systemctl enable --now open-iscsi
  - |
    IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
    PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
    PUBLIC_DNS=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-hostname || true)
    [ -n "$PUBLIC_DNS" ] && EXTRA_SAN="--tls-san $PUBLIC_DNS" || EXTRA_SAN=""
    until nc -z {server_ip} 6443 2>/dev/null; do sleep 5; done
    curl -sfL https://get.k3s.io | \\
      INSTALL_K3S_VERSION="{K3S_VERSION}" \\
      K3S_TOKEN="{token}" \\
      K3S_URL="https://{server_ip}:6443" \\
      sh -s - server --server "https://{server_ip}:6443" --tls-san "$PUBLIC_IP" $EXTRA_SAN
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
    ami=ubuntu_ami.id,
    subnet_id=subnet.id,
    vpc_security_group_ids=[sg.id],
    key_name=key_pair.key_name,
    root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(volume_size=DISK_SIZE_GB, volume_type="gp3"),
)

eip = aws.ec2.Eip(
    f"{CLUSTER_NAME}-eip",
    domain="vpc",
    tags={"Name": f"{CLUSTER_NAME}-eip", "k3s-anywhere": CLUSTER_NAME},
) if ELASTIC_IP else None

server_0_init = (
    pulumi.Output.all(k3s_token.result, eip.public_ip).apply(
        lambda args: cloud_init_server_0(args[0], extra_san=args[1])
    )
    if eip
    else k3s_token.result.apply(cloud_init_server_0)
)

server_0 = aws.ec2.Instance(
    f"{CLUSTER_NAME}-server-0",
    instance_type="t3.medium",
    user_data=server_0_init,
    tags={"Name": f"{CLUSTER_NAME}-server-0", "k3s-anywhere": CLUSTER_NAME},
    **_common,
)

# Elastic IP replaces the instance's dynamic public IP the moment it is
# associated, so any node that joins afterward must dial the EIP, not
# server_0.public_ip (which is no longer routable once associated).
eip_assoc = aws.ec2.EipAssociation(
    f"{CLUSTER_NAME}-eip-assoc",
    instance_id=server_0.id,
    allocation_id=eip.id,
) if eip else None

server_0_address = eip.public_ip if eip else server_0.public_ip
_join_opts = pulumi.ResourceOptions(depends_on=[eip_assoc]) if eip_assoc else None

server_nodes = [server_0]

for i in range(1, DEFAULT_NODES):
    init = pulumi.Output.all(k3s_token.result, server_0_address).apply(
        lambda args: cloud_init_server_join(args[0], args[1])
    )
    node = aws.ec2.Instance(
        f"{CLUSTER_NAME}-server-{i}",
        instance_type="t3.medium",
        user_data=init,
        tags={"Name": f"{CLUSTER_NAME}-server-{i}", "k3s-anywhere": CLUSTER_NAME},
        opts=_join_opts,
        **_common,
    )
    server_nodes.append(node)

gpu_node_list = []

for i in range(GPU_NODES):
    init = pulumi.Output.all(k3s_token.result, server_0_address).apply(
        lambda args: cloud_init_agent(args[0], args[1], gpu=True)
    )
    node = aws.ec2.Instance(
        f"{CLUSTER_NAME}-gpu-{i}",
        instance_type="g4dn.2xlarge",
        user_data=init,
        tags={"Name": f"{CLUSTER_NAME}-gpu-{i}", "k3s-anywhere": CLUSTER_NAME},
        opts=_join_opts,
        **_common,
    )
    gpu_node_list.append(node)

# ── Backup bucket ─────────────────────────────────────────────────────────────

backup_bucket = aws.s3.BucketV2(
    f"{CLUSTER_NAME}-backups",
    bucket=f"{BUCKET_PREFIX}{CLUSTER_NAME}-backups",
    tags={"k3s-anywhere": CLUSTER_NAME},
)

aws.s3.BucketPublicAccessBlock(
    f"{CLUSTER_NAME}-backups-block",
    bucket=backup_bucket.id,
    block_public_acls=True,
    block_public_policy=True,
    ignore_public_acls=True,
    restrict_public_buckets=True,
)

backup_user = aws.iam.User(
    f"{CLUSTER_NAME}-backup-user",
    name=f"{CLUSTER_NAME}-backup",
    tags={"k3s-anywhere": CLUSTER_NAME},
)

backup_policy_doc = backup_bucket.arn.apply(lambda arn: json.dumps({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"],
        "Resource": [arn, f"{arn}/*"],
    }],
}))

aws.iam.UserPolicy(
    f"{CLUSTER_NAME}-backup-policy",
    user=backup_user.name,
    policy=backup_policy_doc,
)

backup_access_key = aws.iam.AccessKey(
    f"{CLUSTER_NAME}-backup-key",
    user=backup_user.name,
)

# ── Exports ───────────────────────────────────────────────────────────────────

server_ips = pulumi.Output.all(*[n.public_ip for n in server_nodes])
server_dns = pulumi.Output.all(*[n.public_dns for n in server_nodes])
gpu_ips = (
    pulumi.Output.all(*[n.public_ip for n in gpu_node_list])
    if gpu_node_list
    else pulumi.Output.from_input([])
)

pulumi.export("cluster_name",       CLUSTER_NAME)
pulumi.export("provider",           "aws")
pulumi.export("region",             REGION)
pulumi.export("server_public_ips",  server_ips)
pulumi.export("server_public_dns",  server_dns)
pulumi.export("elastic_ip",         eip.public_ip if eip else "")
pulumi.export("gpu_public_ips",    gpu_ips)
pulumi.export("default_node_count", DEFAULT_NODES)
pulumi.export("gpu_node_count",    GPU_NODES)
pulumi.export("port",              PORT)
pulumi.export("ssh_private_key",   pulumi.Output.secret(ssh_key.private_key_pem))
pulumi.export("backup_bucket",     backup_bucket.bucket)
pulumi.export("backup_endpoint",   "")
pulumi.export("backup_access_key", pulumi.Output.secret(backup_access_key.id))
pulumi.export("backup_secret_key", pulumi.Output.secret(backup_access_key.secret))
