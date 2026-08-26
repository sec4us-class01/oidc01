resource "aws_security_group" "ec2_lab" {
  name        = "ec2-lab"
  description = "Lab EC2: SSH publico (lab) + egress irrestrito."
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH liberado para qualquer origem (apenas lab!)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Saida irrestrita (apt, internet)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "lab" {
  ami           = data.aws_ami.ubuntu_2404.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  key_name      = aws_key_pair.lab.key_name

  vpc_security_group_ids      = [aws_security_group.ec2_lab.id]
  associate_public_ip_address = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 obrigatorio
    http_put_response_hop_limit = 2
  }

  user_data = <<-EOT
    #!/bin/bash
    set -eux
    apt-get update -y
    apt-get install -y curl unzip jq
  EOT

  tags = {
    Name = "lab-ec2"
  }
}

output "instance_id" {
  value = aws_instance.lab.id
}

output "public_ip" {
  value = aws_instance.lab.public_ip
}

output "ami_id" {
  value = data.aws_ami.ubuntu_2404.id
}

output "ami_name" {
  value = data.aws_ami.ubuntu_2404.name
}
