# ── DNS ───────────────────────────────────────────────────────────────────────
# The UpCloud Terraform provider does not include a DNS record resource.
# DNS must be managed externally (your registrar, Cloudflare, Route53, etc.).
#
# After tofu apply, point your domain at the load balancer:
#   1. Read the LB DNS name:  tofu output dns_name
#   2. Create a CNAME record: <server_name> → <dns_name output>
#      (if your DNS provider supports CNAME flattening at the apex domain)
#   3. Or resolve the LB DNS name to an IP and create an A-record.
#
# dns_mode variable is kept for compatibility with the StackIT example but has
# no effect here — all DNS registration is always external for UpCloud.
