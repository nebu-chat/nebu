# Nebu — UpCloud Deployment Example

Deploys Nebu to UpCloud using VMs, Docker Compose, UpCloud Load Balancer, and Managed PostgreSQL.
See [ADR-014](../../docs/architecture/adr/ADR-014-deployment-strategy-iac.md) for the full architecture.

The structure mirrors the [StackIT example](../stackit/) — the same cloud-init bootstrap template
is shared between both providers.

## Services used

| UpCloud Service | Purpose | StackIT equivalent |
|---|---|---|
| `upcloud_server` | VM running Docker Compose | `stackit_server` |
| `upcloud_network` | Private network (LB ↔ VM) | `stackit_network` |
| `upcloud_firewall_rules` | Inbound port rules (attached to VM) | `stackit_security_group` |
| `upcloud_loadbalancer` | L4/L7 load balancer | `stackit_loadbalancer` / `stackit_application_load_balancer` |
| `upcloud_managed_database_postgresql` | Managed PostgreSQL 16 | `stackit_postgresflex_instance` |
| `upcloud_managed_object_storage` | S3-compatible media storage (optional) | `stackit_objectstorage_bucket` |
| `upcloud_dns_record` | DNS CNAME (optional, `dns_mode = "default"`) | `stackit_dns_zone` + `stackit_dns_record_set` |

**Not available on UpCloud:** Managed Loki log aggregation (`enable_logs` is not supported — logs stay on the VM journal or must be shipped externally).

## Quick Start

```bash
# 1. Configure variables
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Initialise OpenTofu
tofu init

# 3. Review the plan
tofu plan

# 4. Apply
tofu apply
```

## Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.6.0
- UpCloud sub-account with API access (Hub → User Management → Add sub-account → enable API)
- [upctl](https://github.com/UpCloudLtd/upcloud-cli) CLI (optional, for listing plans and zones)
- Container image (`nebu-server`) pushed to your registry at the correct tag

## DNS note

Unlike StackIT, UpCloud load balancers do not assign a static floating IP directly. Instead they
expose a stable `dns_name` (e.g. `lb-<uuid>.lb.upcloudlb.com`). After `tofu apply`:

```bash
tofu output dns_name
# → lb-xxxxxxxx.lb.upcloudlb.com
```

Register this as:
- A **CNAME** record at your domain (if your DNS provider supports CNAME flattening at the apex), or
- Resolve it to an IP (`dig +short $(tofu output -raw dns_name)`) and create an **A-record**.

When `dns_mode = "default"`, OpenTofu creates a CNAME record in UpCloud DNS automatically — the domain zone must be registered in UpCloud DNS Zones beforehand.
