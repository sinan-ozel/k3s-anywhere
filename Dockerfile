FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl openssh-client git jq unzip \
    && rm -rf /var/lib/apt/lists/*

# Helm
RUN curl -fsSL https://get.helm.sh/helm-v3.17.0-linux-amd64.tar.gz \
    | tar -xz --strip-components=1 -C /usr/local/bin linux-amd64/helm

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# Pulumi
RUN curl -fsSL https://get.pulumi.com | sh
ENV PATH="/root/.pulumi/bin:${PATH}"

# Exoscale CLI
RUN curl -fsSL https://github.com/exoscale/cli/releases/latest/download/exoscale-cli_linux_amd64.tar.gz \
    | tar -xz -C /usr/local/bin exo

# AWS CLI
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY pulumi/     /app/pulumi/
COPY scripts/    /app/scripts/
COPY manifests/  /app/manifests/
COPY helpers/    /app/helpers/
COPY entrypoint.sh /app/

RUN pip install --no-cache-dir -r /app/pulumi/exoscale/requirements.txt \
    && pip install --no-cache-dir -r /app/pulumi/aws/requirements.txt

RUN chmod +x /app/entrypoint.sh \
    && find /app/scripts -name "*.sh" -exec chmod +x {} \; \
    && mkdir -p /app/output

WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
