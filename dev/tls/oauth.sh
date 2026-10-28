#!/bin/sh
# Switches Nebu's OAuth authorization server on or off in the local dev stack (dev/tls).
# This writes server_config directly (the same two keys the Admin UI switch writes: /admin/config, section
# "OAuth 2.0 authorization server"; the Admin UI route needs a fresh admin sign-in, this script does not).
#   dev/tls/oauth.sh on | off
set -eu
cd "$(dirname "$0")/../.."
ORIGIN="https://nebu.localtest.me:7443"
case "${1:-}" in
  on)  ENABLED=true ;;
  off) ENABLED=false ;;
  *) echo "usage: $0 on|off" >&2; exit 2 ;;
esac

docker compose exec -T postgres psql -U nebu_migrate -d nebu -c "
INSERT INTO server_config (key, value, set_at) VALUES
  ('oauth_enabled', '$ENABLED', extract(epoch from now())::bigint),
  ('oauth_issuer_url', '$ORIGIN', extract(epoch from now())::bigint)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at"

# the switch is cached per node for up to NEBU_OAUTH_CONFIG_CACHE_MS (default 2 s)
sleep 3
printf 'auth_metadata: '
curl -sk -o /dev/null -w '%{http_code}\n' "$ORIGIN/_matrix/client/v1/auth_metadata"
printf 'newest advertised Matrix version: '
curl -sk "$ORIGIN/_matrix/client/versions" | grep -o 'v1\.[0-9]*' | tail -1
