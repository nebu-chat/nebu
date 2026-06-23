import Config

config :logger, level: :debug

# F-2 (security review): admin session cookie defaults to secure:true (TLS-only) in
# prod. Local dev serves the admin UI over plain HTTP, so relax it here only.
config :nebu_http, admin_session_secure: false
