data "aws_availability_zones" "available" {
  provider = aws.compute
  state    = "available"
}

resource "aws_vpc" "vpc" {
  provider             = aws.compute
  cidr_block           = var.aws_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "vpc-suse-observability"
  }
}

resource "aws_internet_gateway" "igw" {
  provider = aws.compute
  vpc_id   = aws_vpc.vpc.id

  tags = {
    Name = "igw-suse-observability"
  }
}

# A single public subnet in one AZ, matching cloud-rancher's single-subnet model.
resource "aws_subnet" "subnet" {
  provider                = aws.compute
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = cidrsubnet(var.aws_vpc_cidr, 8, 1)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false # nodes get a stable IP from an explicit aws_eip instead

  tags = {
    Name = "snet-suse-observability-nodes"
  }
}

resource "aws_route_table" "rt" {
  provider = aws.compute
  vpc_id   = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "rt-suse-observability-public"
  }
}

resource "aws_route_table_association" "rta" {
  provider       = aws.compute
  subnet_id      = aws_subnet.subnet.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_security_group" "nsg" {
  provider    = aws.compute
  name        = "suse-observability-nodes-sg"
  description = "RKE2/SUSE Observability node traffic (SSH, Kube-API, HTTP, HTTPS)"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.admin_cidr_blocks
  }

  ingress {
    description = "Kube-API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = local.admin_cidr_blocks
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Always open: required for the Let's Encrypt HTTP-01 challenge
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    # Always open, like port 80: the ingress controller's own TLS + SUSE
    # Observability's auth protect this, and agents reporting data in connect
    # from node IPs that have nothing to do with wherever `terraform apply` was run.
    cidr_blocks = ["0.0.0.0/0"]
  }

  # RKE2 inter-node traffic (supervisor API, kubelet, CNI) - needed for any
  # multi-node RKE2 cluster to actually join (cluster_node_count = 3 HA).
  # Scoped to the VPC's own CIDR rather than local.admin_cidr_blocks, since
  # this is node-to-node traffic, not admin access.
  ingress {
    description = "RKE2 inter-node (supervisor API, kubelet, CNI)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.aws_vpc_cidr]
  }

  # Canal's VXLAN overlay (cross-node pod-to-pod traffic) rides on UDP, not
  # TCP - without this, pods can only reach services on their own node.
  ingress {
    description = "RKE2 inter-node (Canal VXLAN overlay)"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [var.aws_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "suse-observability-nodes-sg"
  }
}
