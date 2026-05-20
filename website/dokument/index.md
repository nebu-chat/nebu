# Nebu

Nebu (short for Nebuchadnezzar, the ship of the free from *The Matrix*) is an enterprise-grade,
Matrix Client-Server API compatible chat server.

Apache 2.0 licensed. No federation. Horizontally scalable.
Designed to replace Slack/Teams with full data sovereignty.

## Features

- Matrix Client-Server API compatible
- OIDC-only authentication (no SAML/LDAP directly)
- No Redis, no NATS — ETS and PostgreSQL only
- Horizontally scalable via Elixir/OTP + Horde
- Full data sovereignty — self-hostable

## Source Code

The source code is available at [gitlab.opencode.de](https://gitlab.opencode.de/open-code/nebu-chat).
