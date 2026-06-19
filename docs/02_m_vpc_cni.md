```sh
terraform -chdir=infra fmt
terraform -chdir=infra validate
terraform -chdir=infra apply -auto-approve

aws ec2 describe-subnets --filters "Name=tag:Project,Values=eks-ip-scale" --query "Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AvailableIPs:AvailableIpAddressCount}" --output table
# --------------------------------------------------------------
# |                       DescribeSubnets                      |
# +--------------+----------------+----------------------------+
# | AvailableIPs |     CIDR       |         SubnetId           |
# +--------------+----------------+----------------------------+
# |  10          |  10.0.0.0/28   |  subnet-0af2ec22a1c75a9ac  |
# |  7           |  10.0.0.16/28  |  subnet-03b1e90a46a0cddbb  |
# |  16375       |  10.1.64.0/18  |  subnet-0a48a95b685928401  |
# |  7           |  10.0.0.32/28  |  subnet-056170687b3b21a98  |
# |  16375       |  10.1.0.0/18   |  subnet-06fcc6948cebc8bfa  |
# +--------------+----------------+----------------------------+

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
# |  10          |  10.0.0.0/28   |  subnet-0af2ec22a1c75a9ac  |
# |  0           |  10.0.0.16/28  |  subnet-03b1e90a46a0cddbb  |
# |  16372       |  10.1.64.0/18  |  subnet-0a48a95b685928401  |
# |  0           |  10.0.0.32/28  |  subnet-056170687b3b21a98  |
# |  16372       |  10.1.0.0/18   |  subnet-06fcc6948cebc8bfa  |
# +--------------+----------------+----------------------------+
```