variable "vpc_id" {
  description = "VPC onde a instancia sera criada (escolhida via describe-vpcs)."
  type        = string
}

variable "subnet_id" {
  description = "Subnet onde a instancia sera criada (escolhida via describe-subnets)."
  type        = string
}

variable "instance_type" {
  description = "Tamanho da instancia EC2."
  type        = string
  default     = "t3.micro"
}
