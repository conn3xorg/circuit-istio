# Facts give the server's architecture, which picks the istioctl build.
data "conn3x_host" "facts" {
  for_each = { server = var.server }

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
  arch     = { x86_64 = "amd64", aarch64 = "arm64" }[data.conn3x_host.facts["server"].arch]
  dir      = "/var/lib/conn3x-istio"
  home     = "/opt/istio/${var.istio_version}"
  tarball  = "/opt/istio/istioctl-${var.istio_version}.tar.gz"
  operator = "${local.dir}/operator.yaml"

  # Reads the binary rather than the API, so a plan doesn't depend on the
  # cluster being up.
  k3s_minor = "k3s --version | sed -n 's/^k3s version v\\([0-9]*\\.[0-9]*\\).*/\\1/p'"
  k3s_fits  = "case ' ${join(" ", var.k3s_minors)} ' in *\" $(${local.k3s_minor}) \"*) ;; *) false;; esac"

  # k3s keeps this while Traefik is enabled. It's there before Traefik's
  # service is, so the check doesn't race k3s installing it.
  traefik_off = "[ ! -e /var/lib/rancher/k3s/server/manifests/traefik.yaml ]"

  wait_api = "for _ in $(seq 60); do k3s kubectl get --raw=/readyz >/dev/null 2>&1 && break; sleep 5; done"
  crds_up  = "for _ in $(seq 36); do k3s kubectl wait --for=condition=Established crd/helmcharts.helm.cattle.io crd/helmchartconfigs.helm.cattle.io --timeout=5s >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1"

  # The operator file and the image istiod really runs, so a plan notices an
  # uninstall or a version changed by hand.
  fingerprint = "{ cat ${local.operator} && k3s kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}'; } 2>/dev/null | sha256sum"
}

circuit "istio" {
  hosts = { server = var.server }

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Each Istio release supports a set range of Kubernetes versions, and
  # istioctl only warns about the rest.
  step "k3s_version" {
    command {
      command = "${local.k3s_fits} || { echo \"k3s $(${local.k3s_minor}) is not on k3s_minors (${join(", ", var.k3s_minors)}), the versions Istio ${var.istio_version} supports. Set k3s_version and checksums on circuit-k3s to a supported release.\" >&2; exit 1; }"
      unless  = local.k3s_fits
    }
  }

  # k3s can exit just after creating these CRDs, which leaves them never
  # established. It then exits a minute into every later start, taking the API
  # away from whatever is installing, and restarting doesn't help. Nothing can
  # be stored in a CRD that isn't established, so deleting them loses nothing,
  # and k3s creates them again.
  step "k3s_settled" {
    command {
      command = "${local.wait_api}; ( ${local.crds_up} ) || { for _ in $(seq 24); do k3s kubectl delete crd helmcharts.helm.cattle.io helmchartconfigs.helm.cattle.io --ignore-not-found --timeout=20s >/dev/null 2>&1 && break; sleep 5; done; ${local.wait_api}; ${local.crds_up}; }"
    }
  }

  # k3s's service load balancer gives each port to one service per node, and
  # Traefik has 80 and 443. The gateway would install and look healthy, with
  # its external address pending for good. k3s writes every manifest as it
  # starts and only then removes the disabled ones, so give that a minute.
  step "traefik_clash" {
    for_each = toset(var.ingress_gateway ? ["gateway"] : [])
    command {
      command = "for _ in $(seq 12); do ${local.traefik_off} && exit 0; sleep 5; done; echo 'ingress_gateway needs ports 80 and 443, which k3s gives to Traefik. Add server_config = { disable = [\"traefik\"] } to circuit-k3s, or leave ingress_gateway off.' >&2; exit 1"
      unless  = local.traefik_off
    }
  }

  step "tools" {
    for_each = toset(["curl", "tar", "gzip"])
    package {
      name = item.value
    }
  }

  step "download" {
    download {
      url    = "https://github.com/istio/istio/releases/download/${var.istio_version}/istioctl-${var.istio_version}-linux-${local.arch}.tar.gz"
      sha256 = var.checksums[local.arch]
      dest   = local.tarball
    }
  }

  step "unpack" {
    archive {
      src     = local.tarball
      dest    = local.home
      creates = "${local.home}/istioctl"
    }
  }

  step "link" {
    link {
      path   = "/usr/local/bin/istioctl"
      target = "${local.home}/istioctl"
    }
  }

  step "dir" {
    directory {
      path = local.dir
      mode = "0700"
    }
  }

  step "operator" {
    file {
      path = local.operator
      mode = "0600"
      content = yamlencode({
        apiVersion = "install.istio.io/v1alpha1"
        kind       = "IstioOperator"
        spec       = merge({ profile = var.ingress_gateway ? "default" : "minimal" }, var.operator_spec)
      })
    }
  }

  # An unless guard is checked at plan time, before the operator step has
  # run, so the trigger makes the apply check it again.
  step "install" {
    command {
      command  = "${local.wait_api}; /usr/local/bin/istioctl install -y --kubeconfig /etc/rancher/k3s/k3s.yaml -f ${local.operator} --readiness-timeout 15m && ${local.fingerprint} > ${local.dir}/applied"
      unless   = "[ \"$(${local.fingerprint})\" = \"$(cat ${local.dir}/applied)\" ]"
      triggers = { operator = conn3x_file.istio__operator[each.key].revision }
    }
  }

  step "namespaces" {
    for_each = toset(var.inject_namespaces)
    command {
      command = "k3s kubectl create namespace ${item.value} --dry-run=client -o yaml | k3s kubectl apply -f - && k3s kubectl label namespace ${item.value} istio-injection=enabled --overwrite"
      unless  = "[ \"$(k3s kubectl get namespace ${item.value} -o jsonpath='{.metadata.labels.istio-injection}')\" = enabled ]"
    }
  }
}
