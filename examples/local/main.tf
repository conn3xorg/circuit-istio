variable "port" {
  type    = number
  default = 2222
}

variable "token" {
  type      = string
  ephemeral = true
  default   = "example-token-change-me"
}

variable "ingress_gateway" {
  type    = bool
  default = false
}

variable "k3s_server_config" {
  type    = any
  default = {}
}

module "k3s" {
  source = "github.com/conn3xorg/circuit-k3s?ref=v0.1.3"

  servers              = { server1 = "127.0.0.1" }
  token                = var.token
  server_config        = var.k3s_server_config
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"
}

module "istio" {
  source     = "../.."
  depends_on = [module.k3s]

  server            = "127.0.0.1"
  ingress_gateway   = var.ingress_gateway
  inject_namespaces = ["demo"]

  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"
}
