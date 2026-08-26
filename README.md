# Lab AWS EC2 — Provisionamento de Instância EC2 com Seleção Prévia de VPC

Este lab mostra como subir uma instância **EC2 Ubuntu 24.04 (Noble Numbat)** em uma VPC e subnet **escolhidas manualmente pelo operador antes do `terraform apply`**. A instância é deliberadamente "burra": **não recebe instance profile nem permissões AWS** — é apenas uma VM Linux com SSH. Toda a enumeração de rede (VPCs, subnets) acontece **localmente, antes do setup**, usando uma credencial admin (por exemplo, a criada no lab `aws_admin/`).

Esse fluxo separa claramente dois papéis:

1. **Operador (você, com credencial admin)** — descobre a topologia (`describe-vpcs`, `describe-subnets`), decide onde a VM vai rodar e fixa esses IDs em variáveis Terraform.
2. **VM provisionada** — só serve à carga de trabalho dela; não fala com a API da AWS.

---

## Estrutura do diretório

```
aws_ec2/
├── README.md      # este arquivo
├── .gitignore     # ignora tfstate, tfvars e a chave SSH gerada
├── providers.tf   # provider AWS + tls + local
├── vars.tf        # variaveis vpc_id, subnet_id e instance_type
├── ami.tf         # data source da Ubuntu 24.04 (Canonical)
├── ssh.tf         # gera chave RSA, registra aws_key_pair, salva localmente
└── ec2.tf         # security group + instancia EC2 + outputs
```

## Pré-requisitos

- Terraform e AWS CLI instalados (veja o lab `aws_admin/` para passo-a-passo).
- Credencial AWS configurada em `~/.aws/credentials` com permissão para criar EC2, SG e key pair (a credencial criada pelo lab `aws_admin/` serve).
- AWS CLI v2 e `jq` no terminal local — usados para listar VPCs/subnets antes do `apply`.

## Listando VPCs e subnets antes do setup

Antes de rodar o Terraform, decida em qual VPC e subnet a instância vai nascer. Os IDs ficam fixados em `terraform.tfvars` (ou passados via `-var`) — assim o `apply` é totalmente determinístico, sem depender de "VPC default" (que pode nem existir em contas novas ou em regiões customizadas).

Liste as VPCs da região do provider (`us-east-2`):

```bash
aws ec2 describe-vpcs --region us-east-2 \
  --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,Default:IsDefault,State:State,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

Saída esperada (exemplo):
```
-----------------------------------------------------------------------------
|                              DescribeVpcs                                  |
+----------------+--------------------+-----------+--------+-----------------+
|     Cidr       |      Default       |   State   |  Name  |     VpcId       |
+----------------+--------------------+-----------+--------+-----------------+
|  172.31.0.0/16 |  True              |  available|  None  |  vpc-0a1b2c3d4  |
+----------------+--------------------+-----------+--------+-----------------+
```

Anote o `VpcId` desejado e liste as subnets dele:

```bash
VPC_ID=vpc-0a1b2c3d4   # substitua pelo escolhido acima
aws ec2 describe-subnets --region us-east-2 \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].{SubnetId:SubnetId,Az:AvailabilityZone,Cidr:CidrBlock,Public:MapPublicIpOnLaunch,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

Para um lab acessível por SSH, escolha uma subnet com `Public = True` (ou em uma AZ próxima da sua latência). Anote o `SubnetId`.

> Se a região não tiver VPC default, crie uma rapidamente com `aws ec2 create-default-vpc --region us-east-2` (precisa da permissão correspondente) **ou** monte uma VPC própria via Terraform e use o ID dela aqui.

## Arquivos `.tf` (já criados neste diretório)

### `providers.tf`

```terraform
terraform {
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    tls   = { source = "hashicorp/tls", version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "aws" {
  region = "us-east-2"
}
```

### `vars.tf` — IDs escolhidos manualmente

```terraform
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
```

Como preencher (duas opções equivalentes):

**Opção A — via `terraform.tfvars`** (recomendada; o arquivo já está no `.gitignore`):

```hcl
# terraform.tfvars
vpc_id    = "vpc-0a1b2c3d4"
subnet_id = "subnet-0e5f6a7b8"
```

**Opção B — via flags na linha de comando**:

```bash
terraform apply \
  -var "vpc_id=vpc-0a1b2c3d4" \
  -var "subnet_id=subnet-0e5f6a7b8" \
  -auto-approve
```

> Como as variáveis não têm `default`, o Terraform aborta o `plan/apply` enquanto não receber valores — protegendo contra `apply` acidental sem ter escolhido a VPC.

### `ami.tf` — busca automática da Ubuntu 24.04

```terraform
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (owner oficial das AMIs Ubuntu)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}
```

Como funciona:

- `owners = ["099720109477"]` é o **AWS Account ID da Canonical**, que publica as AMIs oficiais do Ubuntu. Filtrar por owner evita pegar AMIs com o mesmo nome publicadas por terceiros (ataque de *AMI confusion*).
- O filtro `name` casa o codinome **Noble** (Ubuntu 24.04) com root volume gp3 — formato atual das AMIs Canonical.
- `most_recent = true` garante que, mesmo havendo várias publicações da mesma versão (patches), o Terraform pega a última.
- Como é um `data source`, o Terraform resolve o ID **a cada plan/apply** — sua infra acompanha automaticamente a versão mais recente da AMI Canonical, sem precisar editar código.

### `ssh.tf` — geração e armazenamento local da chave SSH

```terraform
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
```

Como funciona:

- **`tls_private_key`** (provider `hashicorp/tls`) gera uma chave **RSA 4096** localmente. A chave existe **apenas no state do Terraform** — não roda nada na conta AWS para criá-la.
- **`aws_key_pair`** registra a parte **pública** na AWS com o nome `lab-vpc-enum`, que será referenciado pela instância EC2 via `key_name`.
- **`local_sensitive_file`** grava a chave **privada** no diretório do projeto como `id_rsa_lab` com permissão `0600` (só o dono lê/escreve). O sufixo `_sensitive_file` faz com que o Terraform **não imprima o conteúdo** em logs/plans.
- **`local_file`** grava a chave pública como `id_rsa_lab.pub` para conferência rápida (ex.: `ssh-keygen -lf id_rsa_lab.pub`).
- O output `ssh_key_path` é só um atalho para `terraform output -raw ssh_key_path`.

> ⚠️ A chave privada fica na pasta do `terraform.tfstate` e **dentro do próprio state** (em texto plano). Trate o diretório do projeto como segredo; o `.gitignore` já bloqueia `id_rsa_lab*` e `terraform.tfstate*`.

### `ec2.tf` — SG e instância EC2

```terraform
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
```

Pontos de atenção:

- **Sem `iam_instance_profile`**: a instância **não recebe credencial AWS alguma**. Nem o IMDS retorna `iam/security-credentials/...` — qualquer chamada `aws ec2 describe-*` de dentro da VM falha com `Unable to locate credentials`. Foi essa a decisão arquitetural deste lab.
- **`var.vpc_id` / `var.subnet_id`**: vêm direto de `vars.tf`. Se o operador errar o ID, o Terraform aborta no plan (ID inexistente) ou no `apply` (subnet não pertence à VPC).
- **Ingress `tcp/22` em `0.0.0.0/0`**: porta SSH **aberta para a internet inteira**. Aceitável apenas em laboratório efêmero. Em produção restrinja para o seu IP corporativo (`<seu-ip>/32`).
- **`key_name`** referencia o `aws_key_pair.lab` criado em `ssh.tf` — é assim que a chave pública vai parar em `/home/ubuntu/.ssh/authorized_keys` no boot.
- **`associate_public_ip_address = true`** garante IP público mesmo se a subnet escolhida não auto-atribuir (`MapPublicIpOnLaunch = false`).
- **IMDSv2 obrigatório**: defesa em profundidade — mesmo sem instance profile, IMDSv2 reduz a superfície de SSRF caso alguma carga de trabalho futura passe a usar credenciais.
- **`user_data` mínimo**: só `curl`, `unzip` e `jq`. Sem AWS CLI (não há credencial para usar).

## Aplicando

Com os IDs já fixados em `terraform.tfvars` (ou passados via `-var`):

```bash
terraform init    # primeira execucao
terraform apply -auto-approve
```

Sem `terraform.tfvars`, passe os valores na linha de comando:

```bash
terraform apply \
  -var "vpc_id=vpc-0a1b2c3d4" \
  -var "subnet_id=subnet-0e5f6a7b8" \
  -auto-approve
```

A saída do `apply` deve mostrar `instance_id`, `public_ip`, `ami_id`, `ami_name` e `ssh_key_path`. Os arquivos `id_rsa_lab` e `id_rsa_lab.pub` aparecem no diretório do projeto.

Confira:

```bash
ls -l id_rsa_lab id_rsa_lab.pub
# -rw-------  ...  id_rsa_lab
# -rw-r--r--  ...  id_rsa_lab.pub

ssh-keygen -lf id_rsa_lab.pub   # mostra o fingerprint da chave gerada
```

## Conectando via SSH

```bash
PUBLIC_IP=$(terraform output -raw public_ip)
ssh -i ./id_rsa_lab ubuntu@"$PUBLIC_IP"
```

- Usuário default das AMIs Canonical do Ubuntu é `ubuntu`.
- Se o `ssh` reclamar de permissão da chave (`UNPROTECTED PRIVATE KEY FILE!`), rode `chmod 600 ./id_rsa_lab` — o `local_sensitive_file` já cria com `0600`, mas alguns sistemas de arquivos (ex.: pasta sincronizada com Dropbox/iCloud) podem alterar o modo.
- Espere ~60 s após o `apply` antes da primeira conexão: o cloud-init ainda está rodando o `user_data`. Você pode acompanhar com `sudo tail -f /var/log/cloud-init-output.log` assim que entrar.

## Validando a topologia (do lado de fora da instância)

Como a instância **não tem permissão** para chamar a API da AWS, qualquer enumeração extra continua sendo feita no terminal do operador (mesma credencial admin):

```bash
INSTANCE_ID=$(terraform output -raw instance_id)

# Confirma onde a instancia foi lancada
aws ec2 describe-instances --region us-east-2 \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Vpc:VpcId,Subnet:SubnetId,Az:Placement.AvailabilityZone,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress,State:State.Name}' \
  --output table

# Roteamento da subnet escolhida
aws ec2 describe-route-tables --region us-east-2 \
  --filters "Name=association.subnet-id,Values=$(grep -E '^subnet_id' terraform.tfvars 2>/dev/null | cut -d'"' -f2)" \
  --query 'RouteTables[].Routes[].{Destino:DestinationCidrBlock,Alvo:GatewayId||NatGatewayId||TransitGatewayId}' \
  --output table
```

Se preferir testar de dentro da instância sem dar permissão, instale uma chave de longo prazo (não recomendado) ou suba a CLI com **credenciais temporárias** via `aws configure --profile ...` no shell do `ubuntu`. A premissa deste lab, no entanto, é manter a VM sem qualquer acesso AWS.

## Diagnóstico rápido

| Sintoma | Causa provável | Como confirmar |
| --- | --- | --- |
| `Error: Missing required argument: vpc_id` | Faltou `terraform.tfvars` ou `-var "vpc_id=..."` | Veja `vars.tf` e a seção "Aplicando" |
| `InvalidSubnetID.NotFound` no apply | `subnet_id` errado ou da região errada | Refaça `aws ec2 describe-subnets --region <regiao>` |
| `InvalidParameterValue: subnet ... is not in vpc ...` | `subnet_id` não pertence ao `vpc_id` informado | Filtre `describe-subnets` por `Name=vpc-id,Values=<vpc_id>` |
| SSH `Connection refused` / timeout | SG sem ingress 22, IP errado, instância ainda bootando | Verifique no console que o SG `ec2-lab` tem regra `tcp/22 0.0.0.0/0`; refaça `terraform output public_ip`; espere ~60 s do `apply` |
| `Permission denied (publickey)` | Permissão da chave errada ou usuário trocado | `chmod 600 id_rsa_lab` e use `ubuntu@`, não `ec2-user@` |
| `UNPROTECTED PRIVATE KEY FILE!` | Permissão da chave > `0600` | `chmod 600 ./id_rsa_lab` |
| `ami_id` vazio / Terraform falha em `data.aws_ami` | Filtro não casou | Mude o `name` para `*ubuntu-noble-24.04-amd64-server-*` (alguns lançamentos usam `hvm-ssd` em vez de `hvm-ssd-gp3`) |
| `user_data` não rodou | Cloud-init falhou | `sudo cat /var/log/cloud-init-output.log` na instância |

## Limpeza

```bash
terraform destroy -auto-approve
```

`destroy` remove a instância, o SG e o key pair na AWS. Os arquivos locais `id_rsa_lab`/`id_rsa_lab.pub` também são apagados pelo provider `local`.

## Hardening adicional para produção

- **Restrinja o ingress 22**: troque `cidr_blocks = ["0.0.0.0/0"]` por `["<seu-ip-publico>/32"]` ou pelo CIDR da VPN corporativa. Melhor ainda: substitua SSH por **SSM Session Manager** — nesse caso, a instância passa a precisar de instance profile com `AmazonSSMManagedInstanceCore` (revertendo a decisão deste lab).
- **Não armazene a chave privada no state**: em produção, use `aws_key_pair` apontando para uma chave pública já existente (`file("~/.ssh/id_rsa.pub")`) e mantenha a privada fora do repositório. O fluxo "gerar e salvar localmente" só faz sentido em laboratório.
- **Subnet privada + NAT/Endpoints**: se a carga de trabalho não precisa de internet entrante, escolha uma subnet privada e dispense o `associate_public_ip_address`.
- Habilite EBS encryption via `root_block_device { encrypted = true }`.
- Mantenha `imdsv2` obrigatório (já feito) e considere `http_endpoint = "disabled"` se a aplicação realmente não usa IMDS.
- Versione os IDs em `terraform.tfvars` por ambiente (`dev.tfvars`, `prod.tfvars`) e use `terraform apply -var-file=prod.tfvars` para evitar trocar VPC manualmente.
