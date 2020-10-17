###############################################################################
# VARIABLES
###############################################################################

locals {
  ssh_remote_user = "ubuntu"
  cidr_blocks     = ["0.0.0.0/0"]
}

variable "aws_region" {
  default = "us-east-2"
}

variable "user_public_key" {
  default = ""
}

variable "connection_use_agent" {
  default = true
}

# VPN
locals {
  vpn_data        = "openvpn-data"
  vpn_client_name = "${var.aws_region}-vpn"
}

variable "vpn_port" {
  default = 1194
}

variable "vpn_image_tag" {
  default = "2.4"
}

# PROXY
locals {
  proxy_config_dir = "/home/${local.ssh_remote_user}/sameersbn_squid"
  proxy_cache      = "proxy-cache"
}

variable "proxy_user" {
  type = string
}

variable "proxy_password" {
  type = string
}

variable "proxy_port" {
  default = 3128
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
  public_key = var.user_public_key != "" ? var.user_public_key : file("~/.ssh/id_rsa.pub")
}

resource "aws_security_group" "vpn" {
  name = "terraform-vpn-security-group"

  # vpn
  ingress {
    from_port   = var.vpn_port
    to_port     = var.vpn_port
    protocol    = "udp"
    cidr_blocks = local.cidr_blocks
  }

  # proxy
  ingress {
    from_port   = var.proxy_port
    to_port     = var.proxy_port
    protocol    = "tcp"
    cidr_blocks = local.cidr_blocks
  }

  # ssh
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.cidr_blocks
  }

  # outgoing
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = local.cidr_blocks
  }
}

resource "aws_instance" "vpn" {
  instance_type          = "t2.micro"
  ami                    = "ami-01237fce26136c8cc" # Ubuntu 20.04 LTS
  vpc_security_group_ids = [aws_security_group.vpn.id]
  key_name               = "terraform-deployer-key"

  connection {
    host  = self.public_dns
    user  = local.ssh_remote_user
    agent = var.connection_use_agent
  }

  provisioner "remote-exec" {
    script = "enable-ssh-root"
  }

  # SETUP DOCKER
  provisioner "remote-exec" {
    inline = [
      "wget -qO - https://raw.githubusercontent.com/yunielrc/install-scripts/master/dist/packages/docker/docker-ubuntu | bash",
    ]
  }

  # SETUP HTTP PROXY
  provisioner "file" {
    source      = "sameersbn_squid"
    destination = "/home/${local.ssh_remote_user}"
  }

  provisioner "remote-exec" {
    inline = [
      "apt-get update -y; apt-get install -y apache2-utils"
    ]
    connection {
      host  = self.public_dns
      user  = "root"
      agent = var.connection_use_agent
    }
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.proxy_password}' | htpasswd -i -c ${local.proxy_config_dir}/etc/squid/passwd ${var.proxy_user}",
      "docker volume create --name ${local.proxy_cache}",
      "docker run --name squid -d --restart always -p ${var.proxy_port}:3128 -v ${local.proxy_config_dir}/etc/squid:/etc/squid:ro -v ${local.proxy_cache}:/var/spool/squid sameersbn/squid:${var.proxy_image_tag}"
    ]
  }

  # SETUP OPENVPN
  provisioner "remote-exec" {
    inline = [
      <<-EOT
      %{if var.vpn_port == 53}
        docker pull kylemanna/openvpn:${var.vpn_image_tag}
        systemctl disable systemd-resolved.service --now
      %{else}
        :
      %{endif}
      EOT
    ]
    connection {
      host  = self.public_dns
      user  = "root"
      agent = var.connection_use_agent
    }
  }

  provisioner "remote-exec" {
    inline = [
      "docker volume create --name ${local.vpn_data}",
      "docker run -v ${local.vpn_data}:/etc/openvpn --rm kylemanna/openvpn:${var.vpn_image_tag} ovpn_genconfig -u udp://${self.public_ip}",
      "yes 'yes' | docker run -v ${local.vpn_data}:/etc/openvpn --rm -i kylemanna/openvpn:${var.vpn_image_tag} ovpn_initpki nopass",
      "docker run --restart always -v ${local.vpn_data}:/etc/openvpn -d -p ${var.vpn_port}:1194/udp --cap-add=NET_ADMIN kylemanna/openvpn:${var.vpn_image_tag}",
      "docker run -v ${local.vpn_data}:/etc/openvpn --rm -it kylemanna/openvpn:${var.vpn_image_tag} easyrsa build-client-full ${local.vpn_client_name} nopass",
      "docker run -v ${local.vpn_data}:/etc/openvpn --rm kylemanna/openvpn:${var.vpn_image_tag} ovpn_getclient ${local.vpn_client_name} > ~/${local.vpn_client_name}.ovpn",
      "sed -i 's/1194 udp/${var.vpn_port} udp/' ~/${local.vpn_client_name}.ovpn"
    ]
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh-keyscan -T 120 ${self.public_ip} >> ~/.ssh/known_hosts
      scp ${local.ssh_remote_user}@${self.public_ip}:~/${local.vpn_client_name}.ovpn ~/
    EOT
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
  value = "~/${local.vpn_client_name}.ovpn"
}

output "proxy_url" {
  value = "http://${var.proxy_user}:${var.proxy_password}@${aws_instance.vpn.public_ip}:${var.proxy_port}"
}

output "closing_message" {
  value = "Your VPN and proxy are ready!"
}
