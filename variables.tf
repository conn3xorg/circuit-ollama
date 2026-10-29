variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "ollama_version" {
  type        = string
  default     = "0.40.13"
  description = "Ollama release to install, without the leading v."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-rc[0-9]+)?$", var.ollama_version))
    error_message = "ollama_version must be a release number without the leading v, such as \"0.40.13\"."
  }
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the release tarball for each architecture, from the release's sha256sum.txt. Change these with ollama_version."
  default = {
    amd64 = "c9490e0f520be21271d969e6703f012268b1d39f8b70dd58854e5bfef7a75bb6"
    arm64 = "913d9a28da6da86d551ce4ca531457767bb14d511cbc1d5ca93e9b3b8b9a8666"
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1:11434"
  description = "Address and port the Ollama API listens on. The API has no authentication: \"0.0.0.0:11434\" lets anyone who can reach the host use it."

  validation {
    condition     = can(regex("^(\\[[0-9a-fA-F:]+\\]|[0-9A-Za-z.-]+):[0-9]{1,5}$", var.listen_address)) && tonumber(regex("[0-9]+$", var.listen_address)) >= 1 && tonumber(regex("[0-9]+$", var.listen_address)) <= 65535
    error_message = "listen_address must be an address and a port, such as \"127.0.0.1:11434\", \"0.0.0.0:11434\" or \"[::]:11434\"."
  }
}

variable "models" {
  type        = list(string)
  default     = []
  description = "Models to pull from the Ollama library, such as [\"llama3.2:3b\", \"qwen2.5:0.5b\"]. A model without a tag gets latest."

  validation {
    condition     = alltrue([for m in var.models : can(regex("^[a-zA-Z0-9][a-zA-Z0-9._/:-]*$", m))])
    error_message = "Each model is a name with an optional tag, such as \"qwen2.5:0.5b\", using letters, digits, ., _, -, / and :."
  }
}

variable "environment" {
  type        = map(string)
  default     = {}
  description = "Extra environment for the Ollama server, such as { OLLAMA_KEEP_ALIVE = \"30m\" }. Set the listen address with listen_address."

  validation {
    condition     = alltrue([for k, v in var.environment : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) && !strcontains(v, "\n")])
    error_message = "Environment names may use letters, digits and _, not starting with a digit, and values can't hold a newline."
  }

  validation {
    condition     = !contains(keys(var.environment), "OLLAMA_HOST")
    error_message = "Set OLLAMA_HOST with listen_address, not environment."
  }
}
