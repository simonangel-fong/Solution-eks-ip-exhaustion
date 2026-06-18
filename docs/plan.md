# EKS Pod IP Exhaustion Lab

## Problem

As application workloads grow, increasing pod density can consume available subnet IP capacity. In Amazon EKS, IP exhaustion can cause pod scheduling failures, limit cluster scalability, and create availability risks during workload expansion.

> How can pod IP exhaustion in Amazon EKS be detected, analyzed, and remediated without causing downtime to existing workloads?

## Project Goal

- Build a reproducible EKS lab that simulates pod IP exhaustion
- Analyze the impact on pod scheduling, networking, and application availability
- Validate practical remediation strategies for restoring pod scheduling capacity with minimal or zero downtime

---

## Background & Context

Amazon EKS commonly uses the Amazon VPC CNI, which assigns VPC-routable IP addresses to pods. This makes pod networking simple and AWS-native, but it also means pod capacity is directly tied to available IP addresses in the worker node subnets.

When subnet IP capacity is exhausted, new pods may fail to start even if the cluster still has available CPU and memory. This project intentionally uses small subnets to reproduce the failure mode, observe the symptoms, and evaluate remediation options.

---

## Scope

### In Scope

- EKS worker node subnets where pod IPs are allocated
- Amazon VPC CNI IP allocation behavior
- Warm IP and warm ENI configuration
- Subnet and VPC CIDR design
- Terraform-managed AWS infrastructure
- Helm-managed nginx workload
- Subnet IP capacity observation using AWS CLI
- Pod and event analysis using `kubectl`

### Out of Scope

- IPv6 cluster implementation
- Service mesh overhead
- Multi-region or disaster recovery design
- Non-HTTP workloads
- Fargate profiles
- Alternative CNI implementations

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
| CIDR          | `10.0.0.0/26`  |
| Total IPs     | `64`           |
| Usable IPs    | `59`           |
| Region        | `ca-central-1` |
| DNS hostnames | `Enabled`      |
| DNS support   | `Enabled`      |

> A deliberately small `/26` VPC is used to make pod IP exhaustion reproducible in a short-running lab.

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
│   ├── backend.hcl       # S3 backend config, gitignored
│   └── terraform.tfvars  # variable values, gitignored
├── helm/
│   └── nginx-values.yaml # bitnami/nginx values
└── README.md
```

> Terraform state is stored in S3 using `terraform { backend "s3" {} }`, with backend values supplied through `backend.hcl`.

---

## Reproduction Phases

### Phase 1: Baseline

Establish the initial cluster state before scaling the workload.

| Item                    | Value                          |
| ----------------------- | ------------------------------ |
| Node group desired size | `1`                            |
| Initial nginx replicas  | `1`                            |
| Observation target      | Baseline subnet IP consumption |

Check available IP capacity in the private subnets:

```bash
aws ec2 describe-subnets \
  --subnet-ids <private-subnet-a-id> <private-subnet-b-id> \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table
```

Check initial pod placement:

```bash
kubectl get nodes -o wide
kubectl get pods -o wide
kubectl get events --sort-by=.lastTimestamp
```

> This phase confirms the starting IP capacity after EKS control-plane ENIs, worker node ENIs, VPC CNI warm IPs, system pods, and the initial nginx workload are running.

---

### Phase 2: IP Exhaustion

Scale the nginx workload beyond the available pod IP capacity of the private subnets.

| Item               | Value                                           |
| ------------------ | ----------------------------------------------- |
| Scaling method     | `helm upgrade`                                  |
| Target replicas    | `200`                                           |
| Expected limit     | Private subnet IP capacity and node pod density |
| Expected pod state | `Pending` or `ContainerCreating`                |

Scale the workload:

```bash
helm upgrade web bitnami/nginx \
  --set replicaCount=200
```

Observe pod status:

```bash
kubectl get pods -o wide
kubectl describe deploy web-nginx
kubectl get events --sort-by=.lastTimestamp
```

Check for pod sandbox or CNI-related failures:

```bash
kubectl get events \
  --field-selector reason=FailedCreatePodSandBox \
  --sort-by=.lastTimestamp
```

Check remaining subnet IP capacity:

```bash
aws ec2 describe-subnets \
  --subnet-ids <private-subnet-a-id> <private-subnet-b-id> \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table
```

> Expected result: new pods fail to start because the cluster cannot allocate enough pod networking capacity from the private subnets. This demonstrates subnet IP exhaustion as a scaling bottleneck, even when CPU and memory may still be available.

---

## Solution Strategy

This project separates solution options into two categories:

- **Mitigation actions**: steps that can be applied to an existing EKS cluster to recover from or reduce pod IP exhaustion.
- **Bootstrap best practices**: design decisions that should be considered when creating new EKS clusters to prevent future IP exhaustion.

---

## Mitigation Actions for Existing Clusters

| ID  | Solution                              | Description                                                                                                                                            | When to Use             |
| --- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------- |
| M1  | Validate Warm Pool Settings           | Review `WARM_IP_TARGET`, `MINIMUM_IP_TARGET`, and `WARM_ENI_TARGET` to confirm that IPs are not being over-reserved by the VPC CNI.                    | Immediate investigation |
| M2  | Enhanced Subnet Discovery             | Add new subnets in the same Availability Zones, tag them with `kubernetes.io/role/cni=1`, and allow the VPC CNI to use the additional subnet capacity. | Short-term expansion    |
| M3  | Prefix Delegation                     | Enable `ENABLE_PREFIX_DELEGATION` so the VPC CNI assigns `/28` IPv4 prefixes to ENIs, improving pod density per node.                                  | Density improvement     |
| M4  | Custom Networking with Secondary CIDR | Add a secondary VPC CIDR and use `ENIConfig` so pod IPs are allocated from dedicated pod subnets instead of the node subnets.                          | Structural remediation  |

### Recommended Mitigation Path

```text
Immediate   → M1  Validate Warm Pool Settings
              Confirm whether IPs are being wasted through CNI pre-allocation.

Short-term  → M2  Enhanced Subnet Discovery
              Add private subnet capacity without replacing existing workloads.

Medium-term → M4 + M3  Custom Networking + Prefix Delegation
              Move pod IP allocation to dedicated pod subnets and improve pod density.
```

> For this project, the primary remediation path is **M1 → M2 → M4 + M3**. Warm pool tuning is used as an initial validation step, while subnet expansion and custom networking provide the real capacity improvement.

---

## Expected Remediation Validation

After applying a mitigation, validate that pod scheduling capacity has recovered.

| Validation Area          | Command / Signal                                                       |
| ------------------------ | ---------------------------------------------------------------------- |
| Subnet IP capacity       | `AvailableIpAddressCount` increases or stops reaching zero             |
| Pod scheduling           | New nginx pods move from `Pending` or `ContainerCreating` to `Running` |
| Kubernetes events        | CNI or pod sandbox creation failures stop appearing                    |
| Application availability | Existing nginx pods remain available during remediation                |
| Cluster stability        | No node replacement is required for short-term mitigation              |

Example validation commands:

```bash
kubectl get pods -o wide

kubectl get events \
  --sort-by=.lastTimestamp

aws ec2 describe-subnets \
  --subnet-ids <private-subnet-a-id> <private-subnet-b-id> \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table
```

> A successful remediation should restore pod scheduling capacity without disrupting existing running pods.

---

## EKS Bootstrap Best Practices

| ID  | Best Practice                  | Description                                                                                                    | Why It Matters                                    |
| --- | ------------------------------ | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| B1  | Plan Larger Pod Subnets        | Use sufficiently large private subnets for worker nodes and pods instead of undersized `/28` lab subnets.      | Prevents early subnet IP exhaustion               |
| B2  | Use Separate Pod Address Space | Attach a secondary VPC CIDR and allocate pod IPs from dedicated pod subnets when high pod density is expected. | Separates node IP and pod IP consumption          |
| B3  | Enable Prefix Delegation Early | Enable prefix delegation when creating the cluster or node groups to improve pod density per node.             | Reduces ENI/IP allocation pressure                |
| B4  | Consider IPv6 for New Clusters | Create IPv6 EKS clusters for workloads where IPv4 address space is a long-term constraint.                     | Avoids private IPv4 exhaustion for pod networking |
| B5  | Monitor Subnet IP Capacity     | Track `AvailableIpAddressCount`, VPC CNI metrics, and pod scheduling failures.                                 | Detects exhaustion before workloads are impacted  |

> These best practices are most effective when applied during cluster design. They are not all suitable as emergency fixes for a running cluster.

---

## Success Criteria

The project is successful when it demonstrates the full operational flow:

```text
Baseline observed
→ IP exhaustion reproduced
→ failure mode identified through events and subnet IP metrics
→ mitigation applied
→ pod scheduling capacity restored
→ existing workloads remain available
```
