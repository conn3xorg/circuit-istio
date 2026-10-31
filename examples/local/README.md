# Local example

Builds a one-node k3s cluster with [circuit-k3s](https://github.com/conn3xorg/circuit-k3s) in a throwaway Rocky Linux 10 container, then installs Istio on it with a `demo` namespace labelled for sidecars. You need Conn3x and Podman, and about 4 GB of memory free for the container.

k3s runs containers of its own, so the host container runs privileged, and rootless Podman can't give it the cpuset cgroup k3s needs. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The apply takes a few minutes, and the second plan says `No changes.` To see the mesh working:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 sh -s < check.sh
```

`check.sh` starts a server and a client in `demo`, and another client outside the mesh. It checks that both `demo` pods got a sidecar, that the client reaches the server through Envoy, and that with mutual TLS required the outside client can't.

To try the ingress gateway, which needs Traefik off:

```sh
conn3x apply -var ingress_gateway=true -var 'k3s_server_config={disable=["traefik"]}'
```

Do that on a fresh container. It's one setting in the example, not a step you'd take on a cluster with traffic on it.

The container can't load kernel modules, so its host needs `br_netfilter` and `overlay` loaded. A Podman machine has both. On Linux, run `sudo modprobe -a br_netfilter overlay` first.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` stops the container, which removes it and its volume, then deletes the key and the state.
