# AWS Documentation: IP Address Utilization Optimization

[Back](../README.md)

- [AWS Documentation: IP Address Utilization Optimization](#aws-documentation-ip-address-utilization-optimization)
  - [AWS CNI \& IP Consumption](#aws-cni--ip-consumption)
  - [Prevention: EKS Creation](#prevention-eks-creation)
    - [Use IPv6 (recommended)](#use-ipv6-recommended)
    - [Optimize the IPs warm pool](#optimize-the-ips-warm-pool)
    - [Optimize node-level IP consumption](#optimize-node-level-ip-consumption)
  - [Mitigation](#mitigation)
      - [Enhanced Subnet Discovery](#enhanced-subnet-discovery)
  - [Remediation](#remediation)
    - [Custom Networking](#custom-networking)
  - [Observebility](#observebility)
    - [Monitor IP Address Inventory](#monitor-ip-address-inventory)

---

- ref: https://docs.aws.amazon.com/eks/latest/best-practices/ip-opt.html

## AWS CNI & IP Consumption

- Role of AWS CNI plugin:
  - **assigns** each `pod` an IP address from the `VPC’s CIDR`(s).
  - support monitoring solutions such as VPC Flow Logs

- IP exhaustion:
  - can't create new Pods or nodes

- EKS subnets:
  - default: `/19`(8,192 ip addresses)
  - at least `/28` (16 IP addresses)

---

## Prevention: EKS Creation

- to prevent `IP exhaustion` issue:
  - needs to optimize Amazon EKS IP consumption at the `VPC` and at the `node level`.

### Use IPv6 (recommended)

- cluster creation with IPv6
  - **official recommendation** for network architecture
  - cluster administrators can focus on migrating and scaling applications without devoting effort towards working around IPv4 limits.

- Amazon EKS clusters support
  - `IPv4`(default)
  - `IPv6`:
    - pods and services: `IPv6 addresses` + legacy `IPv4 endpoints`
    - **pod-to-pod communication**: `IPv6`
    - Within a VPC (`/56`), the IPv6 CIDR block size for IPv6 subnets is fixed at `/64`.
      - 2^64 (approximately 18 quintillion) IPv6 addresses.

---

### Optimize the IPs warm pool

- `VPC CNI` default configuration:
  - keeps an entire `ENI` (and associated IPs) in the `warm pool`.
  - consume a large number of IPs, especially on larger instance types.
- Custom parameters in `VPC CNI`:
  - `WARM_IP_TARGET`
  - `MINIMUM_IP_TARGET`
  - `WARM_ENI_TARGET`

---

### Optimize node-level IP consumption

- `Prefix delegation`
  - a feature of `Amazon Virtual Private Cloud (Amazon VPC)`
  - allows to **assign IPv4 or IPv6 prefixes** to `Amazon Elastic Compute Cloud (Amazon EC2)` instances.
  - **increases the IP addresses per** `network interface (ENI)`, which increases the pod density per node and improves compute efficiency.
  - also supported with Custom Networking.
  - ref: https://docs.aws.amazon.com/eks/latest/best-practices/prefix-mode-linux.html

---

## Mitigation

an interim or partial measure used to reduce the likelihood

#### Enhanced Subnet Discovery

- `Enhanced Subnet Discovery`
  - a streamlined network configuration alternative for IP exhaustion
  - **tags** new subnets so they will **be discoverable** by the `Amazon VPC CNI`.
- Benefits:
  - the current workloads can **keep running on the same subnets** and `Amazon Elastic Kubernetes Service (Amazon EKS)`
  - schedule additional pods on the new "usable subnet(s)".

---

- Steps:
  - Enable the `ENABLE_SUBNET_DISCOVERY` configuration of Amazon VPC CNI add-on to "true"
    - default: VPC CNI(> 1.18.0).
  - Associate a **new CIDR block** to `VPC`.
  - Create a new subnet in the new CIDR block and tag it with `"kubernetes.io/role/cni" = "1"`.

---

## Remediation

the process of completely eliminating the root cause of an issue

### Custom Networking

- `Custom Networking`
  - assigns the node and Pod IPs **from secondary VPC address spaces (CIDR)**.
  - `VPC CNI` creates `secondary ENIs` in the subnet defined under `ENIConfig` and assigns Pods an IP addresses from a CIDR range defined in a `ENIConfig CRD`.

- **official recommendations**
  - CIDRs:
    - `100.64.0.0/10`
    - less likely to be used in a corporate setting
  - using `prefix delegation` with `custom networking`

---

- ref: https://docs.aws.amazon.com/eks/latest/best-practices/custom-networking.html
- Steps:
  - enable `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true`
  - `ENIConfig CRD`
    - alternate subnet CIDR range
    - security group(s) that the Pods will belong to.
  - create new worker nodes
  - drain the existing nodes

---

## Observebility

### Monitor IP Address Inventory

- monitor with `cni-metrics-helper`
- key metrics:
  - maximum number of ENIs the cluster can support
  - number of ENIs already allocated
  - number of IP addresses currently assigned to Pods
  - total and maximum number of IP address available

- can also set `CloudWatch alarms` to get notified if a subnet is running out of IP addresses.
