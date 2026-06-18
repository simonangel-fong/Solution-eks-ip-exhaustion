```sh
terraform -chdir=infra init --backend-config=backend.hcl -reconfigure
terraform -chdir=infra fmt
terraform -chdir=infra validate
terraform -chdir=infra apply -auto-approve

aws ec2 describe-vpcs --filters "Name=tag:Name,Values=eks-ip-exhaustion" --query "Vpcs[].{ID:VpcId,CIDR:CidrBlock,DNS:EnableDnsSupport}"
# [
#     {
#         "ID": "vpc-07c4568b48b3c2a59",
#         "CIDR": "10.0.0.0/24",
#         "DNS": null
#     }
# ]

# confirm subnet
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-07c4568b48b3c2a59" --query "Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Free:AvailableIpAddressCount}"
# [
#     {
#         "ID": "subnet-02b1c63fcba358f15",
#         "CIDR": "10.0.0.0/28",
#         "AZ": "ca-central-1a",
#         "Free": 10
#     },
#     {
#         "ID": "subnet-06c7bee4e732f6939",
#         "CIDR": "10.0.0.32/28",
#         "AZ": "ca-central-1b",
#         "Free": 0
#     },
#     {
#         "ID": "subnet-086f4fe3d9fb2798e",
#         "CIDR": "10.0.0.16/28",
#         "AZ": "ca-central-1a",
#         "Free": 0
#     }
# ]

aws eks describe-cluster --name eks-ip-exhaustion --query "cluster.{Status:status,Version:version,Endpoint:endpoint}"
# {
#     "Status": "ACTIVE",
#     "Version": "1.36",
#     "Endpoint": "https://9F7B5448B8A39D855BE3AC2B2C3C66ED.sk1.ca-central-1.eks.amazonaws.com"
# }

aws eks describe-nodegroup --cluster-name eks-ip-exhaustion --nodegroup-name eks-ip-exhaustion-ng --query "nodegroup.{Status:status,Scaling:scalingConfig}"
# {
#     "Status": "ACTIVE",
#     "Scaling": {
#         "minSize": 1,
#         "maxSize": 10,
#         "desiredSize": 10
#     }
# }

aws eks describe-addon --cluster-name eks-ip-exhaustion --addon-name vpc-cni --query "addon.{Status:status,Version:addonVersion}"
# {
#     "Status": "ACTIVE",
#     "Version": "v1.22.2-eksbuild.1"
# }

aws eks update-kubeconfig --region ca-central-1 --name eks-ip-exhaustion
# Updated context arn:aws:eks:ca-central-1:099139718958:cluster/eks-ip-exhaustion in /home/ubuntuadmin/.kube/config

kubectl get nodes -o wide
# NAME                                          STATUS   ROLES    AGE   VERSION               INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                        KERNEL-VERSION                           CONTAINER-RUNTIME
# ip-10-0-0-149.ca-central-1.compute.internal   Ready    <none>   14m   v1.36.1-eks-0de9cde   10.0.0.149    <none>        Amazon Linux 2023.12.20260608   6.18.33-63.124.amzn2023.x86_64 (amd64)   containerd://2.2.4+unknown
# ip-10-0-0-73.ca-central-1.compute.internal    Ready    <none>   14m   v1.36.1-eks-0de9cde   10.0.0.73     <none>        Amazon Linux 2023.12.20260608   6.18.33-63.124.amzn2023.x86_64 (amd64)   containerd://2.2.4+unknown

kubectl -n kube-system get ds aws-node
# NAME       DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
# aws-node   2         2         2       2            2           <none>          5m44s


# install metric server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

k get deploy metrics-server -n kube-system
# NAME             READY   UP-TO-DATE   AVAILABLE   AGE
# metrics-server   1/1     1            1           74s

# Deploy
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm upgrade -i web-app bitnami/nginx -f helm/nginx-values.yaml

kubectl get pods -o wide
# NAME                             READY   STATUS    RESTARTS   AGE     IP           NODE                                          NOMINATED NODE   READINESS GATES
# web-app-nginx-8449d77c8d-kmvj6   1/1     Running   0          12s     10.0.0.187   ip-10-0-0-149.ca-central-1.compute.internal   <none>           <none>
# web-app-nginx-8449d77c8d-qprlv   1/1     Running   0          8m52s   10.0.0.109   ip-10-0-0-73.ca-central-1.compute.internal    <none>           <none>

kubectl top pods
# NAME                             CPU(cores)   MEMORY(bytes)
# web-app-nginx-8449d77c8d-kmvj6   1m           4Mi
# web-app-nginx-8449d77c8d-qprlv   1m           4Mi

kubectl get svc web-app-nginx
# NAME            TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
# web-app-nginx   ClusterIP   172.20.227.29   <none>        80/TCP,443/TCP   68s

aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-07c4568b48b3c2a59" --query "Subnets[].{CIDR:CidrBlock,Free:AvailableIpAddressCount}"
# [
#     {
#         "ID": "subnet-02b1c63fcba358f15",
#         "CIDR": "10.0.0.0/28",
#         "AZ": "ca-central-1a",
#         "Free": 10
#     },
#     {
#         "ID": "subnet-06c7bee4e732f6939",
#         "CIDR": "10.0.0.32/28",
#         "AZ": "ca-central-1b",
#         "Free": 3
#     },
#     {
#         "ID": "subnet-086f4fe3d9fb2798e",
#         "CIDR": "10.0.0.16/28",
#         "AZ": "ca-central-1a",
#         "Free": 3
#     }
# ]

```

| Subnet                 | Total usable | Consumed | Free |
| ---------------------- | ------------ | -------- | ---- |
| Public A 10.0.0.0/28   | 16           | 6        | 10   |
| Private B 10.0.0.16/28 | 16           | 13       | 3    |
| Private A 10.0.0.32/28 | 16           | 13       | 3    |

---
