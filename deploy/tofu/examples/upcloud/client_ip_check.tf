# Client-IP misconfiguration check (epic oauth-broker, story client-ip-misconfiguration-warnings,
# security gate 3 finding G3-2, follow-ups ap1 / ap3 / ap6).
#
# A `check` block only WARNS on every `tofu plan` / `tofu apply`; it never blocks a deploy (a shared
# client address is today's default behaviour and OAuth stays off until the operator enables it).
# It references variables only (no resource attributes, no data sources), so it is evaluated at plan
# time without provider data.
#
# A silent check proves nothing: a non-empty lb_real_ip_cidrs silences assert 1, but only the
# POSITIVE client-IP test (README, "Reverse-proxy routes, client-IP trust and access logs") shows
# that Nebu sees the real client address. That test stays a MANUAL gate before `oauth_enabled`.

check "client_ip_resolution" {
  # Assert 1: an HTTP-mode load balancer terminates the TCP connection, so nginx sees only the load
  # balancer as $remote_addr unless lb_real_ip_cidrs lets the nginx realip module resolve the client.
  assert {
    condition     = !(contains(["alb", "dynamic"], var.tls_mode) && length(var.lb_real_ip_cidrs) == 0)
    error_message = "tls_mode '${var.tls_mode}' with an empty lb_real_ip_cidrs: nginx sees only the load balancer, so every client shares ONE rate-limit bucket and per-source cap (safe against spoofing, NOT safe for availability: one anonymous source can lock every user out of login). Do NOT enable `oauth_enabled` until lb_real_ip_cidrs is set (after the negative test) AND the positive client-IP test passed (README, Reverse-proxy routes, client-IP trust and access logs)."
  }

  # Assert 2: the TCP-mode frontends (tls_mode none / acme) lose the client address without PROXY
  # protocol, which this template does not support (follow-up ap3).
  assert {
    condition     = contains(["alb", "dynamic"], var.tls_mode)
    error_message = "tls_mode '${var.tls_mode}' uses a TCP-mode UpCloud load balancer frontend: without PROXY protocol (not supported, follow-up ap3) the client address is lost and every client shares ONE rate-limit bucket and per-source cap (safe against spoofing, NOT safe for availability). Do NOT enable `oauth_enabled` in this topology."
  }
}
