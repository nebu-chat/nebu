output "db_id" {
  description = "UpCloud Managed PostgreSQL service ID."
  value       = upcloud_managed_database_postgresql.nebu.id
}

output "db_host" {
  description = "Managed PostgreSQL private service host (only reachable from within the UpCloud private network)."
  value       = upcloud_managed_database_postgresql.nebu.service_host
}

output "vm_id" {
  description = "UpCloud server UUID of the Nebu VM."
  value       = upcloud_server.nebu.id
}

output "vm_public_ip" {
  description = "Public IP address of the Nebu VM. Use this for SSH access."
  value       = [for ni in upcloud_server.nebu.network_interface : ni.ip_address if ni.type == "public"][0]
}

output "load_balancer_id" {
  description = "UpCloud load balancer UUID."
  value       = upcloud_loadbalancer.nebu.id
}

output "load_balancer_dns" {
  description = "DNS name of the UpCloud load balancer public network (e.g. lb-<uuid>-pub-1.lb.upcloudlb.com). Use as CNAME target or resolve to an IP for an A-record."
  value       = [for n in upcloud_loadbalancer.nebu.networks : n.dns_name if n.name == "public"][0]
}

output "dns_name" {
  description = "LB DNS name to register in your external DNS provider. Create a CNAME pointing your domain here (if your DNS provider supports CNAME flattening at apex), or resolve it to an IP address and create an A-record."
  value       = [for n in upcloud_loadbalancer.nebu.networks : n.dns_name if n.name == "public"][0]
}

output "tls_info" {
  description = "TLS status and certificate management approach."
  value = (
    var.tls_mode == "dynamic" ? "dynamic (TLS at UpCloud LB, auto Let's Encrypt via upcloud_loadbalancer_dynamic_certificate_bundle — renews automatically)" :
    var.tls_mode == "alb" ? "alb-manual (TLS at UpCloud LB, cert via upcloud_loadbalancer_manual_certificate_bundle — operator manages renewal)" :
    var.tls_mode == "acme" ? "acme (certbot HTTP-01 on VM, auto-renews via systemd timer — check: sudo certbot certificates)" :
    "disabled"
  )
}

output "nebu_migrate_password" {
  description = "Auto-generated password for the nebu_migrate PostgreSQL user (DDL migration runner). Needed to update NEBU_DB_URL_MIGRATE on an existing VM after tofu apply."
  value       = upcloud_managed_database_user.nebu_migrate.password
  sensitive   = true
}

output "media_bucket" {
  description = "UpCloud Managed Object Storage bucket name for media files. Created when enable_media_gateway = true."
  value       = var.enable_media_gateway ? var.s3_bucket : "disabled"
}

output "media_s3_endpoint" {
  description = "S3-compatible endpoint URL for the UpCloud Managed Object Storage service. Use as NEBU_MINIO_ENDPOINT when configuring external S3 clients."
  value       = var.enable_media_gateway ? local.s3_endpoint : "disabled"
}

output "media_access_key_id" {
  description = "S3-compatible endpoint URL for the UpCloud Managed Object Storage service. Use as NEBU_MINIO_ENDPOINT when configuring external S3 clients."
  value       = var.enable_media_gateway ? upcloud_managed_object_storage_user_access_key.nebu_media[0].access_key_id : "disabled"
  sensitive   = true
}

output "media_secret_access_key" {
  description = "S3-compatible endpoint URL for the UpCloud Managed Object Storage service. Use as NEBU_MINIO_ENDPOINT when configuring external S3 clients."
  value       = var.enable_media_gateway ? upcloud_managed_object_storage_user_access_key.nebu_media[0].secret_access_key : "disabled"
  sensitive   = true
}

output "element_url" {
  description = "Element Web client URL. Available when enable_element_web = true and tls_mode != 'none'."
  value = (
    !var.enable_element_web ? "disabled" :
    var.tls_mode != "none" ? "https://${var.server_name}/" :
    "http://${var.server_name}:7070/"
  )
}
