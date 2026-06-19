# Runbook: EKS IP Exhaustion - Enhanced Subnet Discovery

[Back](../README.md)

- [Runbook: EKS IP Exhaustion - Enhanced Subnet Discovery](#runbook-eks-ip-exhaustion---enhanced-subnet-discovery)
  - [Create CNI Subnets](#create-cni-subnets)
  - [Verification](#verification)

---

## Create CNI Subnets

```sh
# confirm subnet discovery enabled
kubectl get daemonset aws-node -n kube-system -o yaml | grep -A1 ENABLE_SUBNET_DISCOVERY
        # - name: ENABLE_SUBNET_DISCOVERY
        #   value: "true"

terraform -chdir=infra fmt
terraform -chdir=infra validate
terraform -chdir=infra apply -auto-approve
```

---

## Verification

```sh
k scale deploy web --replicas=20
# deployment.apps/web scaled

k get deploy web
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    20/20   20           20          4h9m

aws ec2 describe-subnets --filters "Name=tag:Project,Values=eks-ip-scale" --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" --output table
# --------------------------------------------------------------
# |                       DescribeSubnets                      |
# +--------------+----------------+----------------------------+
# | AvailableIPs |     CIDR       |         SubnetId           |
# +--------------+----------------+----------------------------+
# |  16371       |  10.1.64.0/18  |  subnet-0b9edc5473a1e2147  |
# |  0           |  10.0.0.32/28  |  subnet-0149de88f56baea35  |
# |  10          |  10.0.0.0/28   |  subnet-0b948e927db9a17ca  |
# |  16373       |  10.1.0.0/18   |  subnet-06095a000545e18b0  |
# |  0           |  10.0.0.16/28  |  subnet-080655510871afc02  |
# +--------------+----------------+----------------------------+
```
