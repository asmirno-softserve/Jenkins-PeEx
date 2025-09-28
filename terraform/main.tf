provider "aws" {
  region = "eu-central-1"
}

terraform {
  backend "s3" {
    bucket         = "peex-jenkins"   # must exist already
    key            = "jenkins/terraform.tfstate"   # path inside the bucket
    region         = "eu-central-1"
    encrypt        = true
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_key_pair" "jenkins-key" {
  key_name = "ec2-jenkins-key"
}

resource "aws_instance" "jenkins" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.large"
  subnet_id                   = aws_subnet.jenkins_subnet.id
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  key_name                    = data.aws_key_pair.jenkins-key.key_name
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.jenkins_profile.name

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y python3 python3-apt
  EOF

  tags = {
    Name = "jenkins-server"
  }
}

resource "aws_security_group" "jenkins_sg" {
  name   = "jenkins-sg"
  vpc_id = aws_vpc.jenkins_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc" "jenkins_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "jenkins-vpc" }
}

resource "aws_subnet" "jenkins_subnet" {
  vpc_id                  = aws_vpc.jenkins_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-central-1a"
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

resource "aws_route_table_association" "jenkins_rta" {
  subnet_id      = aws_subnet.jenkins_subnet.id
  route_table_id = aws_route_table.jenkins_rt.id
}

# IAM Role for Jenkins EC2
resource "aws_iam_role" "jenkins_role" {
  name = "jenkins-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

# Attach policy for ECR access (pull & push images)
resource "aws_iam_role_policy_attachment" "jenkins_ecr_policy" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

# Instance profile for EC2 to use the role
resource "aws_iam_instance_profile" "jenkins_inst_profile" {
  name = "jenkins-ec2-profile"
  role = aws_iam_role.jenkins_role.name
}


# Allow full access to S3 (you can narrow this down to specific buckets if needed)
resource "aws_iam_role_policy_attachment" "jenkins_s3_policy" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# Allow read access to Secrets Manager
resource "aws_iam_role_policy_attachment" "jenkins_secrets_manager_policy" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
}

output "ansible_inventory_yaml" {
  value = <<EOT
all:
  hosts:
    ${aws_instance.jenkins.public_ip}:
      ansible_user: ubuntu
      ansible_ssh_private_key_file: ansible/jenkins-key.pem
EOT
}