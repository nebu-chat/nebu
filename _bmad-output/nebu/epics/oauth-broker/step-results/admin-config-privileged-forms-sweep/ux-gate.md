# UX gate admin-config-privileged-forms-sweep (nebu-ux-reviewer, 2026-10-14)
1 blocking: V1 flash messages without role on the two mapping pages (the re-authentication notice is the only instruction after the IdP round trip) -> role=status / role=alert added.
Advisories applied: A1 lock-out warning emphasised (alert-warning), A2 shorter, A3 repo path replaced by "deployment guide". Not applied: A4 flash colour of the re-auth notice (existing pattern),
A5 aria-invalid / aria-describedby on the mapping inputs (pre-existing inconsistency), A6 back-link anchor to the form.
