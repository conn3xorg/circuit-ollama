terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.0" }
    random       = { source = "hashicorp/random", version = "~> 3.0" }
    tls          = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Addresses allowed to reach SSH, such as [\"203.0.113.7/32\"]. Nothing else can reach the droplet."

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "Give at least one address or network in CIDR form, such as \"203.0.113.7/32\"."
  }
}

variable "name" {
  type        = string
  default     = "aibox"
  description = "Name of the droplet, its SSH key and its cloud firewall."
}

variable "region" {
  type    = string
  default = "lon1"
}

variable "size" {
  type        = string
  default     = "s-2vcpu-4gb"
  description = "Droplet size. Ollama on the CPU wants at least 4 GB of memory."
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "ssh_public_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

# The droplet's SSH host key, made here and installed by cloud-init, so
# Conn3x can check it on the very first connection.
resource "tls_private_key" "host" {
  algorithm = "ED25519"
}

resource "random_password" "qdrant" {
  length  = 32
  special = false
}

resource "digitalocean_ssh_key" "admin" {
  name       = var.name
  public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
}

resource "digitalocean_droplet" "box" {
  name     = var.name
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.size
  tags     = var.tags
  ssh_keys = [digitalocean_ssh_key.admin.id]

  user_data = "#cloud-config\n${yamlencode({
    ssh_deletekeys = true
    ssh_keys = {
      ed25519_private = tls_private_key.host.private_key_openssh
      ed25519_public  = tls_private_key.host.public_key_openssh
    }
  })}"
}

# Only SSH comes in, and only from admin_cidrs. Outbound stays open for
# packages, the Ollama and Qdrant releases, and models.
resource "digitalocean_firewall" "box" {
  name        = var.name
  droplet_ids = [digitalocean_droplet.box.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.admin_cidrs
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

locals {
  # The droplet doesn't exist at plan time, so os stands in for the facts
  # the circuits would otherwise read from it.
  hosts = {
    box = {
      address  = digitalocean_droplet.box.ipv4_address
      host_key = tls_private_key.host.public_key_openssh
      os       = "ubuntu"
    }
  }
}

# The circuits run side by side. Conn3x waits out apt's lock when two want
# it at once. depends_on between them would hold back reading the host's
# facts whenever an earlier circuit has a change, and that makes Ollama
# and Qdrant plan to download their releases again.
module "baseline" {
  source = "github.com/conn3xorg/circuit-baseline?ref=v0.1.0"

  hosts                = local.hosts
  ssh_private_key_file = var.ssh_private_key_file
}

module "hardening" {
  source = "github.com/conn3xorg/circuit-hardening?ref=v0.1.0"

  hosts                = local.hosts
  ssh_private_key_file = var.ssh_private_key_file

  # The tunnel below is SSH local forwarding, which hardening turns off.
  # "local" allows -L and still refuses -R.
  sshd_settings = { AllowTcpForwarding = "local" }

  # ufw sets log_martians to 0 each time it starts, from
  # /etc/ufw/sysctl.conf, so the two would undo each other on every apply.
  sysctl = {
    "net.ipv4.conf.all.log_martians"     = null
    "net.ipv4.conf.default.log_martians" = null
  }
}

module "firewall" {
  source = "github.com/conn3xorg/circuit-firewall?ref=v0.2.0"

  hosts                = local.hosts
  ssh_private_key_file = var.ssh_private_key_file
}

module "ollama" {
  source = "github.com/conn3xorg/circuit-ollama?ref=v0.1.1"

  hosts                = local.hosts
  ssh_private_key_file = var.ssh_private_key_file

  models = ["nomic-embed-text", "qwen2.5:0.5b"]
}

module "qdrant" {
  source = "github.com/conn3xorg/circuit-qdrant?ref=v0.1.0"

  hosts                = local.hosts
  ssh_private_key_file = var.ssh_private_key_file

  api_key = random_password.qdrant.result
}

output "ip" {
  value = digitalocean_droplet.box.ipv4_address
}

output "tunnel" {
  value = "ssh -L 11434:127.0.0.1:11434 -L 6333:127.0.0.1:6333 root@${digitalocean_droplet.box.ipv4_address}"
}

output "qdrant_api_key" {
  value     = random_password.qdrant.result
  sensitive = true
}
