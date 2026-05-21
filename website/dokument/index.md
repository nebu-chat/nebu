---
title: "Nebu — Self-hosted Matrix Chat"
---

# Nebu — Self-hosted Matrix Chat

**Self-hosted Matrix chat — your data, your rules.**

Nebu (short for Nebuchadnezzar, the ship of the free from *The Matrix*) is an enterprise-grade,
Matrix Client-Server API compatible chat server.
Apache 2.0 licensed. No federation. Horizontally scalable.
Designed to replace Slack/Teams with full data sovereignty.

---

## Why Nebu?

### Matrix-compatible

Nebu implements the Matrix Client-Server API — compatible with any Matrix client
(Element Web, FluffyChat, Cinny, and others). Your users keep their preferred clients.
Your team is not locked into a proprietary interface.

### Data sovereignty — your data, your rules

Nebu runs entirely on your infrastructure. No SaaS vendor, no external data routing,
no surprise privacy policy changes. You control the server, the database, and the keys.
Full GDPR compliance is built in, not bolted on.

### No Redis, no NATS, no Kafka

Most self-hosted chat servers drag in a fleet of infrastructure dependencies.
Nebu uses Elixir/OTP's built-in ETS for caching and pg Process Groups for pub/sub —
no Redis, no NATS, no Kafka. Fewer moving parts. Simpler operations. Lower cost.

### Apache 2.0 — truly open

Nebu is released under the Apache 2.0 license. Use it, fork it, embed it in your product.
No "open core" licensing, no paid enterprise tier for basic features.

---

## Tech Stack

Nebu is built on a proven combination of fast, reliable, and battle-tested technologies:

| Layer | Technology |
|---|---|
| API Gateway | **Go** 1.26+ — fast, stateless, horizontally scalable |
| Messaging Core | **Elixir**/OTP 1.19+ — actor model, crash-resilient GenServers |
| Database | PostgreSQL 16+ — append-only event log, no ORM magic |
| Clustering | libcluster + Horde — distributed GenServer registry |
| Auth | OIDC-only (Dex, Keycloak, or any OIDC provider) |
| Media | Go media gateway — S3-compatible, thumbnail generation |

No Redis. No NATS. No Kafka. No surprises.

---

## Get Started

Ready to deploy Nebu?

- [Getting Started Guide](getting-started/) — step-by-step operator setup
- [Architecture Documentation](architecture/) — arc42-based system design

---

## Source Code

The source code is available at [gitlab.opencode.de](https://gitlab.opencode.de/open-code/nebu-chat).
Apache 2.0 — contributions welcome.
