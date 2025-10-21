provider "aws" {
  region = "us-west-1"
}

resource "aws_instance" "example" {
  ami           = "ami-033a3fad07a25c231"
  instance_type = "t2.micro"

  tags = {
    Name = "terraform-demo1"
  }
}
