output "api_urls" {
  description = "Each host's Ollama API URL, by host name. On a loopback listen_address, it works from the host itself only."
  value       = { for name, h in var.hosts : name => "http://${contains(["0.0.0.0", "[::]"], local.listen_host) ? try(h.address, h) : local.listen_host}:${local.listen_port}" }
}
