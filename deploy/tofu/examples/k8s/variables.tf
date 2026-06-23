variable "kubeconfig_path" {
  description = "Path to the kubeconfig file used by the kubernetes and helm providers."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubernetes context to use from the kubeconfig file. Leave empty to use the active context."
  type        = string
  default     = ""
}

# go-removal-cleanup: gateway_image_tag was removed. server_image_tag is the only
# required image tag — server serves the public Matrix + media + admin.
variable "server_image_tag" {
  description = "Container image tag for the Nebu server component (e.g. '0.3.0' or 'dev')."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace to deploy Nebu into."
  type        = string
  default     = "nebu"
}

variable "chart_path" {
  description = "Path to the Nebu Helm chart directory (relative to the k8s example root)."
  type        = string
  default     = "../../../helm/nebu"
}

variable "ingress_enabled" {
  description = "Enable the Ingress resource for external access."
  type        = bool
  default     = false
}

