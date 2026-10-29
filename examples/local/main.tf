variable "port" {
  type    = number
  default = 2222
}

variable "keep_alive" {
  type    = string
  default = "10m"
}

module "ollama" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # A 135-million-parameter model: about 270 MB, and quick on a CPU.
  models = ["smollm2:135m"]

  environment = {
    OLLAMA_KEEP_ALIVE = var.keep_alive
  }
}

output "api_urls" {
  value = module.ollama.api_urls
}
