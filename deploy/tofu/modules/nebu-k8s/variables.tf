variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "nebu"
}

variable "chart_path" {
  description = "Path to the Nebu Helm chart directory."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace to deploy Nebu into."
  type        = string
  default     = "nebu"
}

# go-removal-cleanup: gateway_image_tag was removed. server_image_tag is the only
# required image tag — server serves the public Matrix + media + admin.
variable "server_image_tag" {
  description = "Container image tag for the Nebu server component."
  type        = string
}

variable "ingress_enabled" {
  description = "Enable the Ingress resource for external access."
  type        = bool
  default     = false
}

variable "helm_timeout" {
  description = "Timeout in seconds for the helm_release to become ready. Increase for slow image pulls or large clusters."
  type        = number
  default     = 300
}

variable "values_files" {
  description = "List of values file paths passed to the Helm release. All entries must be non-empty absolute paths (use path.module-relative expressions in the calling module)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for f in var.values_files : length(trimspace(f)) > 0])
    error_message = "All entries in values_files must be non-empty strings."
  }
}
