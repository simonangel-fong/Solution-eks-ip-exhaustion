locals {
  project_name = "eks-ip-scale"
  aws_region   = "ca-central-1"

  # vpc
  vpc_cidr       = "10.0.0.0/26"
  public_a_cidr  = "10.0.0.0/28"
  private_a_cidr = "10.0.0.16/28"
  private_b_cidr = "10.0.0.32/28"

  # node
  node_type         = "t3.medium"
  node_min_size     = 1
  node_max_size     = 4
  node_desired_size = 2
}
