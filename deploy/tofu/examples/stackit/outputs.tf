output "postgres_instance_id" {
  description = "STACKIT PostgresFlex instance ID."
  value       = stackit_postgresflex_instance.nebu.instance_id
}

output "postgres_host" {
  description = "PostgresFlex private host (only reachable from within the Stackit private network)."
  value       = stackit_postgresflex_user.nebu.host
}

output "vm_id" {
  description = "STACKIT server ID of the Nebu VM."
  value       = stackit_server.nebu.server_id
}

output "load_balancer_id" {
  description = "Internal resource ID of the active load balancer (ALB when tls_mode = 'alb', NLB otherwise)."
  value       = var.tls_mode == "alb" ? stackit_application_load_balancer.nebu[0].id : stackit_loadbalancer.nebu[0].id
}

output "load_balancer_private_address" {
  description = "Transient private IP address of the active load balancer. The public entry point is dns_name."
  value       = var.tls_mode == "alb" ? stackit_application_load_balancer.nebu[0].private_address : stackit_loadbalancer.nebu[0].private_address
}

output "dns_name" {
  description = "Floating IP address to register in your external DNS server when dns_mode = 'external'. Create an A-record pointing your domain to this IP address. When dns_mode = 'default', Stackit DNS is managing this automatically."
  value       = stackit_public_ip.nebu-alb.ip
}

output "tls_info" {
  description = "TLS status and certificate management approach."
  value = (
    var.tls_mode == "alb" ? "alb-managed (TLS termination at Stackit ALB, cert via stackit_alb_certificate)" :
    var.tls_mode == "acme" ? "certbot-managed (HTTP-01, auto-renews via systemd timer — check: sudo certbot certificates)" :
    "disabled"
  )
}

output "nebu_migrate_password" {
  description = "Auto-generated password for the nebu_migrate PostgresFlex user (DDL migration runner). Needed to update NEBU_DB_URL_MIGRATE on an existing VM after tofu apply."
  value       = stackit_postgresflex_user.nebu_migrate.password
  sensitive   = true
}

output "logs_ingest_url" {
  description = "Stackit Logs Loki push endpoint. After apply: Portal → Logs → instance → Access tokens → Create (Read+Write role). Then SSH into the VM and run: /opt/nebu/configure-fluent-bit.sh <token>"
  value       = var.enable_logs ? stackit_logs_instance.nebu[0].ingest_url : "disabled"
}

output "element_url" {
  description = "Element Web client URL. Available when enable_element_web = true and tls_mode != 'none'."
  value = (
    !var.enable_element_web ? "disabled" :
    var.tls_mode != "none" ? "https://${var.server_name}/" :
    "http://${var.server_name}:7070/"
  )
}

output "media_bucket" {
  description = "StackIT Object Storage bucket name for media files. Created by this module when enable_media_gateway = true."
  value       = var.enable_media_gateway ? var.s3_bucket : "disabled"
}
