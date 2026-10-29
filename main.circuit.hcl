# Facts give each host's architecture, which picks the release tarball.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }
}

locals {
  goarch  = { x86_64 = "amd64", aarch64 = "arm64" }
  arch    = { for name, f in data.conn3x_host.facts : name => local.goarch[f.arch] }
  tarball = { for name, a in local.arch : name => "/opt/ollama/ollama-linux-${a}-${var.ollama_version}.tar.zst" }

  # The tarball holds bin/ollama and lib/ollama. Ollama finds its runners in
  # lib/ollama next to its own bin directory, so each version keeps both
  # under one directory of its own.
  home   = "/opt/ollama/${var.ollama_version}"
  binary = "${local.home}/bin/ollama"

  listen_host = regex("^(.*):([0-9]+)$", var.listen_address)[0]
  listen_port = tonumber(regex("^(.*):([0-9]+)$", var.listen_address)[1])

  # The ollama command talks to the server at OLLAMA_HOST. A server on every
  # address still answers on loopback.
  client_host = contains(["0.0.0.0", "[::]"], local.listen_host) ? "127.0.0.1:${local.listen_port}" : var.listen_address

  # ollama list shows a model without a tag as name:latest.
  model_names = { for m in var.models : m => can(regex(":[^/]*$", m)) ? m : "${m}:latest" }

  # Quoted for systemd: a backslash and a double quote are escaped, and % is
  # doubled so systemd doesn't read it as a specifier.
  environment = merge(var.environment, { OLLAMA_HOST = var.listen_address })
  dropin = join("", concat(
    ["# Written by Conn3x. Changes here are overwritten on the next apply.\n[Service]\n"],
    [for k in sort(keys(local.environment)) : "Environment=\"${k}=${replace(replace(replace(local.environment[k], "\\", "\\\\"), "\"", "\\\""), "%", "%%")}\"\n"],
  ))
}

circuit "ollama" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Minimal images can lack any of these. The release is a zstd tarball,
  # which tar unpacks through zstd.
  step "tools" {
    for_each = toset(["curl", "tar", "zstd"])
    package {
      name = item.value
    }
  }

  # The same account the official install script makes. Models live under
  # its home, in /usr/share/ollama/.ollama/models.
  step "group" {
    group {
      name   = "ollama"
      system = true
    }
  }

  step "user" {
    user {
      name   = "ollama"
      group  = "ollama"
      system = true
      home   = "/usr/share/ollama"
      shell  = "/bin/false"
    }
  }

  step "download" {
    download {
      url    = "https://github.com/ollama/ollama/releases/download/v${var.ollama_version}/ollama-linux-${local.arch[each.key]}.tar.zst"
      sha256 = var.checksums[local.arch[each.key]]
      dest   = local.tarball[each.key]
    }
  }

  step "unpack" {
    archive {
      src     = local.tarball[each.key]
      dest    = local.home
      creates = local.binary
    }
  }

  step "link" {
    link {
      path   = "/usr/local/bin/ollama"
      target = local.binary
    }
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/ollama.service"
      content = <<-EOT
        [Unit]
        Description=Ollama
        After=network-online.target
        Wants=network-online.target

        [Service]
        ExecStart=${local.binary} serve
        User=ollama
        Group=ollama
        Restart=always
        RestartSec=3
        NoNewPrivileges=true

        [Install]
        WantedBy=multi-user.target
      EOT
    }
    notify = [handler.restart]
  }

  step "environment" {
    file {
      path    = "/etc/systemd/system/ollama.service.d/conn3x.conf"
      content = local.dropin
    }
    notify = [handler.restart]
  }

  # The restart handler doesn't reload systemd, and the service step below
  # only does when it planned a change, so a changed unit or drop-in would
  # otherwise restart with the old settings.
  step "reload" {
    command {
      command = "systemctl daemon-reload"
      triggers = {
        unit        = conn3x_file.ollama__unit[each.key].revision
        environment = conn3x_file.ollama__environment[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "ollama"
      state   = "started"
      enabled = true
    }
  }

  handler "restart" {
    service {
      name = "ollama"
    }
  }
}

# A circuit of its own, so models are pulled after the restart handler has
# put a new listen address or version into effect.
circuit "models" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "api" {
    depends_on = [conn3x_service_action.ollama__restart]
    wait_for {
      port    = local.listen_port
      timeout = "1m"
    }
  }

  step "pull" {
    for_each = local.model_names
    command {
      command = "OLLAMA_HOST='${local.client_host}' ollama pull '${item.key}'"
      unless  = "OLLAMA_HOST='${local.client_host}' ollama list | awk 'NR > 1 { print $1 }' | grep -qxF '${item.value}'"
    }
  }
}
