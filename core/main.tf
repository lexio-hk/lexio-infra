terraform {
  backend "s3" {
    bucket = "terraform-state.lexioapp.com"
    key    = "file.state"
    region = "us-east-1"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

provider "aws" {}
variable "project" { default = "prod" }
variable "hosted_zone" { default = "lexioapp.com" }
variable "owner" { default = "lexio" }
variable "aws_key_pair_name" {
  description = "AWS Key Pair name to use for EC2 Instances (if already existent)"
  type        = string
  default     = null
}

output "networks" {
  value = [for s in aws_subnet.private : s.availability_zone]
}

# AWS VPC
resource "aws_vpc" "main" {
  cidr_block                       = var.aws_vpc_cidr
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = false

  tags = {
    Name    = "${var.project}-vpc"
    Project = var.project
    Owner   = var.owner
  }
}

# Route53 HostedZone ID from name
data "aws_route53_zone" "selected" {
  name         = "${var.hosted_zone}."
  private_zone = false
}

variable "aws_vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.23.0.0/16"
}

variable "availability_zones" {
  description = "Number of different AZs to use"
  type        = number
  default     = 3
}


# Public Subnets
resource "aws_subnet" "public" {
  count             = var.availability_zones
  availability_zone = data.aws_availability_zones.available.names[count.index]
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.aws_vpc_cidr, 8, count.index + 11)
  tags = {
    Name      = "${var.project}-public-${count.index}"
    Attribute = "public"
    Project   = var.project
    Owner     = var.owner
  }
}

# Private Subnets
resource "aws_subnet" "private" {
  count                   = var.availability_zones
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.aws_vpc_cidr, 8, count.index + 1)
  map_public_ip_on_launch = false

  tags = {
    Name      = "${var.project}-private-${count.index}"
    Attribute = "private"
    Project   = var.project
    Owner     = var.owner
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project}-igw"
    Project = var.project
    Owner   = var.owner
  }
}

# AWS Route Tables
## Public
resource "aws_route_table" "rt-public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name      = "${var.project}-rt-public"
    Attribute = "public"
    Project   = var.project
    Owner     = var.owner
  }
}

## Private
resource "aws_route_table" "rt-private" {
  count  = var.availability_zones
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.natgw[count.index].id
  }

  tags = {
    Name      = "${var.project}-rt-private"
    Attribute = "private"
    Project   = var.project
    Owner     = var.owner
  }
}

# AWS Elastic IP addresses (EIP) for NAT Gateways
resource "aws_eip" "nat" {
  count = var.availability_zones

  vpc = true

  tags = {
    Name    = "${var.project}-eip-natgw-${count.index}"
    Project = var.project
    Owner   = var.owner
  }
}

# AWS NAT Gateways
resource "aws_nat_gateway" "natgw" {
  count = var.availability_zones

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = element(aws_subnet.public.*.id, count.index)

  tags = {
    Name    = "${var.project}-natgw-${count.index}"
    Project = var.project
    Owner   = var.owner
  }
}



output "vpc_id" {
  value = aws_vpc.main.id
}

data "aws_subnet_ids" "subnet_ids" {
  depends_on = [
    aws_subnet.private
  ]
  vpc_id = aws_vpc.main.id
  tags = {
    Attribute = "private"
  }
}

output "subnet_ids" {
  value = data.aws_subnet_ids.subnet_ids.ids.*
}

## Bastion Host
data "aws_iam_policy_document" "bastion" {
  statement {
    sid = "bastion"
    actions = [
      "autoscaling:DescribeAutoScalingInstances",
      "ec2:CreateRoute",
      "ec2:CreateTags",
      "ec2:DescribeAutoScalingGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "ec2:DescribeRouteTables",
      "ec2:DescribeTags",
      "elasticloadbalancing:DescribeLoadBalancers",
      "route53:ListHostedZonesByName"
    ]
    resources = ["*"]
  }
  statement {
    sid = "route53"
    actions = [
      "route53:ChangeResourceRecordSets"
    ]
    resources = [
      "arn:aws:route53:::hostedzone/${data.aws_route53_zone.selected.zone_id}"
    ]
  }
}

resource "aws_iam_role" "bastion" {
  name_prefix        = "bastion-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name    = "${var.project}-bastion"
    Project = var.project
    Owner   = var.owner
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "bastion" {
  name_prefix = "bastion-"
  role        = aws_iam_role.bastion.id
  policy      = data.aws_iam_policy_document.bastion.json
}

resource "aws_iam_instance_profile" "bastion" {
  name_prefix = "bastion-"
  role        = aws_iam_role.bastion.name
}

# SecurityGroups
resource "aws_security_group" "bastion-lb" {
  name_prefix = "bastion-lb-"
  description = "Bastion-LB"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name    = "${var.project}-bastion-lb"
    Project = var.project
    Owner   = var.owner
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "bastion" {
  name_prefix = "bastion-"
  description = "Bastion"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name    = "${var.project}-bastion"
    Project = var.project
    Owner   = var.owner
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "allow_ingress_bastion-lb_on_bastion_ssh" {
  security_group_id        = aws_security_group.bastion.id
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion-lb.id
  description              = "SSH: Bastion-LB - Bastion"
}

## Egress
resource "aws_security_group_rule" "egress_all" {
  for_each = {
    "BastionLB" = aws_security_group.bastion-lb.id,
    "Bastion"   = aws_security_group.bastion.id,
  }
  security_group_id = each.value
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Egress ALL: ${each.key}"
}

# Load Balancer
## Bastion Host
resource "aws_elb" "bastion" {
  name_prefix     = "basti-" // cannot be longer than 6 characters
  subnets         = aws_subnet.public.*.id
  security_groups = [aws_security_group.bastion-lb.id]

  listener {
    instance_port     = 22
    instance_protocol = "tcp"
    lb_port           = 22
    lb_protocol       = "tcp"
  }

  tags = {
    Name    = "${var.project}-bastion-lb"
    Project = var.project
    Owner   = var.owner
  }
}

# AutoScalingGroups
## Bastion
resource "aws_autoscaling_group" "bastion" {
  max_size             = 1
  min_size             = 1
  desired_capacity     = 1
  force_delete         = false
  launch_configuration = aws_launch_configuration.bastion.name
  vpc_zone_identifier  = aws_subnet.private.*.id
  load_balancers       = [aws_elb.bastion.id]

  tags = [
    {
      key                 = "Name"
      value               = "${var.project}-bastion"
      propagate_at_launch = true
    },
    {
      key                 = "Project"
      value               = var.project
      propagate_at_launch = true
    },
    {
      key                 = "Owner"
      value               = var.owner
      propagate_at_launch = true
    }
  ]
}

# Route53
## Bastion Host
resource "aws_route53_record" "bastion-public" {
  zone_id = data.aws_route53_zone.selected.id
  name    = "bastion"
  type    = "A"

  alias {
    evaluate_target_health = false
    name                   = aws_elb.bastion.dns_name
    zone_id                = aws_elb.bastion.zone_id
  }
}

# LaunchConfigurations
## Bastion Host
resource "aws_launch_configuration" "bastion" {
  name_prefix                 = "bastion-"
  image_id                    = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  security_groups             = [aws_security_group.bastion.id]
  key_name                    = var.aws_key_pair_name == null ? aws_key_pair.ssh.0.key_name : var.aws_key_pair_name
  associate_public_ip_address = false
  ebs_optimized               = true
  enable_monitoring           = true
  iam_instance_profile        = aws_iam_instance_profile.bastion.id

  lifecycle {
    create_before_destroy = true
  }
}

# IAM Roles for EC2 Instance Profiles
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["ec2.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_key_pair" "ssh" {
  count      = 1
  key_name   = "${var.owner}-${var.project}"
  public_key = file("bin/id_lexio.pub")
}
