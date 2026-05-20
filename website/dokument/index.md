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

## Who Uses Nebu?

### Marcus — IT Operations Lead

*"We needed a Slack replacement that stays inside our VPC. Nebu runs on our Kubernetes cluster,
connects to our Keycloak, and our compliance team hasn't had a single question about data residency
since we switched."*

**Marcus** represents operators who need a self-hostable, OIDC-integrated chat server that fits
inside an existing Kubernetes or Docker Compose deployment without additional middleware dependencies.

---

### Leila — Software Engineer

*"I like that it's just Matrix — I can use Element Web today and switch to another Matrix client
tomorrow without asking anyone's permission."*

**Leila** represents end users who want freedom of client choice and the reliability of an
open protocol, without sacrificing the UX quality of commercial chat tools.

---

### Mia — Compliance Officer

*"Apache 2.0, on-premise, with a GDPR erasure endpoint and an audit log — this is the first
chat server our legal team approved without amendments."*

**Mia** represents compliance officers who need verifiable data sovereignty, a clear license,
and a documented right-to-erasure implementation before they can approve a tool for production use.

---

### Kai — System Administrator

*"The Bootstrap Wizard walked me through OIDC setup in under 15 minutes.
The admin dashboard shows me what I need to know without cluttering the screen."*

**Kai** represents administrators who need straightforward initial setup and a day-to-day
admin UI that focuses on operational visibility without overwhelming detail.

---

## Get Started

Ready to deploy Nebu?

- [Getting Started Guide](getting-started/) — step-by-step operator setup
- [Architecture Documentation](architecture/) — arc42-based system design

---

## Source Code

The source code is available at [gitlab.opencode.de](https://gitlab.opencode.de/open-code/nebu-chat).
Apache 2.0 — contributions welcome.
