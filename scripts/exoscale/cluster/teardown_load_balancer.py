#!/usr/bin/env python3
"""
Delete cloud-provisioned load balancers before pulumi destroy.
For Exoscale with ServiceLB (klipper-lb), external LBs are not created by default.
This script is a safety net in case workloads deployed LoadBalancer services.
"""
import os
import subprocess
import sys


def main():
    cluster_name = os.environ.get("CLUSTER_NAME", "")
    kubeconfig = f"/app/output/{cluster_name}-kubeconfig.yaml"

    if not os.path.exists(kubeconfig):
        print("No kubeconfig found — skipping LoadBalancer cleanup.")
        return

    result = subprocess.run(
        [
            "kubectl", "--kubeconfig", kubeconfig,
            "get", "svc", "--all-namespaces",
            "-o", "jsonpath={range .items[?(@.spec.type=='LoadBalancer')]}{.metadata.namespace}/{.metadata.name}\\n{end}",
        ],
        capture_output=True,
        text=True,
    )

    services = [s for s in result.stdout.strip().splitlines() if s]
    if not services:
        print("No LoadBalancer services found.")
        return

    for svc in services:
        namespace, name = svc.split("/", 1)
        print(f"Deleting LoadBalancer service {namespace}/{name}...")
        subprocess.run(
            ["kubectl", "--kubeconfig", kubeconfig, "delete", "svc", "-n", namespace, name],
            check=False,
        )

    print("LoadBalancer cleanup complete.")


if __name__ == "__main__":
    main()
