# ── UpCloud Authentication ────────────────────────────────────────────────────
# Use exactly one of the two auth methods below.
# Token takes precedence when both are set.

variable "upcloud_token" {
  description = "UpCloud API token (ucat_…). Preferred auth method. Generate: UpCloud Hub → My Account → API Tokens → Create token. Omit when using upcloud_username + upcloud_password."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.upcloud_token == null || startswith(var.upcloud_token, "ucat_")
    error_message = "upcloud_token must start with 'ucat_' (UpCloud API token format)."
  }
}

variable "upcloud_username" {
  description = "UpCloud sub-account username for API access. Omit when using upcloud_token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "upcloud_password" {
  description = "UpCloud sub-account password for API access. Omit when using upcloud_token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key injected into the VM for operator access (ubuntu user)."
  type        = string
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, staging, prod). Used in resource names."
  type        = string
  default     = "dev"
}

variable "zone" {
  description = "UpCloud zone for the VM, load balancer, and managed database. Run 'upctl zone list' to see available zones. Examples: de-fra1, fi-hel2, nl-ams1, pl-waw1."
  type        = string
  default     = "de-fra1"
}

variable "network_cidr" {
  description = "IPv4 CIDR block for the Nebu private network."
  type        = string
  default     = "10.0.0.0/24"
}

variable "vm_plan" {
  description = "UpCloud server plan. Run 'upctl server plans' to list plans. 4xCPU-8GB is the minimum recommended for Nebu (BEAM scheduler benefits from multiple cores)."
  type        = string
  default     = "4xCPU-8GB"
}

variable "vm_template" {
  description = "UpCloud storage template name for the boot volume. Verify the current name: upctl storage list --type template | grep -i ubuntu"
  type        = string
  default     = "Ubuntu Server 24.04 LTS (Noble Numbat)"
}

# ── Container resource limits ─────────────────────────────────────────────────

variable "server_cpu_limit" {
  description = "CPU limit for the Elixir server container (Docker Compose deploy.resources.limits.cpus). Default suits a 4xCPU-8GB VM. BEAM scheduler uses multiple cores under load."
  type        = string
  default     = "1.50"
}

variable "server_memory_limit" {
  description = "Memory limit for the Elixir server container (Docker Compose deploy.resources.limits.memory). Default suits a 4xCPU-8GB VM. BEAM allocates aggressively — set this to avoid OOM kills."
  type        = string
  default     = "2g"
}

variable "dex_cpu_limit" {
  description = "CPU limit for the Dex container. Only relevant when oidc_mode = 'dex'."
  type        = string
  default     = "0.25"
}

variable "dex_memory_limit" {
  description = "Memory limit for the Dex container. Only relevant when oidc_mode = 'dex'."
  type        = string
  default     = "128m"
}

variable "element_cpu_limit" {
  description = "CPU limit for the Element Web container. Only relevant when enable_element_web = true."
  type        = string
  default     = "0.25"
}

variable "element_memory_limit" {
  description = "Memory limit for the Element Web container. Only relevant when enable_element_web = true."
  type        = string
  default     = "128m"
}

variable "clamav_cpu_limit" {
  description = "CPU limit for the ClamAV malware-scanner container (ADR-024). Only relevant when enable_media_gateway = true."
  type        = string
  default     = "0.50"
}

variable "clamav_memory_limit" {
  description = "Memory limit for the ClamAV malware-scanner container. clamd keeps the full virus signature database resident in memory (typically 1-1.5 GB) — set generously to avoid OOM kills during freshclam updates. Only relevant when enable_media_gateway = true."
  type        = string
  default     = "1.5g"
}

# ── Media object storage ──────────────────────────────────────────────────────

variable "enable_media_gateway" {
  description = "When true, creates an UpCloud Managed Object Storage service + bucket and configures the server container to serve /_matrix/media from it. S3 credentials are fully managed by OpenTofu — no manual portal step required."
  type        = bool
  default     = false
}

variable "s3_bucket" {
  description = "S3 bucket name for media storage. Used when enable_media_gateway = true. UpCloud bucket names are globally unique within a service."
  type        = string
  default     = "nebu-media"
}

variable "object_storage_region" {
  description = "UpCloud Managed Object Storage region. Separate from the compute zone. Run 'upctl object-storage regions' to list. Examples: europe-1, us-east-1."
  type        = string
  default     = "europe-1"
}

# ── Load Balancer ─────────────────────────────────────────────────────────────

variable "enable_firewall" {
  description = "When true, creates upcloud_firewall_rules on the VM. Set to false for UpCloud trial accounts — trial mode enforces a built-in firewall (TRIAL_FIREWALL) that rejects custom rule configurations."
  type        = bool
  default     = true
}

variable "lb_plan" {
  description = "UpCloud load balancer plan. 'development' is free (suitable for testing, no SLA). For production use 'production-small' or higher. Run 'upctl loadbalancer plans' to list."
  type        = string
  default     = "development"
}

# ── Managed PostgreSQL ────────────────────────────────────────────────────────

variable "db_plan" {
  description = "UpCloud managed database plan for PostgreSQL. Run 'upctl database plans --type postgresql' to list available plans. hobbyist-2 is the smallest paid plan; for production use 2x2xHDD or higher."
  type        = string
  default     = "hobbyist-2"
}

# ── TLS ───────────────────────────────────────────────────────────────────────

variable "tls_mode" {
  description = "TLS termination strategy. 'none': no TLS, server exposed on port 8008 via LB TCP passthrough. 'acme': nginx on VM + certbot Let's Encrypt (HTTP-01). 'dynamic': UpCloud LB terminates TLS with automatic Let's Encrypt certificate management (recommended — set acme_email). 'alb': UpCloud LB terminates TLS using a manually provided certificate (tls_certificate_pem/tls_private_key_pem) — use only for custom CAs or wildcard certs."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "acme", "alb", "dynamic"], var.tls_mode)
    error_message = "tls_mode must be 'none', 'acme', 'dynamic', or 'alb'."
  }
}

variable "acme_email" {
  description = "Email address for Let's Encrypt ACME account registration. Required when tls_mode = 'acme' or 'dynamic'."
  type        = string
  default     = ""
}

variable "acme_staging" {
  description = "When true, passes --test-cert to certbot (Let's Encrypt staging). Use for initial testing to avoid rate limits. Only relevant when tls_mode = 'acme'."
  type        = bool
  default     = false
}

variable "tls_certificate_pem" {
  description = "Path to PEM-encoded TLS certificate (fullchain). Required when tls_mode = 'alb'. Obtain externally (e.g. certbot DNS-01). Example: '/etc/letsencrypt/live/chat.example.com/fullchain.pem'"
  type        = string
  sensitive   = true
  default     = ""
}

variable "tls_private_key_pem" {
  description = "Path to PEM-encoded TLS private key. Required when tls_mode = 'alb'. Must match tls_certificate_pem. Example: '/etc/letsencrypt/live/chat.example.com/privkey.pem'"
  type        = string
  sensitive   = true
  default     = ""
}

# ── Bootstrap secrets ─────────────────────────────────────────────────────────

variable "internal_secret" {
  description = "Shared PSK used for server node registration (ADR-008). Injected into .secrets/internal_secret at first boot."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.internal_secret) >= 16
    error_message = "internal_secret must be at least 16 characters. Use 'openssl rand -hex 32' to generate."
  }
}

variable "pii_encryption_key" {
  description = "32-byte AES key for PII field encryption in the Elixir server (NEBU_PII_ENCRYPTION_KEY). Must be exactly 64 hex characters. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.pii_encryption_key) == 64 && can(regex("^[0-9a-f]+$", var.pii_encryption_key))
    error_message = "pii_encryption_key must be exactly 64 lowercase hex characters. Use 'openssl rand -hex 32' to generate."
  }
}

# ── OIDC ──────────────────────────────────────────────────────────────────────

variable "oidc_client_secret" {
  description = "Optional. When oidc_mode = 'dex': required — embedded into Dex staticClients config. When oidc_mode = 'external': omit to let Nebu read OIDC config from the database. Minimum 16 characters when set."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.oidc_client_secret == null || length(var.oidc_client_secret) >= 16
    error_message = "oidc_client_secret must be at least 16 characters when set."
  }

  validation {
    condition     = var.oidc_client_secret == null || (!strcontains(var.oidc_client_secret, "\"") && !strcontains(var.oidc_client_secret, "\\"))
    error_message = "oidc_client_secret must not contain double-quote or backslash characters (YAML interpolation constraint)."
  }
}

variable "oidc_client_id" {
  description = "Optional. When oidc_mode = 'dex': required — embedded into Dex staticClients config. When oidc_mode = 'external': omit to let Nebu read OIDC config from the database. Minimum 8 characters when set."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.oidc_client_id == null || length(var.oidc_client_id) >= 8
    error_message = "oidc_client_id must be at least 8 characters when set."
  }

  validation {
    condition     = var.oidc_client_id == null || (!strcontains(var.oidc_client_id, "\"") && !strcontains(var.oidc_client_id, "\\"))
    error_message = "oidc_client_id must not contain double-quote or backslash characters (YAML interpolation constraint)."
  }
}

variable "oidc_issuer" {
  description = "OIDC issuer URL. Required when oidc_mode = 'external' (e.g. 'https://auth.example.com/realms/nebu'). When oidc_mode = 'dex', this value is ignored — the issuer is automatically set to '<scheme>://<server_name>/dex'."
  type        = string
  default     = ""
}

variable "oidc_audience" {
  description = "Expected 'aud' claim in OIDC Bearer tokens. Leave empty to default to oidc_client_id. Set explicitly when your IdP issues access tokens with a separate audience (e.g. Keycloak with resource servers)."
  type        = string
  default     = ""
}

variable "oidc_mode" {
  description = "OIDC deployment profile. 'dex': deploy Dex as a sidecar (test/demo environments). 'external': no bundled IdP; operator must provide oidc_issuer (for production with a managed OIDC provider)."
  type        = string
  default     = "external"

  validation {
    condition     = contains(["dex", "external"], var.oidc_mode)
    error_message = "oidc_mode must be 'dex' or 'external'."
  }
}

variable "dex_allowed_cidr" {
  description = "CIDR block allowed to reach Dex on port 5556 (dex mode, tls_mode = 'none' only). Default 0.0.0.0/0 is permissive — restrict in shared environments."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrnetmask(var.dex_allowed_cidr))
    error_message = "dex_allowed_cidr must be a valid CIDR block (e.g. '10.0.0.0/8' or '203.0.113.1/32')."
  }
}

variable "dex_static_password_hash" {
  description = "bcrypt hash for the Dex static user (operator@example.com). Required when oidc_mode = 'dex'. Generate: htpasswd -bnBC 12 '' 'yourpassword' | tr -d ':' | sed 's/$2y/$2a/'"
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.dex_static_password_hash == null || startswith(var.dex_static_password_hash, "$2a$") || startswith(var.dex_static_password_hash, "$2b$") || startswith(var.dex_static_password_hash, "$2y$")
    error_message = "dex_static_password_hash must be a bcrypt hash starting with '$2a$', '$2b$', or '$2y$'."
  }
}

variable "dex_user1_password_hash" {
  description = "bcrypt hash for alice@example.com (demo user). Optional when oidc_mode = 'dex'."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.dex_user1_password_hash == null || startswith(var.dex_user1_password_hash, "$2a$") || startswith(var.dex_user1_password_hash, "$2b$") || startswith(var.dex_user1_password_hash, "$2y$")
    error_message = "dex_user1_password_hash must be a bcrypt hash."
  }
}

variable "dex_user2_password_hash" {
  description = "bcrypt hash for bob@example.com (demo user). Optional when oidc_mode = 'dex'."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.dex_user2_password_hash == null || startswith(var.dex_user2_password_hash, "$2a$") || startswith(var.dex_user2_password_hash, "$2b$") || startswith(var.dex_user2_password_hash, "$2y$")
    error_message = "dex_user2_password_hash must be a bcrypt hash."
  }
}

variable "dex_compliance_password_hash" {
  description = "bcrypt hash for compliance@example.com. Optional when oidc_mode = 'dex'."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.dex_compliance_password_hash == null || startswith(var.dex_compliance_password_hash, "$2a$") || startswith(var.dex_compliance_password_hash, "$2b$") || startswith(var.dex_compliance_password_hash, "$2y$")
    error_message = "dex_compliance_password_hash must be a bcrypt hash."
  }
}

# ── Domain & Registry ─────────────────────────────────────────────────────────

variable "server_name" {
  description = "Public server name / domain for the Nebu instance (e.g. 'chat.example.com'). Used as NEBU_SERVER_NAME inside containers."
  type        = string
}

variable "nebu_version" {
  description = "Nebu container image tag to deploy (e.g. '1.0.0'). Never use 'latest' in production."
  type        = string
  default     = ""

  validation {
    condition     = var.nebu_version != "latest"
    error_message = "Use a specific version tag. Set nebu_version to a semver tag like '1.0.0'."
  }
}

variable "image_registry" {
  description = "Container image registry prefix (e.g. 'registry.gitlab.com/myorg/open-chat'). Server is pulled as <image_registry>/nebu-server:<nebu_version>."
  type        = string
}

variable "enable_element_web" {
  description = "When true, deploys Element Web as a Docker service. Requires tls_mode = 'acme' or 'alb' — without nginx, Element (port 7070) and server (port 8008) are different origins causing CORS failures."
  type        = bool
  default     = false
}

# ── DNS ───────────────────────────────────────────────────────────────────────

variable "dns_mode" {
  description = "Kept for StackIT compatibility. The UpCloud provider has no DNS record resource — DNS is always managed externally. After tofu apply, point your domain at the 'dns_name' output."
  type        = string
  default     = "external"

  validation {
    condition     = var.dns_mode == "external"
    error_message = "UpCloud provider does not support DNS record management. dns_mode must be 'external'."
  }
}
