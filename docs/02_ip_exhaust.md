## IP Exhaustion

```bash
kubectl create deploy web --image=nginx --replicas=0
# deployment.apps/web created

kubectl scale deploy web --replicas=20
# deployment.apps/web scaled

kubectl get deploy
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    4/20    20           4           3m46s

aws ec2 describe-subnets \
  --subnet-ids subnet-03b1e90a46a0cddbb subnet-056170687b3b21a98 \
  --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" \
  --output table

# --------------------------------------------------------------
# |                       DescribeSubnets                      |
# +--------------+----------------+----------------------------+
# | AvailableIPs |     CIDR       |         SubnetId           |
# +--------------+----------------+----------------------------+
# |  0           |  10.0.0.16/28  |  subnet-03b1e90a46a0cddbb  |
# |  0           |  10.0.0.32/28  |  subnet-056170687b3b21a98  |
# +--------------+----------------+----------------------------+

kubectl get po -l app=web | grep ContainerCreating
# web-7887448d46-8v6jl   0/1     ContainerCreating   0          101s
# web-7887448d46-b2v76   0/1     ContainerCreating   0          101s
# web-7887448d46-bwf46   0/1     ContainerCreating   0          101s
# web-7887448d46-fm9k4   0/1     ContainerCreating   0          101s
# web-7887448d46-r5w6b   0/1     ContainerCreating   0          101s
# web-7887448d46-szmg9   0/1     ContainerCreating   0          101s

kubectl describe po web-7887448d46-szmg9
# Events:
#   Type     Reason                  Age               From               Message
#   ----     ------                  ----              ----               -------
#   Normal   Scheduled               2m11s             default-scheduler  Successfully assigned default/web-7887448d46-szmg9 to ip-10-0-0-44.ca-central-1.compute.internal
#   Warning  FailedCreatePodSandBox  1s (x2 over 12s)  kubelet            (combined from similar events): Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "11ba8b29f38a269ffe3269e0ae3a83cb9a75793d2b3c34edb8dee0625f64bc90": plugin type="aws-cni" name="aws-cni" failed (add): add cmd: failed to assign an IP address to container

aws eks describe-cluster --name eks-ip-scale --query "cluster.health"
# {
#     "issues": [
#         {
#             "code": "InsufficientFreeAddresses",
#             "message": "One or more of the subnets associated with your cluster does not have enough available IP addresses for Amazon EKS to perform cluster management operations. Free up addresses in the subnet(s), or associate different subnets to your cluster using the Amazon EKS update-cluster-config API.",
#             "resourceIds": [
#                 "subnet-03b1e90a46a0cddbb",
#                 "subnet-056170687b3b21a98"
#             ]
#         }
#     ]
# }

```

- Observation:
  - Each pod in EKS with the AWS VPC CNI requires a VPC IP from the worker node subnets.
  - Both private subnets reached `AvailableIpAddressCount = 0`.
  - The deployment reached only `14/20` available replicas.
  - The remaining pods stayed in `ContainerCreating` because the AWS CNI failed to assign pod IPs.
  - The events confirm the root cause: `failed to assign an IP address to container`.

---
