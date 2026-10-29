# circuit-ollama

A Conn3x circuit that runs [Ollama](https://ollama.com) on your own hosts, so you can ask a local model something without sending it to anyone's API. You pick the release and the models; the circuit installs Ollama from its official release tarball, runs it under systemd as its own `ollama` user, and pulls the models you list. The same settings land on Ubuntu, Debian, Fedora and Rocky Linux.

It runs models on the CPU. That's plenty for small models and embeddings, and slow for big ones. GPU drivers aren't covered: see [What it doesn't do](#what-it-doesnt-do).

## Usage

```hcl
module "ollama" {
  source = "github.com/conn3xorg/circuit-ollama?ref=v0.1.0"

  hosts                = { llm1 = "203.0.113.20" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  models = ["qwen2.5:0.5b", "nomic-embed-text"]

  environment = {
    OLLAMA_KEEP_ALIVE = "30m"
  }
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

On the host, try it with `ollama run qwen2.5:0.5b`, or through the API:

```sh
curl http://127.0.0.1:11434/api/generate -d '{"model": "qwen2.5:0.5b", "prompt": "Why is the sky blue?", "stream": false}'
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Reaching it from other machines

By default Ollama listens on `127.0.0.1:11434`, so only the host itself can use it. Setting `listen_address = "0.0.0.0:11434"` opens it to every network the host is on.

**The Ollama API has no authentication.** Anyone who can reach that port can run your models, pull new ones onto your disk and delete the ones you have. On a droplet with a public address, that means anyone on the internet: with `0.0.0.0` set, `curl http://<droplet>:11434/api/tags` from a laptop listed our models. Keep it on a private address, a VPN such as [circuit-tailscale](https://github.com/conn3xorg/circuit-tailscale), or behind a firewall rule from [circuit-firewall](https://github.com/conn3xorg/circuit-firewall), or put a reverse proxy with authentication in front, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy).

## What it does

On each host, in order:

1. Installs `curl`, `tar` and `zstd`. The release ships as a zstd tarball.
2. Creates the `ollama` system user and group, with its home in `/usr/share/ollama`, as the official install script does. Models are kept in `/usr/share/ollama/.ollama/models`.
3. Downloads `ollama-linux-amd64.tar.zst` or `ollama-linux-arm64.tar.zst` for `ollama_version` from Ollama's GitHub releases into `/opt/ollama`, keeping it only if its SHA-256 matches `checksums`. Unpacks it into `/opt/ollama/<version>` and links `/usr/local/bin/ollama` to the binary.
4. Writes `/etc/systemd/system/ollama.service`, which runs `ollama serve` as the `ollama` user, and a drop-in, `/etc/systemd/system/ollama.service.d/conn3x.conf`, that sets `OLLAMA_HOST` from `listen_address` and everything in `environment`.
5. Starts Ollama now and at boot. When the version, unit or drop-in changes, it reloads systemd and restarts Ollama.
6. Waits for the API, then pulls each model in `models` that `ollama list` doesn't already show. A model you already have isn't pulled again, and a new tag on the library doesn't trigger a pull: Conn3x checks the name, not the contents.

Before the circuit runs, the `conn3x_host` data source reads each host's architecture over SSH, which picks the tarball.

### Disk space

The Linux release bundles the CUDA libraries, so it's big: the 0.40.13 tarball is about 1.5 GB, and 2.2 GB unpacked. The tarball stays in `/opt/ollama` so Conn3x can check it on each plan. Models come on top: `qwen2.5:0.5b` is about 400 MB, an 8B model about 5 GB.

### Upgrading

Change `ollama_version` and `checksums` together. The checksums are in the release's `sha256sum.txt`, such as <https://github.com/ollama/ollama/releases/download/v0.40.13/sha256sum.txt>. The new version unpacks next to the old one, and Ollama restarts on it. Delete the old tarball and directory from `/opt/ollama` yourself once you're happy; models aren't touched.

### What it doesn't do

- No GPU. It doesn't install NVIDIA or AMD drivers, CUDA or ROCm, and doesn't add the `ollama` user to the `render` or `video` groups. The release's bundled CUDA libraries are unpacked anyway, but running on a GPU wasn't tested.
- It doesn't delete models. Taking one out of `models` leaves it on disk; `ollama rm <model>` removes it.
- It doesn't create a directory you point `OLLAMA_MODELS` at. Create it first, owned by `ollama`.
- No authentication, TLS or web UI. See [Reaching it from other machines](#reaching-it-from-other-machines).
- Deleting the module leaves Ollama installed and running.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.20"`, or a host object such as `{ address = "203.0.113.20", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `ollama_version` | string | `"0.40.13"` | Ollama release to install, without the leading `v`. |
| `checksums` | map(string) | the 0.40.13 tarballs | SHA-256 of the release tarball, by architecture: `amd64` and `arm64`. Change these with `ollama_version`. |
| `listen_address` | string | `"127.0.0.1:11434"` | Address and port the API listens on, such as `"0.0.0.0:11434"` or `"[::]:11434"`. The API has no authentication. |
| `models` | list(string) | `[]` | Models to pull from the [Ollama library](https://ollama.com/library), such as `["llama3.2:3b", "nomic-embed-text"]`. A model without a tag gets `latest`. |
| `environment` | map(string) | `{}` | Extra environment for the server, such as `{ OLLAMA_KEEP_ALIVE = "30m", OLLAMA_NUM_PARALLEL = "2" }`. Set `OLLAMA_HOST` with `listen_address` instead. |

## Outputs

| Name | Description |
| --- | --- |
| `api_urls` | Each host's API URL, by host name. With `listen_address` on `0.0.0.0` or `[::]`, it uses the host's address, such as `http://203.0.113.20:11434`. On loopback it's `http://127.0.0.1:11434`, which works from the host itself only. |

## Requirements

Requires Conn3x v0.6.6 or later, systemd on each host, an x86_64 or aarch64 CPU, and outbound HTTPS to github.com and to ollama.com for models. Give the host enough memory for the models you pull: a 0.5B model runs in well under 1 GB, an 8B one wants about 8 GB.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes and that the extra environment reached the service, and asks `smollm2:135m` for a reply through `/api/generate`. The same checks passed by hand on arm64 containers of all four. On Rocky Linux 10, changing `listen_address` and adding a model in one apply restarted Ollama on the new address before pulling.

It was also applied by hand to an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, both with 2 vCPUs and 4 GB of memory. On both, `smollm2:135m` answered through the API, and after a reboot Ollama came back, answered again, and the plan had no changes. The Rocky Linux audit log had no SELinux denials. With `listen_address = "0.0.0.0:11434"`, both served the API to the internet, as warned above.

## License

MPL-2.0. See [LICENSE](LICENSE). Ollama itself is MIT.
