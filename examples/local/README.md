# Local example

Applies circuit-ollama to a throwaway Rocky Linux 10 container with systemd, pulls `smollm2:135m`, a 270 MB model, and sets `OLLAMA_KEEP_ALIVE`. You need Conn3x and Podman, and about 5 GB of free disk in Podman's storage: the Ollama release alone is 1.5 GB.

```sh
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To ask the model something:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 ollama run smollm2:135m "Say hello."
```

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
