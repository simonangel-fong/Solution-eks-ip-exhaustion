# EKS Pod IP Exhaustion

## Problem

As application workloads grow, increasing pod density can consume available subnet IP capacity. In Amazon EKS, IP exhaustion can cause pod scheduling failures, limit cluster scalability, and create availability risks during workload expansion.

> How can pod IP exhaustion in Amazon EKS be mitigated without causing downtime to existing workloads?

## Project Goal

- Build a reproducible EKS lab that simulates pod IP exhaustion
- Develop a practical mitigation strategie zero downtime

## Reference

https://docs.aws.amazon.com/eks/latest/best-practices/ip-opt.html

---

## Background & Context

Amazon EKS commonly uses the Amazon VPC CNI, which assigns VPC-routable IP addresses to pods. This makes pod networking simple and AWS-native, but it also means pod capacity is directly tied to available IP addresses in the worker node subnets.

When subnet IP capacity is exhausted, new pods may fail to start even if the cluster still has available CPU and memory. This project intentionally uses small subnets to reproduce the failure mode, observe the symptoms, and evaluate remediation options.

---

## Infrastructure Specification

### Network

#### IP Capacity Model

```text
Total IPs in subnet
  − 5 AWS-reserved IPs
  − EKS control-plane ENIs
  − worker node primary ENIs
  − VPC CNI warm IP pool
  − pod IP assignments
────────────────────────────
= IPs available for new pods
```

> In this lab, the private subnets are intentionally small so that pod IP exhaustion can be reproduced quickly.

#### VPC

| Spec          | Value          |
| ------------- | -------------- |
| CIDR          | `10.0.0.0/24`  |
| Total IPs     | `256`          |
| Usable IPs    | `251`          |
| Region        | `ca-central-1` |
| DNS hostnames | `Enabled`      |
| DNS support   | `Enabled`      |

> A deliberately small `/24` VPC is used to make pod IP exhaustion reproducible in a short-running lab.

#### Subnets

| Subnet    | CIDR           | AZ              | Usable IPs | Role                                          |
| --------- | -------------- | --------------- | ---------- | --------------------------------------------- |
| Public A  | `10.0.0.0/28`  | `ca-central-1a` | `11`       | Internet Gateway and NAT Gateway              |
| Private A | `10.0.0.16/28` | `ca-central-1a` | `11`       | EKS control-plane ENI, worker nodes, and pods |
| Private B | `10.0.0.32/28` | `ca-central-1b` | `11`       | EKS control-plane ENI, worker nodes, and pods |

> The private `/28` subnets are intentionally undersized to make IP exhaustion observable. This design is for lab simulation only and is not suitable for production EKS workloads.

#### Subnet Tags

| Tag                                  | Applied To      | Value   |
| ------------------------------------ | --------------- | ------- |
| `kubernetes.io/role/elb`             | Public subnet   | `1`     |
| `kubernetes.io/role/internal-elb`    | Private subnets | `1`     |
| `kubernetes.io/cluster/eks-ip-scale` | Private subnets | `owned` |

#### Internet Access

| Spec             | Value                                         |
| ---------------- | --------------------------------------------- |
| Internet Gateway | `1`, attached to the VPC                      |
| NAT Gateway      | `1`, deployed in Public A                     |
| NAT Elastic IP   | `1`                                           |
| Design note      | Single NAT Gateway is used to reduce lab cost |

---

### EKS Cluster

#### Cluster

| Spec                    | Value                         |
| ----------------------- | ----------------------------- |
| Cluster name            | `eks-ip-scale`                |
| Kubernetes version      | `1.36`                        |
| Endpoint public access  | `true`                        |
| Endpoint private access | `true`                        |
| Control-plane subnets   | Private A, Private B          |
| CNI                     | Amazon VPC CNI managed add-on |
| Cluster logs            | `api`, `scheduler`            |

> The cluster uses two private subnets across two Availability Zones to satisfy EKS subnet requirements and keep the lab focused on private subnet IP exhaustion.

#### Managed Node Group

| Spec                | Value                |
| ------------------- | -------------------- |
| Instance type       | `t3.medium`          |
| Capacity type       | `ON_DEMAND`          |
| Min / Max / Desired | `1` / `2` / `4`      |
| Node subnets        | Private A, Private B |
| Max pods per node   | `17`                 |

> `t3.medium` is intentionally used with small private subnets to make pod IP pressure visible quickly. In this lab, pod startup may be limited by both subnet IP capacity and node-level pod density.

#### VPC CNI Configuration

| Environment Variable | Value | Purpose                                         |
| -------------------- | ----- | ----------------------------------------------- |
| `WARM_IP_TARGET`     | `1`   | Keep a minimal warm IP buffer for pod startup   |
| `MINIMUM_IP_TARGET`  | `0`   | Avoid front-loading a larger secondary IP pool  |
| `WARM_ENI_TARGET`    | `0`   | Avoid maintaining an additional unused warm ENI |

> These values reduce unnecessary IP pre-allocation so that actual subnet capacity pressure is easier to observe.

---

## Workload — nginx

| Spec                   | Value                                                                        |
| ---------------------- | ---------------------------------------------------------------------------- |
| Chart                  | `bitnami/nginx`                                                              |
| Release name           | `web`                                                                        |
| Initial replicas       | `1`                                                                          |
| CPU request / limit    | `20m` / `50m`                                                                |
| Memory request / limit | `32Mi` / `64Mi`                                                              |
| Service type           | `ClusterIP`                                                                  |
| Scaling method         | Increase replicas until new pods remain pending or fail during network setup |

> The nginx workload is used as a lightweight test application to create pod density and trigger observable scheduling or networking failure modes.

---

## Terraform File Structure

```txt
eks-ip-scale/
├── infra/
│   ├── 01_variables.tf   # input variables
│   ├── 02_providers.tf   # Terraform block, AWS provider, S3 backend
│   ├── 03_locals.tf      # project name, region, CIDRs, node group sizing
│   ├── 04_outputs.tf     # cluster endpoint, subnet IDs, kubeconfig hints
│   ├── 05_vpc.tf         # VPC, subnets, IGW, NAT, EIP, route tables
│   ├── 06_eks.tf         # IAM, EKS cluster, node group, VPC CNI add-on
│   ├── 07_m_vpc_cni.tf   # mitigation with vpc cidr and cni subnets
│   ├── backend.hcl       # S3 backend config, gitignored
│   └── terraform.tfvars  # variable values, gitignored
└── README.md
```

> Terraform state is stored in S3 using `terraform { backend "s3" {} }`, with backend values supplied through `backend.hcl`.

---

## Reproduction Phases

### Phase 1: Infrastructure

Establish the initial cluster state before scaling the workload.

| Item                    | Value                          |
| ----------------------- | ------------------------------ |
| Node group desired size | `4`                            |
| Initial nginx replicas  | `4`                            |
| Observation target      | Baseline subnet IP consumption |

Check available IP capacity in the private subnets:

```bash
aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=eks-ip-scale" \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table
```

---

### Phase 2: IP Exhaustion

Scale the nginx workload beyond the available pod IP capacity of the private subnets.

```bash
kubectl create deploy web --image=nginx --replicas=0
kubectl scale deploy web --replicas=20
kubectl get deploy
```

Check remaining subnet IP capacity:

```bash
aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=eks-ip-scale" \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table
```

> Expected result: new pods fail to start because the cluster cannot allocate enough pod networking capacity from the private subnets. This demonstrates subnet IP exhaustion as a scaling bottleneck, even when CPU and memory may still be available.

---

## Mitigation Solution: Enhanced Subnet Discovery

This project uses `Enhanced Subnet Discovery` as the mitigation strategy.

Benefits:

- Adds pod IP capacity in place.
- Avoids rebuilding the cluster, recreating node groups, or moving existing pods.

---

### Key Steps

- Confirm subnet discovery is enabled: `ENABLE_SUBNET_DISCOVERY=true`.
- Add a secondary CIDR block to the VPC, for example `/16`.
- Create new CNI subnets.
  - CIDR block: `/18` per subnet.
  - Required tag: `kubernetes.io/role/cni=1`.
  - This tag allows the Amazon VPC CNI to discover and use the subnets for pod IP allocation.

- Additional Subnets

| Subnet        | CIDR           | AZ              | Usable IPs | Role                                          |
| ------------- | -------------- | --------------- | ---------- | --------------------------------------------- |
| Private CNI A | `10.0.0.48/28` | `ca-central-1a` | `11`       | EKS control-plane ENI, worker nodes, and pods |
| Private CNI B | `10.0.0.64/28` | `ca-central-1b` | `11`       | EKS control-plane ENI, worker nodes, and pods |

---

### Verification

Scale the workload after applying the mitigation:

```bash
kubectl create deploy web --image=nginx --replicas=0
kubectl scale deploy web --replicas=20
kubectl get deploy
```

Check available IP capacity in the additional subnets:

```sh
aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=eks-ip-scale" \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table
```
