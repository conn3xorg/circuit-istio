variable "server" {
  type        = any
  description = "One k3s server to run istioctl on: an address, or a host object with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "istio_version" {
  type        = string
  default     = "1.31.3"
  description = "Istio release, without a v. Change it with checksums and k3s_minors."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.istio_version))
    error_message = "istio_version is a release number such as \"1.31.3\"."
  }
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the istioctl tarball for each architecture, from the .sha256 file beside it on the Istio release."
  default = {
    amd64 = "382c3004ce2e9c5ed3064b092ae0da7f6bbe30c766a1be282f45725add004860"
    arm64 = "7476801623dbb900073cb1dba6a23b6a15c564b7e92b208aed36829315fefff1"
  }
}

variable "k3s_minors" {
  type        = list(string)
  default     = ["1.32", "1.33", "1.34", "1.35", "1.36", "1.37"]
  description = "Kubernetes minor versions the server's k3s may run, from Istio's supported releases page. Anything else fails the apply before Istio is touched."
}

variable "ingress_gateway" {
  type        = bool
  default     = false
  description = "Install Istio's ingress gateway too, which is its default profile rather than minimal. It wants ports 80 and 443, so Traefik must be disabled on circuit-k3s first."
}

variable "inject_namespaces" {
  type        = list(string)
  default     = []
  description = "Namespaces to create if they're missing and label for sidecar injection. Pods already running there get a sidecar when they're next restarted."

  validation {
    condition     = alltrue([for n in var.inject_namespaces : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", n))])
    error_message = "A namespace is lowercase letters, digits and dashes."
  }
}

variable "operator_spec" {
  type        = any
  default     = {}
  description = "More fields for the spec of the IstioOperator file, such as { meshConfig = { accessLogFile = \"/dev/stdout\" } }. Keys here replace the same keys from this circuit, profile included. They reach state, so nothing secret goes here."
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
