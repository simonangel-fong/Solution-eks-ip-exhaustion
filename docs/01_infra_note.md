## Create EKS

```sh
terraform -chdir=infra init --backend-config=backend.hcl -reconfigure
terraform -chdir=infra fmt
terraform -chdir=infra validate
terraform -chdir=infra apply -auto-approve

aws eks update-kubeconfig --region ca-central-1 --name eks-ip-scale
# Added new context arn:aws:eks:ca-central-1:099139718958:cluster/eks-ip-scale to /home/ubuntuadmin/.kube/config

kubectl get nodes -o wide
# NAME                                         STATUS   ROLES    AGE     VERSION               INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                           CONTAINER-RUNTIME
# ip-10-0-0-25.ca-central-1.compute.internal   Ready    <none>   30m     v1.36.1-eks-0de9cde   10.0.0.25     <none>        Amazon Linux 2023.12.20260608   6.18.33-63.124.amzn2023.x86_64 (amd64)   containerd://2.2.4+unknown
# ip-10-0-0-37.ca-central-1.compute.internal   Ready    <none>   6m51s   v1.36.1-eks-0de9cde   10.0.0.37     <none>        Amazon Linux 2023.12.20260608   6.18.33-63.124.amzn2023.x86_64 (amd64)   containerd://2.2.4+unknown

kubectl get pods -o wide -A
# NAMESPACE     NAME                       READY   STATUS    RESTARTS   AGE     IP          NODE                                         NOMINATED NODE   READINESS GATES
# kube-system   aws-node-2t68b             2/2     Running   0          7m21s   10.0.0.37   ip-10-0-0-37.ca-central-1.compute.internal   <none>           <none>
# kube-system   aws-node-66th7             2/2     Running   0          30m     10.0.0.25   ip-10-0-0-25.ca-central-1.compute.internal   <none>           <none>
# kube-system   coredns-84994d84c5-4zbjd   1/1     Running   0          33m     10.0.0.24   ip-10-0-0-25.ca-central-1.compute.internal   <none>           <none>
# kube-system   coredns-84994d84c5-84xj4   1/1     Running   0          33m     10.0.0.23   ip-10-0-0-25.ca-central-1.compute.internal   <none>           <none>
# kube-system   kube-proxy-jsp7x           1/1     Running   0          7m21s   10.0.0.37   ip-10-0-0-37.ca-central-1.compute.internal   <none>           <none>
# kube-system   kube-proxy-rdf92           1/1     Running   0          30m     10.0.0.25   ip-10-0-0-25.ca-central-1.compute.internal   <none>           <none>

aws ec2 describe-subnets \
  --subnet-ids subnet-03b1e90a46a0cddbb subnet-056170687b3b21a98 \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table

# --------------------------------------------------------------
# |                       DescribeSubnets                      |
# +--------------+----------------+----------------------------+
# | AvailableIPs |     CIDR       |         SubnetId           |
# +--------------+----------------+----------------------------+
# |  4           |  10.0.0.16/28  |  subnet-03b1e90a46a0cddbb  |
# |  6           |  10.0.0.32/28  |  subnet-056170687b3b21a98  |
# +--------------+----------------+----------------------------+
```

| Subnet                 | Total usable | Consumed | AvailableIPs |
| ---------------------- | ------------ | -------- | ------------ |
| Private A 10.0.0.16/28 | 16           | 12       | 4            |
| Private B 10.0.0.32/28 | 16           | 9        | 6            |

---
