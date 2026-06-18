# eks.tf

# ##############################
# Assume Role: eks
# ##############################
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.project_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ##############################
# Assume Role: node
# ##############################
resource "aws_iam_role" "node" {
  name               = "${local.project_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ##############################
# EKS
# ##############################
resource "aws_eks_cluster" "main" {
  name     = local.project_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.36"

  vpc_config {
    subnet_ids              = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  enabled_cluster_log_types = ["api", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
  ]
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.project_name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  instance_types = [local.node_type]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = local.node_desired_size
    min_size     = local.node_min_size
    max_size     = local.node_max_size
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]
}

# ##############################
# Add-ons
# ##############################
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "vpc-cni"
  addon_version = "v1.22.2-eksbuild.1"

  configuration_values = jsonencode({
    env = {
      WARM_IP_TARGET    = "1"
      MINIMUM_IP_TARGET = "0"
      WARM_ENI_TARGET   = "0"
    }
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}
