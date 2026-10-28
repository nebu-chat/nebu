# Client-IP misconfiguration check (epic oauth-broker, story client-ip-misconfiguration-warnings,
# security gate 3 finding G3-2, follow-ups ap1 / ap6 / ap7).
#
# A `check` block only WARNS on every `tofu plan` / `tofu apply`; it never blocks a deploy (a shared
# client address is today's default behaviour and OAuth stays off until the operator enables it).
# It references variables only (no resource attributes, no data sources), so it is evaluated at plan
# time without provider data.
#
# Only the HTTP-mode ALB case is checked. Whether the Stackit NLB used by `acme` / `none` preserves
# the client source address is UNVERIFIED (follow-up ap7), so nothing is asserted there (no guessing).
#
# A silent check proves nothing: a non-empty lb_real_ip_cidrs silences it, but only the POSITIVE
# client-IP test (README, "Reverse-proxy routes, client-IP trust and access logs") shows that Nebu
# sees the real client address. That test stays a MANUAL gate before `oauth_enabled`.

check "client_ip_resolution" {
  assert {
    condition     = !(var.tls_mode == "alb" && length(var.lb_real_ip_cidrs) == 0)
    error_message = "tls_mode 'alb' with an empty lb_real_ip_cidrs: nginx sees only the Stackit ALB, so every client shares ONE rate-limit bucket and per-source cap (safe against spoofing, NOT safe for availability: one anonymous source can lock every user out of login). Do NOT enable `oauth_enabled` until lb_real_ip_cidrs is set (after the negative test) AND the positive client-IP test passed (README, Reverse-proxy routes, client-IP trust and access logs)."
  }
}
