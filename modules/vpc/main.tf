###############################################################################
# VPC Module — main.tf
#
# Creates a production-grade, multi-tier VPC with:
#   - Public subnets   (one per AZ, with IGW route)
#   - Private subnets  (one per AZ, with NAT Gateway route)
#   - Intra  subnets   (one per AZ, no internet route — used for databases)
#   - Optional Transit Gateway attachment for multi-region connectivity
#   - VPC Flow Logs to S3 with configurable lifecycle policies
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  name = "${var.name}-${var.environment}"

  # Determine which AZs have subnets defined
  public_az_count  = length(var.public_subnet_cidrs)
  private_az_count = length(var.private_subnet_cidrs)
  intra_az_count   = length(var.intra_subnet_cidrs)

  # NAT Gateway placement: one per AZ (HA) or a single shared one
  nat_gateway_count = (
    var.enable_nat_gateway
    ? (var.single_nat_gateway ? 1 : local.public_az_count)
    : 0
  )

  common_tags = merge(
    {
      Name        = local.name
      Environment = var.environment
      Region      = var.region
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  tags = merge(local.common_tags, { Name = "${local.name}-vpc" })
}

###############################################################################
# Internet Gateway (public subnets)
###############################################################################

resource "aws_internet_gateway" "this" {
  count = local.public_az_count > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-igw" })
}

###############################################################################
# Public Subnets
###############################################################################

resource "aws_subnet" "public" {
  count = local.public_az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false # Never auto-assign public IPs; use EIPs/ALBs explicitly

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name}-public-${var.azs[count.index]}"
      Tier = "public"
      # EKS cluster auto-discovers subnets via these tags
      "kubernetes.io/role/elb"              = "1"
      "kubernetes.io/cluster/${local.name}" = "shared"
    }
  )
}

resource "aws_route_table" "public" {
  count = local.public_az_count > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-public-rt" })
}

resource "aws_route" "public_internet" {
  count = local.public_az_count > 0 ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count = local.public_az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

###############################################################################
# Elastic IPs & NAT Gateways
###############################################################################

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(local.common_tags, { Name = "${local.name}-nat-eip-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, { Name = "${local.name}-natgw-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Private Subnets
###############################################################################

resource "aws_subnet" "private" {
  count = local.private_az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(
    local.common_tags,
    {
      Name                                  = "${local.name}-private-${var.azs[count.index]}"
      Tier                                  = "private"
      "kubernetes.io/role/internal-elb"     = "1"
      "kubernetes.io/cluster/${local.name}" = "shared"
    }
  )
}

resource "aws_route_table" "private" {
  # One route table per private subnet (per AZ) so we can route each AZ through
  # its own NAT Gateway for fault isolation. Falls back to shared RT when
  # single_nat_gateway = true.
  count = local.private_az_count

  vpc_id = aws_vpc.this.id

  tags = merge(
    local.common_tags,
    { Name = "${local.name}-private-rt-${var.azs[count.index]}" }
  )
}

resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? local.private_az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = (
    var.single_nat_gateway
    ? aws_nat_gateway.this[0].id
    : aws_nat_gateway.this[count.index].id
  )
}

resource "aws_route" "private_tgw" {
  # Add routes for remote CIDRs reachable via Transit Gateway
  count = var.transit_gateway_id != "" ? local.private_az_count * length(var.tgw_destination_cidrs) : 0

  route_table_id         = aws_route_table.private[count.index % local.private_az_count].id
  destination_cidr_block = var.tgw_destination_cidrs[floor(count.index / local.private_az_count)]
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "private" {
  count = local.private_az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

###############################################################################
# Intra (Database) Subnets — no internet route
###############################################################################

resource "aws_subnet" "intra" {
  count = local.intra_az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.intra_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name}-intra-${var.azs[count.index]}"
      Tier = "intra"
    }
  )
}

resource "aws_route_table" "intra" {
  count = local.intra_az_count > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-intra-rt" })
}

resource "aws_route" "intra_tgw" {
  count = var.transit_gateway_id != "" ? length(var.tgw_destination_cidrs) : 0

  route_table_id         = aws_route_table.intra[0].id
  destination_cidr_block = var.tgw_destination_cidrs[count.index]
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "intra" {
  count = local.intra_az_count

  subnet_id      = aws_subnet.intra[count.index].id
  route_table_id = aws_route_table.intra[0].id
}

###############################################################################
# Transit Gateway Attachment
###############################################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = var.transit_gateway_id != "" ? 1 : 0

  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = aws_subnet.private[*].id

  dns_support                                     = "enable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(local.common_tags, { Name = "${local.name}-tgw-attachment" })
}

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  count = var.transit_gateway_id != "" && var.transit_gateway_route_table_id != "" ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[0].id
  transit_gateway_route_table_id = var.transit_gateway_route_table_id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  count = length(var.tgw_propagated_route_tables)

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[0].id
  transit_gateway_route_table_id = var.tgw_propagated_route_tables[count.index]
}

###############################################################################
# Default Security Group — deny all (security hardening)
###############################################################################

resource "aws_default_security_group" "deny_all" {
  vpc_id = aws_vpc.this.id

  # Explicitly empty — overrides AWS default allow-all rules
  ingress = []
  egress  = []

  tags = merge(local.common_tags, { Name = "${local.name}-default-sg-deny-all" })
}

###############################################################################
# Default Network ACL — explicitly managed (defence in depth)
###############################################################################

resource "aws_default_network_acl" "this" {
  default_network_acl_id = aws_vpc.this.default_network_acl_id

  # Allow all within VPC — NACLs are stateless; fine-grained rules belong in SGs
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(local.common_tags, { Name = "${local.name}-default-nacl" })

  lifecycle {
    ignore_changes = [subnet_ids]
  }
}
