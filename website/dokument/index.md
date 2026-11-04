---
title: "Nebu - Self-hosted Matrix Chat"
---

# Nebu - Self-hosted Matrix Chat

**Self-hosted Matrix chat - your data, your rules.**

Nebu (short for Nebuchadnezzar, the ship of the free from *The Matrix*) is an enterprise-grade,
Matrix Client-Server API compatible chat server.
Apache 2.0 licensed. No federation. Horizontally scalable.
Designed to replace Slack/Teams with full data sovereignty.

---

## Why Nebu?

### Matrix-compatible

Nebu implements the Matrix Client-Server API - compatible with any Matrix client
(Element Web, FluffyChat, Cinny, and others). Your users keep their preferred clients.
Your team is not locked into a proprietary interface.

### Modern sign-in: your identity provider, Nebu as OAuth 2.0 broker

Users sign in with the identity provider your organisation already runs (Keycloak, Azure AD,
Google Workspace, Dex). Nebu keeps no passwords of its own.

Optionally, Nebu acts as an **OAuth 2.0 authorization server** (Matrix v1.15) in front of that
provider. Current clients such as Element Web and FluffyChat register themselves, an administrator
approves each new client in the Admin UI, and only Nebu issues and revokes the Matrix access and
refresh tokens - your identity provider never has to know every Matrix client. The feature is
**off by default**; an administrator switches it on in the Admin UI, and while it is off the
existing OIDC login works unchanged.

### End-to-end encryption infrastructure - with archivable rooms

Nebu supports what Matrix clients need for end-to-end encryption: server-side key backup
(so "chat recovery" works), to-device messages, a device key directory and cross-signing with
server-verified Ed25519 signatures for device verification. The server stores only public keys
and opaque blobs, decrypts nothing and logs no key material.

**Rooms stay unencrypted on purpose.** Nebu refuses `m.room.encryption` and `m.room.encrypted`,
so the archive, the audit log and the legal export remain complete - the compliance model is
the product. To-device messages are limited to a fixed list of event types and are rate and size
limited. A small, documented residual remains (to-device messages are an opaque,
non-archived user-to-user channel) and is recorded in the architecture documentation
(ADR-011, risk register). End-to-end encrypted Element Call calls are not supported.

### Data sovereignty - your data, your rules

Nebu runs entirely on your infrastructure. No SaaS vendor, no external data routing,
no surprise privacy policy changes. You control the server, the database, and the keys.
Full GDPR compliance is built in, not bolted on.

### No Redis, no NATS, no Kafka

Most self-hosted chat servers drag in a fleet of infrastructure dependencies.
Nebu uses Elixir/OTP's built-in ETS for caching and pg Process Groups for pub/sub -
no Redis, no NATS, no Kafka. Fewer moving parts. Simpler operations. Lower cost.

### Apache 2.0 - truly open

Nebu is released under the Apache 2.0 license. Use it, fork it, embed it in your product.
No "open core" licensing, no paid enterprise tier for basic features.

---

## Tech Stack

Nebu is built on a proven combination of fast, reliable, and battle-tested technologies:

| Layer | Technology |
|---|---|
| Application | **Elixir**/OTP 1.19+ - single OTP app, actor model, crash-resilient GenServers |
| HTTP / Web | Bandit + Plug (Matrix API & media), Phoenix LiveView (Admin UI) |
| Database | PostgreSQL 16+ - append-only event log, no ORM magic |
| Clustering | libcluster + Horde - distributed GenServer registry |
| Auth | OIDC (Dex, Keycloak, or any OIDC provider); optional OAuth 2.0 authorization server (broker model) |
| Media | Built-in media gateway (`Nebu.Media`) - S3-compatible, thumbnail generation |

No Redis. No NATS. No Kafka. No surprises.

---

## Get Started

Ready to deploy Nebu?

- [Getting Started Guide](getting-started/) - step-by-step operator setup
- [Architecture Documentation](architecture/) - arc42-based system design

---

## Source Code

The source code is available at [gitlab.opencode.de](https://gitlab.opencode.de/nebu/nebu-server).
Apache 2.0 - contributions welcome.
