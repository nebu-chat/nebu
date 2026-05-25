# ── Network ───────────────────────────────────────────────────────────────────

resource "stackit_network" "nebu" {
  project_id       = var.stackit_project_id
  name             = "nebu-${var.environment}"
  ipv4_prefix      = var.network_cidr
  ipv4_nameservers = ["8.8.8.8", "8.8.4.4"]
  routed           = true
}

