provider "aws" {
  region = "eu-central-1"
}

terraform {
  backend "s3" {
    bucket         = "peex-jenkins" 
    key            = "jenkins/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
  }
}

# Network
resource "aws_vpc" "jenkins_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "jenkins-vpc" }
}

resource "aws_subnet" "jenkins_subnet_a" {
  vpc_id                  = aws_vpc.jenkins_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-central-1a"
  map_public_ip_on_launch = true

  tags = { Name = "jenkins-subnet" }
}

resource "aws_subnet" "jenkins_subnet_b" {
  vpc_id                  = aws_vpc.jenkins_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "eu-central-1b"
  map_public_ip_on_launch = true

  tags = { Name = "jenkins-subnet" }
}

resource "aws_internet_gateway" "jenkins_igw" {
  vpc_id = aws_vpc.jenkins_vpc.id
}

resource "aws_route_table" "jenkins_rt" {
  vpc_id = aws_vpc.jenkins_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.jenkins_igw.id
  }
}

resource "aws_route_table_association" "jenkins_rta_a" {
  subnet_id      = aws_subnet.jenkins_subnet_a.id
  route_table_id = aws_route_table.jenkins_rt.id
}

resource "aws_route_table_association" "jenkins_rta_b" {
  subnet_id      = aws_subnet.jenkins_subnet_b.id
  route_table_id = aws_route_table.jenkins_rt.id
}

# IAM role for EKS cluster
resource "aws_iam_role" "eks_cluster" {
  name = "peex-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "eks.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSVPCResourceController" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# EKS cluster
resource "aws_eks_cluster" "peex" {
  name     = "peex-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.29"

  vpc_config {
    subnet_ids = [aws_subnet.jenkins_subnet_a.id, aws_subnet.jenkins_subnet_b.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSVPCResourceController,
  ]
}

# IAM role for worker nodes
resource "aws_iam_role" "eks_nodes" {
  name = "peex-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_nodes_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_nodes_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_nodes_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# EKS managed node group
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.peex.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [aws_subnet.jenkins_subnet_a.id, aws_subnet.jenkins_subnet_b.id]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_nodes_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.eks_nodes_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.eks_nodes_AmazonEKS_CNI_Policy,
  ]
}

# Auth token for Kubernetes provider
data "aws_eks_cluster_auth" "peex" {
  name = aws_eks_cluster.peex.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.peex.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.peex.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.peex.token
}

# Namespaces depend on EKS cluster
resource "kubernetes_namespace" "staging" {
  metadata { name = "staging" }
  depends_on = [aws_eks_cluster.peex, aws_eks_node_group.default]
}

resource "kubernetes_namespace" "production" {
  metadata { name = "production" }
  depends_on = [aws_eks_cluster.peex, aws_eks_node_group.default]
}
