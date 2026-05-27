terraform {
  required_version = ">= 1.6.0"

  required_providers {
    stackit = {
      source  = "stackitcloud/stackit"
      version = "~> 0.95"
    }
  }

  # Backend: Stackit Object Storage (S3-compatible). Configure before use.
  # Uncomment and fill in values — do NOT commit credentials.
  #
  # backend "s3" {
  #   bucket                      = "my-tofu-state"
  #   key                         = "nebu/stackit/terraform.tfstate"
  #   endpoint                    = "https://object.storage.eu01.onstackit.cloud"
  #   region                      = "eu01"
  #   skip_credentials_validation = true
  #   skip_region_validation      = true
  #   skip_metadata_api_check     = true
  # }
}

provider "stackit" {
  default_region           = var.region
  service_account_key_path = var.stackit_key_path
  # beta feature: enable_beta_resources = true required for PROTOCOL_HTTPS ALB listener
  enable_beta_resources = true
}

# ── StackIT Object Storage (optional) ────────────────────────────────────────
# Creates the S3 bucket for media storage when enable_media_gateway = true.
# Note: StackIT Object Store credentials (s3_access_key / s3_secret_key) are
# NOT the same as the service account key (stackit_key_path). They are created
# separately in the STACKIT portal under Object Storage > Credentials.
resource "stackit_objectstorage_bucket" "nebu_media" {
  count      = var.enable_media_gateway ? 1 : 0
  project_id = var.stackit_project_id
  name       = var.s3_bucket
}
