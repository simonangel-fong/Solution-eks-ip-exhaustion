
locals {
  vpc_secondary_cidr = "10.1.0.0/16"
  cni_a_cidr         = "10.1.0.0/18"
  cni_b_cidr         = "10.1.64.0/18"
}

# ##############################
# Mitigation: Additional Subnet
# ##############################
resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  vpc_id     = aws_vpc.main.id
  cidr_block = local.vpc_secondary_cidr
}

resource "aws_subnet" "cni_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.cni_a_cidr
  availability_zone = "${local.aws_region}a"

  tags = {
    Name                                          = "${local.project_name}-cni-a"
    "kubernetes.io/role/cni"                      = "1"
    "kubernetes.io/cluster/${local.project_name}" = "owned"
  }

  depends_on = [aws_vpc_ipv4_cidr_block_association.secondary]
}

resource "aws_subnet" "cni_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.cni_b_cidr
  availability_zone = "${local.aws_region}b"

  tags = {
    Name                                          = "${local.project_name}-cni-b"
    "kubernetes.io/role/cni"                      = "1"
    "kubernetes.io/cluster/${local.project_name}" = "owned"
  }

  depends_on = [aws_vpc_ipv4_cidr_block_association.secondary]
}

resource "aws_route_table_association" "cni_a" {
  subnet_id      = aws_subnet.cni_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "cni_b" {
  subnet_id      = aws_subnet.cni_b.id
  route_table_id = aws_route_table.private.id
}
