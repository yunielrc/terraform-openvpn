###############################################################################
# VARIABLES
###############################################################################

variable "user_public_key" {
  default = ""
}

# VPN

variable "aws_region" {
  default = "us-east-2"
}

variable "ssh_remote_user" {
  default = "ubuntu"
}

variable "ssh_public_key_path" {
  default = "~/.ssh/id_rsa.pub"
}

variable "vpn_data" {
  default = "openvpn-data-default"
}

variable "vpn_port" {
  default = 443
}

variable "vpn_client_name" {
  default = "awesome-personal-vpn"
}

variable "vpn_image_tag" {
  default = "2.4"
}

# PROXY

variable "proxy_config_dir" {
  default = "/home/ubuntu/sameersbn_squid"
}

variable "proxy_cache" {
  default = "proxy-cache-default"
}

variable "proxy_user" {
  type = string
}

variable "proxy_password" {
  type = string
}

variable "proxy_port" {
  default = 5151
}

variable "proxy_image_tag" {
  default = "3.5.27-2"
}

###############################################################################
# PROVIDERS
###############################################################################

provider "aws" {
  profile = "default"
  region  = var.aws_region
}

###############################################################################
# RESOURCES
###############################################################################

resource "aws_key_pair" "deployer" {
  key_name   = "terraform-deployer-key"
  public_key = var.user_public_key != "" ? var.user_public_key : file(var.ssh_public_key_path)
}

resource "aws_security_group" "vpn" {
  name = "terraform-vpn-security-group"

  ingress {
    from_port   = var.vpn_port
    to_port     = var.vpn_port
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# FIX: this group is not created in ec2
resource "aws_security_group" "proxy" {
  name = "terraform-proxy-security-group"

  ingress {
    from_port   = var.proxy_port
    to_port     = var.proxy_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ssh" {
  name = "terraform-ssh-security-group"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "outgoing" {
  name = "terraform-outgoing-security-group"

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "vpn" {
  instance_type = "t2.micro"
  # Ubuntu 20.04 LTS (AMI)
  ami = "ami-01237fce26136c8cc"

  vpc_security_group_ids = [
    aws_security_group.vpn.id,
    aws_security_group.proxy.id,
    aws_security_group.ssh.id,
    aws_security_group.outgoing.id,
  ]

  key_name = "terraform-deployer-key"

  connection {
    host  = aws_instance.vpn.public_dns
    user  = var.ssh_remote_user
    agent = true
  }

  # setup docker
  provisioner "remote-exec" {
    inline = [
      "wget -qO - https://raw.githubusercontent.com/yunielrc/install-scripts/master/dist/packages/docker/docker-ubuntu | bash",
    ]
  }

  # setup http proxy
  provisioner "file" {
    source      = "sameersbn_squid"
    destination = "/home/${var.ssh_remote_user}"
  }

  provisioner "file" {
    source      = "passwd"
    destination = "${var.proxy_config_dir}/etc/squid/passwd"
  }

  provisioner "remote-exec" {
    inline = [
      "docker volume create --name ${var.proxy_cache}",
      "docker run --name squid -d --restart always -p ${var.proxy_port}:3128 -v ${var.proxy_config_dir}/etc/squid:/etc/squid:ro -v ${var.proxy_cache}:/var/spool/squid sameersbn/squid:${var.proxy_image_tag}"
    ]
  }

  # setup openvpn docker container
  provisioner "remote-exec" {
    inline = [
      "docker volume create --name ${var.vpn_data}",
      "docker run -v ${var.vpn_data}:/etc/openvpn --rm kylemanna/openvpn:${var.vpn_image_tag} ovpn_genconfig -u udp://${aws_instance.vpn.public_dns}",
      "yes 'yes' | docker run -v ${var.vpn_data}:/etc/openvpn --rm -i kylemanna/openvpn:${var.vpn_image_tag} ovpn_initpki nopass",
      # "systemctl stop systemd-resolved.service && systemctl disable systemd-resolved.service",
      "docker run --restart always -v ${var.vpn_data}:/etc/openvpn -d -p ${var.vpn_port}:1194/udp --cap-add=NET_ADMIN kylemanna/openvpn:${var.vpn_image_tag}",
      "docker run -v ${var.vpn_data}:/etc/openvpn --rm -it kylemanna/openvpn:${var.vpn_image_tag} easyrsa build-client-full ${var.vpn_client_name} nopass",
      "docker run -v ${var.vpn_data}:/etc/openvpn --rm kylemanna/openvpn:${var.vpn_image_tag} ovpn_getclient ${var.vpn_client_name} > ~/${var.vpn_client_name}.ovpn",
    ]
  }

  provisioner "local-exec" {
    command = "ssh-keyscan -T 120 ${aws_instance.vpn.public_ip} >> ~/.ssh/known_hosts"
  }

  provisioner "local-exec" {
    command = "scp ${var.ssh_remote_user}@${aws_instance.vpn.public_ip}:~/${var.vpn_client_name}.ovpn ~/"
  }
}

###############################################################################
# OUTPUT
###############################################################################

output "aws_instance_public_dns" {
  value = aws_instance.vpn.public_dns
}

output "aws_instance_public_ip" {
  value = aws_instance.vpn.public_ip
}

output "vpn_client_configuration_file" {
  value = "~/${var.vpn_client_name}.ovpn"
}

output "proxy_url" {
  value = "http://${var.proxy_user}:${var.proxy_password}@${aws_instance.vpn.public_ip}:${var.proxy_port}"
}

output "closing_message" {
  value = "Your VPN and proxy are ready!"
}
