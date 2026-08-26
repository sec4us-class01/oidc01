resource "tls_private_key" "lab" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "lab" {
  key_name   = "lab-vpc-enum"
  public_key = tls_private_key.lab.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.lab.private_key_openssh
  filename        = "${path.module}/id_rsa_lab"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content         = tls_private_key.lab.public_key_openssh
  filename        = "${path.module}/id_rsa_lab.pub"
  file_permission = "0644"
}

output "ssh_key_path" {
  value = local_sensitive_file.private_key.filename
}
