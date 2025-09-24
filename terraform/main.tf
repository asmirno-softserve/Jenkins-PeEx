provider "aws" {
  region = "eu-central-1"
}

resource "aws_instance" "jenkins_target" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t2.micro"

  tags = {
    Name = "jenkins-target"
  }
}

resource "aws_security_group" "allow_ssh_http" {
  name        = "allow_ssh_http"
  description = "Allow SSH and HTTP"

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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

output "public_ip" {
  value = aws_instance.jenkins_target.public_ip
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.yaml"
  content  = <<EOT
all:
  hosts:
    ${aws_instance.jenkins.public_ip}:
      ansible_user: ubuntu
      ansible_ssh_private_key_file: ~/Downloads/PeEx.pem
EOT
}
