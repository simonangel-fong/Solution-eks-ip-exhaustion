# Product Requirements Document

# eks-ip-exhaustion-lab

**Version:** 1.0  
**Status:** Draft  
**Date:** June 2026

---

## 1. Overview

### 1.1 Project Title

`solution-eks-ip-exhaustion`

### 1.2 Problem Statement

An EKS cluster using Amazon VPC CNI exhausts its subnet IPv4 address pool under HPA-driven pod scaling, blocking further horizontal scale-out with zero or minimal downtime tolerance.

With Amazon VPC CNI, every pod receives a real, routable VPC IP address. This makes pods first-class VPC citizens but causes IP pools to drain faster than expected — compounded by CNI warm pool pre-allocation, HPA scale-up overlap, and a hard subnet CIDR ceiling that cannot be resized once set.

### 1.3 Goal

Build a reproducible lab environment that simulates IP exhaustion on EKS, observes the failure mode, and validates a prioritized set of remediation solutions. The output is a standardized, reusable reference that can be adopted as a best-practice pattern for production clusters.

---

## 2. Background & Context

### 2.1 Why This Happens

```
Total usable IPs in subnet
  − 5 IPs reserved by AWS per subnet
  − IPs assigned to nodes (ENIs)
  − IPs pre-warmed by VPC CNI warm pool (held but unused)
  − IPs assigned to running pods
─────────────────────────────────
= IPs actually available for new pods
```

IP consumption is higher than steady-state pod count suggests because:

- VPC CNI pre-warms IPs via `WARM_IP_TARGET` and `WARM_ENI_TARGET` — consuming IPs before pods exist
- HPA scale-up creates new pods while terminating pods still hold their IPs through the connection drain window
- Subnet CIDR is immutable — it cannot be resized, only supplemented

### 2.2 Three Distinct Sub-Problems

**Sub-problem 1 — Static Capacity Ceiling**
The subnet is a hard, fixed boundary. Once exhausted, the CNI cannot allocate, pods remain `Pending`, and HPA cannot fulfill its intent. There is no graceful degradation.

**Sub-problem 2 — HPA Amplifies the Drain Rate**
During a scale-up event, new pods request IPs immediately while terminating pods hold their IPs until the drain period ends. Peak IP consumption is higher than steady-state pod count implies.

**Sub-problem 3 — Warm Pool Creates Hidden Consumption**
VPC CNI pre-allocates IPs on nodes that are held but unused, invisible to `kubectl get pods`. In a small subnet, this hidden reservation can account for 20–40% of total IP consumption.

### 2.3 Assumptions

| Assumption             | Value                                  |
| ---------------------- | -------------------------------------- |
| CNI                    | Amazon VPC CNI (default)               |
| Constraint scope       | Subnet-level (extendable to VPC-level) |
| Pod type               | Stateless, HPA-managed                 |
| Scaling trigger        | HPA (CPU-based)                        |
| Infrastructure control | Full (VPC, subnets, node groups)       |
| IPv6                   | Not enabled in this project scope      |

---

## 3. Scope

### In Scope

- EKS node group subnets — where pod IPs are drawn from
- VPC CNI IP allocation behavior — warm pool, ENI attachment
- HPA scaling behavior — speed, overlap, IP churn
- Subnet and VPC CIDR design — current and expandable
- Terraform-managed infrastructure
- Helm-managed workloads (nginx)

### Out of Scope

- IPv6 dual-stack (noted as long-term recommendation, not implemented)
- Service mesh overhead
- Multi-region or DR scenarios
- Non-HTTP workloads
- Fargate nodes

---

## 4. Infrastructure Specification

### 4.1 VPC

| Spec                 | Value          |
| -------------------- | -------------- |
| CIDR                 | `10.0.0.0/24`  |
| Enable DNS hostnames | `true`         |
| Enable DNS support   | `true`         |
| Region               | `ca-central-1` |

> Deliberately small /24 (256 IPs, 251 usable) to make exhaustion reproducible quickly.

### 4.2 Subnets

| Spec                                  | Value                        |
| ------------------------------------- | ---------------------------- |
| Count                                 | 2 (multi-AZ minimum for EKS) |
| Subnet A CIDR                         | `10.0.0.0/25` (126 usable)   |
| Subnet B CIDR                         | `10.0.0.128/25` (126 usable) |
| AZ A                                  | `ca-central-1a`              |
| AZ B                                  | `ca-central-1b`              |
| Public IP on launch                   | `false`                      |
| Tag `kubernetes.io/role/internal-elb` | `1`                          |
| Tag `kubernetes.io/cluster/<name>`    | `owned`                      |

### 4.3 Internet Gateway & NAT

| Spec                  | Value                                    |
| --------------------- | ---------------------------------------- |
| Internet Gateway      | 1, attached to VPC                       |
| NAT Gateway           | 1, in Subnet A (single NAT for lab cost) |
| NAT Elastic IP        | 1                                        |
| Public Subnet for NAT | `10.0.0.0/26` carved from Subnet A       |

### 4.4 EKS Cluster

| Spec                    | Value                          |
| ----------------------- | ------------------------------ |
| Cluster name            | `eks-ip-exhaustion`            |
| Kubernetes version      | `1.36`                         |
| Endpoint public access  | `true`                         |
| Endpoint private access | `true`                         |
| CNI                     | Amazon VPC CNI (managed addon) |
| Cluster log types       | `api`, `scheduler`             |

### 4.5 EKS Node Group

| Spec                | Value                                     |
| ------------------- | ----------------------------------------- |
| Instance type       | `t3.medium`                               |
| Capacity type       | `ON_DEMAND`                               |
| Min / Max / Desired | `1` / `3` / `2`                           |
| Max pods per node   | `17` (default for t3.medium with VPC CNI) |

> `t3.medium` supports 3 ENIs × 6 IPs = 18 IPs, minus 1 for the node itself = 17 max pods. With 3 nodes max: theoretical pod ceiling = 51. The IP pool exhausts before this.

### 4.6 VPC CNI Configuration (Addon env vars)

| Spec                | Value                                                 |
| ------------------- | ----------------------------------------------------- |
| `WARM_IP_TARGET`    | `5` (default — intentionally verbose for observation) |
| `MINIMUM_IP_TARGET` | `3`                                                   |
| `WARM_ENI_TARGET`   | `1`                                                   |

### 4.7 Workload — nginx (Helm)

| Spec                   | Value            |
| ---------------------- | ---------------- |
| Chart                  | `bitnami/nginx`  |
| Release name           | `nginx-lab`      |
| Initial replicas       | `2`              |
| CPU request / limit    | `100m` / `200m`  |
| Memory request / limit | `64Mi` / `128Mi` |
| Service type           | `ClusterIP`      |

### 4.8 HPA

| Spec                            | Value           |
| ------------------------------- | --------------- |
| Min replicas                    | `2`             |
| Max replicas                    | `80`            |
| Scale trigger                   | CPU utilization |
| Target CPU utilization          | `20%`           |
| Scale-up stabilization window   | `0s`            |
| Scale-down stabilization window | `30s`           |

> CPU threshold at 20% ensures a trivial load test triggers aggressive scale-out. Max replicas at 80 far exceeds the IP ceiling — guaranteeing exhaustion.

### 4.9 Load Generator

| Spec     | Value                                     |
| -------- | ----------------------------------------- |
| Tool     | `kubectl run` with `busybox` or `k6` job  |
| Behavior | Infinite HTTP loop to spike CPU above 20% |

---

## 5. Terraform File Structure

```
eks-ip-exhaustion-lab/
├── terraform/
│   ├── main.tf          # provider, backend
│   ├── vpc.tf           # VPC, subnets, IGW, NAT, route tables
│   ├── eks.tf           # cluster, node group, IAM roles
│   ├── addons.tf        # VPC CNI addon with env var config
│   └── outputs.tf       # cluster endpoint, subnet IDs, kubeconfig
├── helm/
│   └── nginx-values.yaml
├── k8s/
│   └── hpa.yaml
└── README.md
```

---

## 6. Reproduction Phases

### Phase 1 — Baseline

Nodes: 2, Pods: ~2–4. Expected IP consumption: ~30–40 (nodes + warm pool pre-allocation).

### Phase 2 — Load Applied, HPA Fires

HPA creates pods rapidly. VPC CNI allocates real IPs per pod. IP consumption climbs toward the 252-IP ceiling.

### Phase 3 — Exhaustion

New pods remain in `Pending` state. CNI reports allocation failure. HPA scaling intent is blocked silently while the cluster appears healthy.

### Phase 4 — Observe

```bash
kubectl get events --field-selector reason=FailedCreatePodSandBox
aws ec2 describe-subnets  # AvailableIpAddressCount = 0
```

---

## 7. Solution Options

The following solutions are evaluated and prioritized. Each will be implemented as a separate lab branch with before/after metrics.

### 7.1 Solution Candidates

| ID  | Name                               | Description                                                                                                                            |
| --- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| S1  | Warm Pool Tuning                   | Reduce `WARM_IP_TARGET` and `WARM_ENI_TARGET` to free hidden pre-allocated IPs within the existing subnet                              |
| S2  | Prefix Delegation                  | Enable `ENABLE_PREFIX_DELEGATION` so each ENI holds a /28 prefix (16 IPs) instead of individual IPs, increasing pod density per node   |
| S3  | Custom Networking (Secondary CIDR) | Assign pod IPs from a secondary VPC CIDR (e.g. CG-NAT `100.64.0.0/10`) via ENIConfig, separating pod IPs from node IPs                 |
| S4  | Enhanced Subnet Discovery          | Tag new subnets with `kubernetes.io/role/cni=1` so VPC CNI automatically spills new ENIs into them without touching existing workloads |
| S5  | Alternative CNI (Cilium)           | Replace VPC CNI with Cilium overlay networking, scoping pod IPs to an internal address space that does not consume VPC IPs             |
| S6  | IPv6 Dual-Stack                    | Enable IPv6 at cluster creation, giving pods IPv6 addresses and eliminating the RFC1918 IPv4 ceiling entirely                          |
| S7  | Private NAT + CG-NAT Subnets       | Place nodes and pods in large non-routable CG-NAT subnets and route traffic via a private NAT gateway                                  |

### 7.2 Priority Ranking

| Rank | ID  | Solution                           | Rationale                                                                                                      |
| ---- | --- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| 1    | S1  | Warm Pool Tuning                   | Zero cost, zero risk, config-only. Always the first step — buys time for any structural fix                    |
| 2    | S4  | Enhanced Subnet Discovery          | Non-disruptive, additive, Terraform-friendly. Best fit for the zero-downtime goal                              |
| 3    | S3  | Custom Networking + Secondary CIDR | Structural fix for VPC-constrained environments. Well-documented AWS pattern, reusable at enterprise scale     |
| 4    | S2  | Prefix Delegation                  | Strong efficiency multiplier when combined with S3 or S4 — not a standalone ceiling fix                        |
| 5    | S7  | Private NAT + CG-NAT Subnets       | Suitable for large-scale multi-VPC architectures; introduces NAT cost and routing complexity                   |
| 6    | S5  | Alternative CNI (Cilium)           | Powerful structural fix but carries highest migration risk and loses AWS-native integrations                   |
| 7    | S6  | IPv6 Dual-Stack                    | AWS's recommended long-term answer; only practical for new clusters or teams ready for org-level IPv6 adoption |

### 7.3 Recommended Layered Approach

```
Immediate   →  S1  Warm Pool Tuning          stop the bleeding, no risk
Short-term  →  S4  Enhanced Subnet Discovery  non-disruptive expansion
Medium-term →  S3 + S2  Custom Net + PD       structural fix + density
Long-term   →  S6  IPv6 for new clusters      the real long-term answer
```

---

## 8. Success Criteria

| #   | Criterion                                   | Measurement                                                                       |
| --- | ------------------------------------------- | --------------------------------------------------------------------------------- |
| 1   | Scaling never blocked by IP exhaustion      | No pod remains `Pending` due to CNI allocation failure under test load            |
| 2   | Zero or minimal downtime during remediation | Pod disruption budget respected; no unplanned service interruption                |
| 3   | IP utilization stays below safe threshold   | `AvailableIpAddressCount` stays above 20% at peak HPA scale                       |
| 4   | Solution is repeatable                      | Terraform + Helm code is parameterized and deployable from scratch                |
| 5   | Trade-offs are explicitly measured          | Cost delta, pod start latency, and operational complexity documented per solution |

---

## 9. Trade-off Evaluation Framework

Each solution will be benchmarked against the following dimensions:

| Dimension               | Description                                                            |
| ----------------------- | ---------------------------------------------------------------------- |
| **Cost**                | Additional AWS resource cost (NAT GW, extra subnets, Transit GW)       |
| **Complexity**          | Operational and configuration overhead to implement and maintain       |
| **Downtime risk**       | Likelihood and duration of disruption during rollout                   |
| **IP efficiency**       | How effectively the solution uses available IP space                   |
| **AWS supportability**  | Whether the solution is fully supported by AWS or community-maintained |
| **Scalability ceiling** | How far the solution scales before the next constraint is hit          |

---

## 10. Out of Scope for v1

- IPv6 implementation (noted as long-term, tracked for v2)
- Multi-VPC or Transit Gateway connectivity
- Fargate node support
- Custom CNI (Cilium) full migration — noted as a valid path, tracked for v2
- Cost optimization beyond the CNI/subnet layer

---

## 11. References

- [AWS EKS Best Practices — IP Optimization](https://docs.aws.amazon.com/eks/latest/best-practices/ip-opt.html)
- [AWS Blog — Automating Custom Networking to Solve IPv4 Exhaustion](https://aws.amazon.com/blogs/containers/automating-custom-networking-to-solve-ipv4-exhaustion-in-amazon-eks/)
- [AWS Blog — Addressing IPv4 Exhaustion Using Private NAT Gateways](https://aws.amazon.com/blogs/containers/addressing-ipv4-address-exhaustion-in-amazon-eks-clusters-using-private-nat-gateways/)
- [AWS Blog — Amazon VPC CNI Introduces Enhanced Subnet Discovery](https://aws.amazon.com/blogs/containers/amazon-vpc-cni-introduces-enhanced-subnet-discovery/)
- [Adevinta — How We Avoided an Outage Caused by Running Out of IPs in EKS](https://adevinta.com/techblog/how-we-avoided-an-outage-caused-by-running-out-of-ips-in-eks/)
- [AWS EKS Best Practices Guide — IP Optimization Strategies](https://aws.github.io/aws-eks-best-practices/networking/ip-optimization-strategies/)
