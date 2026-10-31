# circuit-istio

A Conn3x circuit that installs [Istio](https://istio.io) on a k3s cluster with `istioctl`, at a version you pin, with the tarball's SHA-256 checked. Istio recommends `istioctl` for most installs, because it validates the configuration and checks the result. It's for the cluster you've built with [circuit-k3s](https://github.com/conn3xorg/circuit-k3s), and it takes you to sidecars on the namespaces you name.

Two things tend to catch people on k3s, and this circuit handles both. Istio supports a set range of Kubernetes versions, so it checks yours before touching anything. And k3s's Traefik already holds ports 80 and 443, which is where Istio's ingress gateway wants to be.

## Usage

```hcl
module "k3s" {
  source = "github.com/conn3xorg/circuit-k3s?ref=v0.1.4"

  servers              = { cp1 = "203.0.113.10" }
  token                = var.k3s_token
  ssh_private_key_file = "~/.ssh/id_ed25519"
}

module "istio" {
  source     = "github.com/conn3xorg/circuit-istio?ref=v0.1.1"
  depends_on = [module.k3s]

  server               = "203.0.113.10"
  inject_namespaces    = ["shop"]
  ssh_private_key_file = "~/.ssh/id_ed25519"
}

variable "k3s_token" {
  type      = string
  ephemeral = true
}
```

Run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.` Pods you start in `shop` from then on get a sidecar. Pods already running there get one when they next restart.

Without an ingress gateway you get Istio's `minimal` profile, just `istiod`, and Traefik carries on handling traffic into the cluster.

To try it on a throwaway container first, see [examples/local](examples/local).

### Traefik and the ingress gateway

Traffic into the mesh needs Istio's ingress gateway, and on k3s that wants the same ports Traefik has. Left alone, the gateway installs and looks healthy while its address stays `<pending>` for good, with `didn't have free ports for the requested pod ports` buried in an event in `kube-system`.

So setting `ingress_gateway = true` with Traefik enabled stops the apply with a message. Turn Traefik off on circuit-k3s, which is also what Istio's k3d guide does:

```hcl
module "k3s" {
  # ...
  server_config = { disable = ["traefik"] }
}

module "istio" {
  # ...
  ingress_gateway = true
}
```

Anything that was reached through Traefik needs an Istio `Gateway` and `VirtualService` after that, or its traffic stops. The circuit doesn't write those for you.

### Other Istio settings

`operator_spec` adds to the `spec` of the IstioOperator file, and each key replaces the same key from this circuit:

```hcl
operator_spec = {
  meshConfig = { accessLogFile = "/dev/stdout" }
}
```

It reaches state, so nothing secret goes there. Only the default settings have been run through this circuit, apart from `ingress_gateway`.

## What it does

On the server you name, in order:

1. Checks that the k3s installed there is on `k3s_minors`, and stops with a message if it isn't. The check runs on every plan, so a later k3s upgrade past Istio's range shows up too.
2. Waits for every CRD to be established. If one stays stuck, the apply fails and points to [Troubleshooting](https://github.com/conn3xorg/circuit-k3s#troubleshooting) in circuit-k3s. It never deletes a CRD.
3. Stops if `ingress_gateway` is on and Traefik is enabled.
4. Downloads `istioctl`, checks its SHA-256, unpacks it under `/opt/istio/VERSION` and links `/usr/local/bin/istioctl` to it.
5. Writes `/var/lib/conn3x-istio/operator.yaml` and runs `istioctl install` with it, which waits for Istio to be ready.
6. Creates each namespace in `inject_namespaces` if it's missing, and labels it `istio-injection=enabled`.

Each plan compares a hash of the operator file and the image `istiod` runs with the hash from the last apply. So you'll see a planned change after someone uninstalls Istio or changes its version by hand. Other edits to Istio's objects aren't noticed. While the cluster is down, a plan shows the install as changed, and a plan right after a reboot can do this too, until the API is back.

### What it doesn't do

- It doesn't install k3s. Use circuit-k3s, or any k3s whose binary is at `k3s` in the `PATH` with its kubeconfig at `/etc/rancher/k3s/k3s.yaml`.
- It doesn't turn on mutual TLS for you. Sidecars use it when both ends have one, and a `PeerAuthentication` set to `STRICT` makes it required, as [check.sh](examples/local/check.sh) does for its own namespace.
- It doesn't restart your workloads, so after an upgrade your sidecars stay on the old version until you do: `kubectl rollout restart`.
- It doesn't open firewall ports or configure ambient mode, and it doesn't uninstall. `istioctl uninstall --purge` removes Istio.

### Upgrading

Set `istio_version`, `checksums` and `k3s_minors` together, with the versions from [Istio's supported releases page](https://istio.io/latest/docs/releases/supported-releases/). Take each checksum from the `.sha256` file beside the `istioctl` tarball on the release. Conn3x runs `istioctl install` at the new version, in place. Read the release's upgrade notes before moving to a new minor version.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `server` | any | Required | One k3s server to run `istioctl` on: an address, or a host object with an `address` and optional `host_key`, `user`, `port`, `private_key_file` and `jump_hosts`. |
| `istio_version` | string | `"1.31.3"` | Istio release, without a `v`. |
| `checksums` | map(string) | The 1.31.3 checksums | SHA-256 of the `istioctl` tarball, for `amd64` and `arm64`. |
| `k3s_minors` | list(string) | `["1.32", "1.33", "1.34", "1.35", "1.36", "1.37"]` | Kubernetes minor versions the server's k3s may run. |
| `ingress_gateway` | bool | `false` | Install Istio's ingress gateway, using its `default` profile rather than `minimal`. Needs Traefik disabled. |
| `inject_namespaces` | list(string) | `[]` | Namespaces to create if missing and label for sidecar injection. |
| `operator_spec` | any | `{}` | More fields for the IstioOperator `spec`. Reaches state. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |

## Outputs

| Name | Description |
| --- | --- |
| `istio_version` | Istio release installed. |

## Requirements

Requires Conn3x v0.6.10 or later, circuit-k3s v0.1.4 or later if that's what built your cluster, a k3s server on a Kubernetes version Istio supports, and outbound HTTPS to GitHub and to the registry Istio's images come from. `istiod` asks the scheduler for 500m of CPU and 2 GiB of memory by default, and each sidecar for 100m and 128 MiB.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each in a container on amd64, checks that the plan after it has no changes, and runs [check.sh](examples/local/check.sh): both pods in the mesh get a sidecar, the client reaches the server with Envoy's header on the answer, and with mutual TLS required a pod outside the mesh can't reach it. The same four containers also passed by hand on arm64, and a k3s setup with Traefik enabled stopped `ingress_gateway = true` with its message on Ubuntu 24.04.

The rest was run by hand on 2 vCPU, 4 GB droplets with one node each. On Rocky Linux 10 with SELinux enforcing: the same checks, an upgrade from 1.31.2 to 1.31.3 with the pods restarted afterwards, then a reboot with no changes in the plan and the checks passing again. On Ubuntu 24.04: the same checks and a reboot, with Traefik off and `ingress_gateway = true`, and on a second droplet a `Gateway` and `VirtualService` answering 200 from outside on port 80 through the gateway.

v0.1.0 deleted k3s's Helm CRDs when they weren't established after about three minutes. On a cluster that was only slow, that would have deleted every HelmChart in it, so upgrade from v0.1.0. v0.1.1 only waits. CI runs it with circuit-k3s v0.1.4; the droplet runs above were on v0.1.0.

Not run: more than one node, arm64 on a real host, ambient mode, an upgrade between minor versions, k3s versions other than v1.37.1 (the circuit-k3s default).

## License

MPL-2.0. See [LICENSE](LICENSE). Istio is Apache-2.0.
