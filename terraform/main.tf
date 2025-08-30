terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region
  profile = "terraform-provisioner"
}

# Default VPC and subnets
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ECR repo
resource "aws_ecr_repository" "app" {
  name = "${var.project}-repo"
  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete = true
}

# S3 bucket for artifacts
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project}-artifacts-${random_id.suffix.hex}"
  force_destroy = true
}

# Security group for EC2
resource "aws_security_group" "web_sg" {
  name        = "${var.project}-sg"
  description = "Allow SSH and app port 8080"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
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

# IAM for EC2 to pull from ECR
resource "aws_iam_role" "ec2_role" {
  name = "${var.project}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Latest Ubuntu 22.04
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# User data + locals
locals {
  ecr_url   = "${aws_ecr_repository.app.repository_url}:latest"
  registry  = replace(aws_ecr_repository.app.repository_url, "/${aws_ecr_repository.app.name}", "")
  user_data = <<-EOF
    #!/bin/bash
    set -eux

    # Docker
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg unzip
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io

    # AWS CLI v2
    curl -Ls "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /root/awscliv2.zip
    unzip /root/awscliv2.zip -d /root
    /root/aws/install

    # ECR login, pull, run
    REGION="${var.region}"
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${local.registry}
    docker pull ${local.ecr_url} || true
    docker run -d -p 8080:8080 --restart unless-stopped --name helloapp ${local.ecr_url} || true
  EOF
}

# EC2 instance
resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name               = var.key_pair_name
  user_data              = local.user_data

  tags = {
    Name = "${var.project}-web"
  }
}

# Outputs
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ec2_public_ip" {
  value = aws_instance.web.public_ip
}

output "app_url" {
  value = "http://${aws_instance.web.public_dns}:8080"
}
