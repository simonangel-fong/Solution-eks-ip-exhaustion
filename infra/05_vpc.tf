# vpc.tf

# ##############################
# VPC
# ##############################
resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = local.project_name
  }
}

# ##############################
# Subnet: Public
# ##############################
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_a_cidr
  availability_zone       = "${local.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${local.project_name}-public-a"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

# ##############################
# Subnet: Private
# ##############################
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_a_cidr
  availability_zone = "${local.aws_region}a"

  tags = {
    Name                                          = "${local.project_name}-private-a"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.project_name}" = "owned"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_b_cidr
  availability_zone = "${local.aws_region}b"

  tags = {
    Name                                          = "${local.project_name}-private-b"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.project_name}" = "owned"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${local.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# ##############################
# IGW
# ##############################
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project_name}-igw"
  }
}

# ##############################
# EIP
# ##############################
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.project_name}-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

# ##############################
# NAT
# ##############################
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "${local.project_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

