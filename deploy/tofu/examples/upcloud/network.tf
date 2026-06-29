# ── SDN Router ────────────────────────────────────────────────────────────────
# Required for managed services (PostgreSQL) to be reachable from the private
# network. Without a router, the DB's SDN attachment has no route to the VM.

resource "upcloud_router" "nebu" {
  name = "nebu-${var.environment}-router"
}

# ── Private Network ────────────────────────────────────────────────────────────
# Used for LB → VM and VM → managed DB (PostgreSQL) communication.
# The router enables routing between the private network and managed services.

resource "upcloud_network" "nebu" {
  name   = "nebu-${var.environment}"
  zone   = var.zone
  router = upcloud_router.nebu.id

  ip_network {
    address            = var.network_cidr
    dhcp               = true
    dhcp_default_route = false
    family             = "IPv4"
  }
}
