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

data "aws_secretsmanager_secret_version" "mail_password" {
  secret_id = "peex-mail-password"
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



# Namespaces
resource "kubernetes_namespace" "staging" {
  metadata { name = "staging" }
  depends_on = [aws_eks_cluster.peex, aws_eks_node_group.default]
}

resource "kubernetes_namespace" "production" {
  metadata { name = "production" }
  depends_on = [aws_eks_cluster.peex, aws_eks_node_group.default]
}

# Secrets management
resource "kubernetes_secret" "mail_password_staging" {
  metadata {
    name      = "mail-secret"
    namespace = "staging"
  }

  data = {
    MAIL_PASSWORD = base64encode(
      data.aws_secretsmanager_secret_version.mail_password.secret_string
    )
  }

  depends_on = [kubernetes_namespace.staging]
}

resource "kubernetes_secret" "mail_password_production" {
  metadata {
    name      = "mail-secret"
    namespace = "production"
  }

  data = {
    MAIL_PASSWORD = base64encode(
      data.aws_secretsmanager_secret_version.mail_password.secret_string
    )
  }

  depends_on = [kubernetes_namespace.production]
}

resource "kubernetes_service_account" "app_staging" {
  metadata {
    name      = "peex-app-sa"
    namespace = kubernetes_namespace.staging.metadata[0].name
  }
}

resource "kubernetes_service_account" "app_production" {
  metadata {
    name      = "peex-app-sa"
    namespace = kubernetes_namespace.production.metadata[0].name
  }
}

resource "kubernetes_role" "read_mail_secret_staging" {
  metadata {
    name      = "read-mail-secret"
    namespace = kubernetes_namespace.staging.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    resource_names = ["mail-secret"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "bind_mail_secret_staging" {
  metadata {
    name      = "bind-mail-secret"
    namespace = kubernetes_namespace.staging.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.read_mail_secret_staging.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.app_staging.metadata[0].name
    namespace = kubernetes_namespace.staging.metadata[0].name
  }
}

resource "kubernetes_role" "read_mail_secret_production" {
  metadata {
    name      = "read-mail-secret"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    resource_names = ["mail-secret"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "bind_mail_secret_production" {
  metadata {
    name      = "bind-mail-secret"
    namespace = kubernetes_namespace.production.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.read_mail_secret_production.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.app_production.metadata[0].name
    namespace = kubernetes_namespace.production.metadata[0].name
  }
}
