terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ============================================================
# VARIABLES
# ============================================================

variable "cluster_version" {
  default = "1.35"
}

# ============================================================
# VPC
# ============================================================

resource "aws_vpc" "eks_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "eks-vpc"
  }
}

# ============================================================
# INTERNET GATEWAY
# ============================================================

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id

  tags = {
    Name = "eks-igw"
  }
}

# ============================================================
# PUBLIC SUBNETS
# ============================================================

resource "aws_subnet" "public1" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "eks-public-1a"

    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "public2" {
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "eks-public-1b"

    "kubernetes.io/role/elb" = "1"
  }
}

# ============================================================
# PRIVATE SUBNETS
# ============================================================

resource "aws_subnet" "private1" {
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "eks-private-1a"

    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "eks-private-1b"

    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ============================================================
# PUBLIC ROUTE TABLE
# ============================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "eks-public-rt"
  }
}

resource "aws_route_table_association" "public1" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public2" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public.id
}

# ============================================================
# NAT GATEWAY
# ============================================================

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "eks-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public1.id

  depends_on = [
    aws_internet_gateway.igw
  ]

  tags = {
    Name = "eks-nat"
  }
}

# ============================================================
# PRIVATE ROUTE TABLE
# ============================================================

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "eks-private-rt"
  }
}

resource "aws_route_table_association" "private1" {
  subnet_id      = aws_subnet.private1.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private2" {
  subnet_id      = aws_subnet.private2.id
  route_table_id = aws_route_table.private.id
}

# ============================================================
# SECURITY GROUP
# LAB ONLY
# ============================================================

resource "aws_security_group" "allow_all" {
  name        = "eks-lab-sg"
  description = "Security group for EKS lab"
  vpc_id      = aws_vpc.eks_vpc.id

  ingress {
    description = "Allow all traffic - LAB ONLY"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-lab-sg"
  }
}

# ============================================================
# EKS CLUSTER IAM ROLE
# ============================================================

resource "aws_iam_role" "cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "eks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "eks-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role = aws_iam_role.cluster_role.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ============================================================
# EKS CLUSTER
# ============================================================

resource "aws_eks_cluster" "eks" {
  name     = "naresh"
  role_arn = aws_iam_role.cluster_role.arn
  version  = var.cluster_version

  # IMPORTANT:
  # Enables EKS API access entries while keeping
  # compatibility with aws-auth ConfigMap.
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  vpc_config {
    subnet_ids = [
      aws_subnet.private1.id,
      aws_subnet.private2.id
    ]

    endpoint_public_access = true

    security_group_ids = [
      aws_security_group.allow_all.id
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]

  tags = {
    Name = "naresh"
  }
}

# ============================================================
# EKS ACCESS ENTRY
# ============================================================

# The EC2 instance uses the EC2-Admin IAM role.
# This allows kubectl from that EC2 instance to access EKS.

resource "aws_eks_access_entry" "ec2_admin" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = "arn:aws:iam::082487811368:role/EC2-Admin"
  type          = "STANDARD"

  depends_on = [
    aws_eks_cluster.eks
  ]
}

# ============================================================
# EKS ACCESS POLICY
# ============================================================

resource "aws_eks_access_policy_association" "ec2_admin" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_eks_access_entry.ec2_admin.principal_arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [
    aws_eks_access_entry.ec2_admin
  ]
}

# ============================================================
# WORKER NODE IAM ROLE
# ============================================================

resource "aws_iam_role" "worker_role" {
  name = "eks-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "eks-worker-role"
  }
}

# ============================================================
# WORKER NODE IAM POLICIES
# ============================================================

resource "aws_iam_role_policy_attachment" "worker_node" {
  role = aws_iam_role.worker_role.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni" {
  role = aws_iam_role.worker_role.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role = aws_iam_role.worker_role.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ============================================================
# EKS MANAGED NODE GROUP
# ============================================================

resource "aws_eks_node_group" "node_group" {
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "eks-node-group"

  node_role_arn = aws_iam_role.worker_role.arn

  version = var.cluster_version

  subnet_ids = [
    aws_subnet.private1.id,
    aws_subnet.private2.id
  ]

  # Keeping t3.micro as requested.
  # NOTE:
  # t3.micro has very limited pod capacity.
  # This is the reason CoreDNS is currently unable
  # to schedule in your cluster.
  instance_types = ["t3.small"]

  scaling_config {
    desired_size = 2
    max_size     = 2
    min_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_node,
    aws_iam_role_policy_attachment.cni,
    aws_iam_role_policy_attachment.ecr
  ]

  tags = {
    Name = "eks-node-group"
  }
}

# ============================================================
# VPC CNI ADD-ON
# ============================================================

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group
  ]
}

# ============================================================
# COREDNS ADD-ON
# ============================================================

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group
  ]
}

# ============================================================
# KUBE-PROXY ADD-ON
# ============================================================

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group
  ]
}

# ============================================================
# EKS POD IDENTITY AGENT
# ============================================================

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "eks-pod-identity-agent"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group
  ]
}

# ============================================================
# EBS CSI IAM ROLE
# ============================================================

resource "aws_iam_role" "ebs_csi_role" {
  name = "AmazonEKS_EBS_CSI_DriverRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "pods.eks.amazonaws.com"
        }

        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = {
    Name = "AmazonEKS_EBS_CSI_DriverRole"
  }
}

# ============================================================
# EBS CSI IAM POLICY
# ============================================================

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role = aws_iam_role.ebs_csi_role.name

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ============================================================
# EBS CSI POD IDENTITY ASSOCIATION
# ============================================================

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name = aws_eks_cluster.eks.name

  namespace = "kube-system"

  service_account = "ebs-csi-controller-sa"

  role_arn = aws_iam_role.ebs_csi_role.arn

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_policy,
    aws_eks_addon.pod_identity
  ]
}

# ============================================================
# EBS CSI ADD-ON
# ============================================================

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "aws-ebs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.node_group,
    aws_eks_addon.pod_identity,
    aws_eks_pod_identity_association.ebs_csi
  ]
}

# ============================================================
# ADMIN / BASTION EC2
# ============================================================

resource "aws_instance" "eks" {
  ami           = "ami-02dfbd4ff395f2a1b"
  instance_type = "t3.micro"

  subnet_id = aws_subnet.public1.id

  vpc_security_group_ids = [
    aws_security_group.allow_all.id
  ]

  root_block_device {
    volume_size = 30
  }

  tags = {
    Name = "eks"
  }

  user_data = <<-EOF
    #!/bin/bash

    set -e

    # Update packages
    dnf update -y

    # Install required packages
    dnf install -y curl unzip

    # Install AWS CLI if required
    if ! command -v aws >/dev/null 2>&1; then
      curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
      unzip -q /tmp/awscliv2.zip -d /tmp
      /tmp/aws/install
    fi

    # Install kubectl
    curl -o /usr/local/bin/kubectl \
      https://s3.us-west-2.amazonaws.com/amazon-eks/1.35.0/2025-01-02/bin/linux/amd64/kubectl

    chmod +x /usr/local/bin/kubectl

    # Install eksctl
    ARCH=amd64
    PLATFORM=$(uname -s)_$ARCH

    curl -sL \
      "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz" \
      | tar xz -C /usr/local/bin

    chmod +x /usr/local/bin/eksctl

  EOF
}
