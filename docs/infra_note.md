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
  --subnet-ids subnet-036659f9d08cf5913 subnet-06a54a19a9cd65165 \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table

# --------------------------------------------------------------
# |                       DescribeSubnets                      |
# +--------------+----------------+----------------------------+
# | AvailableIPs |     CIDR       |         SubnetId           |
# +--------------+----------------+----------------------------+
# |  7           |  10.0.0.32/28  |  subnet-036659f9d08cf5913  |
# |  5           |  10.0.0.16/28  |  subnet-06a54a19a9cd65165  |
# +--------------+----------------+----------------------------+
```

| Subnet                 | Total usable | Consumed | AvailableIPs |
| ---------------------- | ------------ | -------- | ------------ |
| Private A 10.0.0.16/28 | 16           | 11       | 5            |
| Private B 10.0.0.32/28 | 16           | 9        | 7            |

---

## IP Exhaustion

```bash
kubectl create deploy web --image=nginx --replicas=0
# deployment.apps/web created

kubectl scale deploy web --replicas=20
# deployment.apps/web scaled

kubectl get deploy
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    14/20   20           14          22m

aws ec2 describe-subnets \
  --subnet-ids subnet-036659f9d08cf5913 subnet-06a54a19a9cd65165 \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table

# --------------------------------------------------------------
# |                       DescribeSubnets                      |
# +--------------+----------------+----------------------------+
# | AvailableIPs |     CIDR       |         SubnetId           |
# +--------------+----------------+----------------------------+
# |  0           |  10.0.0.32/28  |  subnet-036659f9d08cf5913  |
# |  0           |  10.0.0.16/28  |  subnet-06a54a19a9cd65165  |
# +--------------+----------------+----------------------------+

kubectl get po -l app=web | grep ContainerCreating
# web-7887448d46-jkt5b   0/1     ContainerCreating   0          7m9s
# web-7887448d46-llbkp   0/1     ContainerCreating   0          7m9s
# web-7887448d46-nq7ft   0/1     ContainerCreating   0          7m9s
# web-7887448d46-pj4kp   0/1     ContainerCreating   0          7m9s
# web-7887448d46-q2knn   0/1     ContainerCreating   0          7m9s
# web-7887448d46-zwv6v   0/1     ContainerCreating   0          7m9s

kubectl describe po web-7887448d46-jkt5b
# Events:
#   Type     Reason                  Age                     From               Message
#   ----     ------                  ----                    ----               -------
#   Normal   Scheduled               7m34s                   default-scheduler  Successfully assigned default/web-7887448d46-jkt5b to ip-10-0-0-25.ca-central-1.compute.internal
#   Warning  FailedCreatePodSandBox  7m34s                   kubelet            Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "b203fc823d7cc19aa03ce8e8c1cbc21d76aadd3851c80e9d3e523cc22c407cdc": plugin type="aws-cni" name="aws-cni" failed (add): add cmd: failed to assign an IP address to container
#   Warning  FailedCreatePodSandBox  2m20s (x17 over 5m42s)  kubelet            (combined from similar events): Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "c66900431caccf405c46f86a688a03a2a67df6c0329f9d2034ae7174b2bf2056": plugin type="aws-cni" name="aws-cni" failed (add): add cmd: failed to assign an IP address to container

```

- Observation:
  - Each pod in EKS with the AWS VPC CNI requires a VPC IP from the worker node subnets.
  - Both private subnets reached `AvailableIpAddressCount = 0`.
  - The deployment reached only `14/20` available replicas.
  - The remaining pods stayed in `ContainerCreating` because the AWS CNI failed to assign pod IPs.
  - The events confirm the root cause: `failed to assign an IP address to container`.
