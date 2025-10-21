
##############################
# Provider and VPC Setup
##############################
provider "aws" {
  region = "eu-west-1"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = { Name = "main-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "main-igw" }
}

##############################
# Public Subnet for ALB
##############################
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "eu-west-1a"
  tags = { Name = "public-subnet" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

##############################
# Private Subnets for EC2 + RDS
##############################
resource "aws_subnet" "private" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet("10.0.0.0/16", 8, count.index + 2)
  map_public_ip_on_launch = false
  availability_zone       = "eu-west-1${element(["a","b","c"], count.index)}"
  tags = { Name = "private-subnet-${count.index}" }
}

##############################
# Security Groups
##############################
resource "aws_security_group" "alb_sg" {
  vpc_id = aws_vpc.main.id
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
  tags = { Name = "alb-sg" }
}

resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "ec2-sg" }
}

resource "aws_security_group" "rds_sg" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "rds-sg" }
}

##############################
# Application Load Balancer
##############################
resource "aws_lb" "app_lb" {
  name               = "app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public.id]
}

resource "aws_lb_target_group" "tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

##############################
# EC2 Launch Template + AutoScaling Group
##############################
resource "aws_launch_template" "web_template" {
  name_prefix   = "web-"
  image_id      = "ami-033a3fad07a25c231"
  instance_type = "t3.micro"
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  user_data = base64encode("#!/bin/bash\nyum install -y httpd\nsystemctl start httpd")
}

resource "aws_autoscaling_group" "web_asg" {
  name                = "web-asg"
  min_size            = 3
  max_size            = 3
  desired_capacity    = 3
  vpc_zone_identifier = aws_subnet.private[*].id
  launch_template {
    id      = aws_launch_template.web_template.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.tg.arn]
  depends_on = [aws_lb_listener.listener]
}

##############################
# RDS (with Multi-AZ + Read Replicas)
##############################
resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "primary" {
  identifier           = "primary-db"
  engine               = "mysql"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20
  db_name              = "appdb"
  username             = "admin"
  password             = "Admin1234!"
  skip_final_snapshot  = true
  multi_az             = true
  db_subnet_group_name = aws_db_subnet_group.db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
}

resource "aws_db_instance" "replica" {
  count                 = 2
  identifier            = "replica-db-${count.index}"
  replicate_source_db   = aws_db_instance.primary.id
  instance_class        = "db.t3.micro"
  publicly_accessible   = false
  depends_on            = [aws_db_instance.primary]
}
