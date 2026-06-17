# Implementation Plan — eks-ip-exhaustion-lab

Layered build plan for the lab described in [prd.md](prd.md). Each phase has a **Build** step and a **Verify** step. Infrastructure is verified with the AWS CLI; Kubernetes resources are verified with `kubectl`.

---

## Decisions

| Topic | Decision | Source |
|---|---|---|
| Kubernetes version | `1.36` (GA on EKS) | [prd.md:135](prd.md#L135) |
| State backend | Local `terraform.tfstate` | Lab scope |
| NAT subnet placement | Split Subnet A `/25` → public `/26` + private `/26`; Subnet B stays `/25` | Resolves overlap in [prd.md:113-127](prd.md#L113-L127) |

### Revised subnet layout

| Subnet | CIDR | AZ | Usable IPs | Role |
|---|---|---|---|---|
| Public A (NAT) | `10.0.0.0/26` | `ca-central-1a` | 59 | NAT GW + IGW |
| Private A | `10.0.0.64/26` | `ca-central-1a` | 59 | EKS nodes/pods |
| Private B | `10.0.0.128/25` | `ca-central-1b` | 123 | EKS nodes/pods |

---

## Phase 1 — VPC

**Build**

- [terraform/main.tf](../terraform/main.tf): AWS provider, `ca-central-1`, local backend, `required_providers`.
- [terraform/vpc.tf](../terraform/vpc.tf): VPC `10.0.0.0/24`, DNS hostnames + support on.
- `terraform init`
- `terraform plan`
- `terraform apply`

**Verify**

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=eks-ip-exhaustion" \
  --query "Vpcs[].{ID:VpcId,CIDR:CidrBlock,DNS:EnableDnsSupport}"
```

Expect: 1 VPC, CIDR `10.0.0.0/24`, DNS `true`.

---

## Phase 2 — Subnets, Route Tables, Networking

**Build**

- Public subnet `10.0.0.0/26` in `ca-central-1a` for NAT.
- Private subnet `10.0.0.64/26` in `ca-central-1a` for EKS.
- Private subnet `10.0.0.128/25` in `ca-central-1b` for EKS.
- EKS tags (`kubernetes.io/role/internal-elb=1`, `kubernetes.io/cluster/<name>=owned`) on both private subnets.
- IGW attached to VPC.
- NAT GW + EIP in the public subnet.
- Public RT (`0.0.0.0/0 → igw`), private RT (`0.0.0.0/0 → nat`), associations.

**Verify**

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query "Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Free:AvailableIpAddressCount}"

aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=<vpc-id>" \
  --query "NatGateways[].{ID:NatGatewayId,State:State}"

aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query "RouteTables[].{ID:RouteTableId,Routes:Routes[].DestinationCidrBlock}"
```

Expect: 3 subnets with expected CIDRs/AZs, NAT `available`, private RT has `0.0.0.0/0 → nat-...`, public RT has `0.0.0.0/0 → igw-...`.

---

## Phase 3 — EKS Cluster + Node Group + Add-ons

**Build**

- [terraform/eks.tf](../terraform/eks.tf): cluster `eks-ip-exhaustion`, k8s `1.36`, IAM roles, endpoint public + private access, log types `api`, `scheduler`.
- Node group `t3.medium`, capacity `ON_DEMAND`, min/max/desired `1/3/2`, attached to both private subnets.
- [terraform/addons.tf](../terraform/addons.tf): VPC CNI managed addon with env vars:
  - `WARM_IP_TARGET=5`
  - `MINIMUM_IP_TARGET=3`
  - `WARM_ENI_TARGET=1`
- `aws eks update-kubeconfig --region ca-central-1 --name eks-ip-exhaustion`

**Verify**

```bash
aws eks describe-cluster --name eks-ip-exhaustion \
  --query "cluster.{Status:status,Version:version,Endpoint:endpoint}"

aws eks describe-nodegroup \
  --cluster-name eks-ip-exhaustion --nodegroup-name <ng> \
  --query "nodegroup.{Status:status,Scaling:scalingConfig}"

aws eks describe-addon \
  --cluster-name eks-ip-exhaustion --addon-name vpc-cni \
  --query "addon.{Status:status,Version:addonVersion}"

kubectl get nodes -o wide
kubectl -n kube-system get ds aws-node
kubectl -n kube-system get ds aws-node \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq
```

Expect: cluster `ACTIVE`, node group `ACTIVE`, addon `ACTIVE`, 2 Ready nodes, `aws-node` env shows the configured warm-pool values.

---

## Phase 4 — Workload (Single Pod)

**Build**

- [helm/nginx-values.yaml](../helm/nginx-values.yaml): bitnami/nginx, `replicaCount: 1`, CPU `100m`/`200m`, memory `64Mi`/`128Mi`, service `ClusterIP`.
- `helm repo add bitnami https://charts.bitnami.com/bitnami`
- `helm install nginx-lab bitnami/nginx -f helm/nginx-values.yaml`

**Verify**

```bash
kubectl get pods -o wide
kubectl get svc nginx-lab
kubectl describe pod -l app.kubernetes.io/name=nginx | grep -E "IP:|Node:"

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query "Subnets[].{CIDR:CidrBlock,Free:AvailableIpAddressCount}"
```

Expect: 1 pod `Running` with a VPC IP, baseline `AvailableIpAddressCount` recorded for both private subnets.

---

## Phase 5 — Scale Out + HPA

**Build**

- `kubectl scale deploy/nginx-lab --replicas=2` and confirm both pods schedule.
- [k8s/hpa.yaml](../k8s/hpa.yaml): min `2`, max `80`, CPU target `20%`, scale-up stabilization `0s`, scale-down `30s`.
- `kubectl apply -f k8s/hpa.yaml`

**Verify**

```bash
kubectl get deploy nginx-lab
kubectl get hpa nginx-lab
kubectl top pods
```

Expect: 2 pods `Running`, HPA shows `<n>%/20%` (not `<unknown>`), metrics-server reachable.

---

## Phase 6 — Exhaust + Observe

**Build**

- Load generator:
  ```bash
  kubectl run loadgen --image=busybox --restart=Never -- \
    /bin/sh -c "while true; do wget -q -O- http://nginx-lab; done"
  ```
  (or a `k6` Job).

**Verify**

```bash
kubectl get hpa nginx-lab -w
kubectl get pods -o wide
kubectl get events --field-selector reason=FailedCreatePodSandBox \
  --sort-by=.lastTimestamp

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query "Subnets[].{CIDR:CidrBlock,Free:AvailableIpAddressCount}"

kubectl -n kube-system logs ds/aws-node \
  | grep -iE "InsufficientFreeAddresses|failed to allocate"
```

Expect: pods in `Pending`, `FailedCreatePodSandBox` events present, `AvailableIpAddressCount` near `0`. Save all output to `docs/evidence/baseline/`.

---

## Phase 7 — Solutions (one branch per ID)

For each solution: create a branch, apply the change, redeploy, repeat the Phase 6 verification, save evidence to `docs/evidence/<solution>/`, and fill the §9 trade-off table from the PRD.

### 7a — `solution/s1-warm-pool`

**Build:** set VPC CNI env `WARM_IP_TARGET=1`, `WARM_ENI_TARGET=0` (addon update).

**Verify:**
```bash
kubectl -n kube-system get ds aws-node \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | jq
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
  --query "Subnets[].{CIDR:CidrBlock,Free:AvailableIpAddressCount}"
```
Expect: new env values applied, more free IPs at idle, HPA can scale further before exhaustion.

### 7b — `solution/s4-subnet-discovery`

**Build:** add a new private subnet tagged `kubernetes.io/role/cni=1`, no workload changes.

**Verify:**
```bash
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
  --query "Subnets[].{ID:SubnetId,CIDR:CidrBlock,Tags:Tags}"
kubectl -n kube-system logs ds/aws-node | grep -i discovered
```
Expect: new subnet visible, CNI logs reference discovery, new ENIs land in the new subnet under load.

### 7c — `solution/s3-s2-custom-net-pd`

**Build:** attach secondary VPC CIDR `100.64.0.0/16`, create per-AZ `ENIConfig`, set `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true` and `ENABLE_PREFIX_DELEGATION=true`.

**Verify:**
```bash
aws ec2 describe-vpcs --vpc-ids <vpc-id> \
  --query "Vpcs[].CidrBlockAssociationSet"
kubectl get eniconfig
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query "NetworkInterfaces[].{ID:NetworkInterfaceId,Subnet:SubnetId,Prefixes:Ipv4Prefixes}"
kubectl get pods -o wide
```
Expect: secondary CIDR attached, ENIConfigs present, ENIs hold `/28` prefixes, pod IPs come from `100.64.0.0/16`.

---

## Phase 8 — Documentation

**Build**

- [README.md](../README.md): quickstart, teardown, cost note (NAT GW ≈ $0.045/h).
- `docs/results.md`: consolidated trade-off table across the §9 dimensions (cost, complexity, downtime risk, IP efficiency, AWS supportability, scalability ceiling).
- Teardown: `helm uninstall`, `kubectl delete -f k8s/`, `terraform destroy`.

**Verify**

```bash
aws ec2 describe-addresses --query "Addresses[?AssociationId==null]"
aws ec2 describe-nat-gateways --filter "Name=state,Values=available"
aws eks list-clusters
```

Expect: no orphan EIPs, no live NAT gateways, no remaining EKS clusters.
