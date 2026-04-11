---
name: Adapter Contribution
about: Propose a new storage backend adapter
title: "[ADAPTER] "
labels: adapter, contribution
---

**Target backend**
Which storage system? (e.g., PostgreSQL/pgvector, Neo4j, Elasticsearch, Snowflake)

**Capabilities**
Which adapter behaviour callbacks will your adapter implement?
- [ ] resolve/3
- [ ] discover/3
- [ ] assert/3
- [ ] normalize/2
- [ ] health_check/0
- [ ] capabilities/0

**Query paradigms supported**
- [ ] Graph traversal
- [ ] Vector similarity search
- [ ] Full-text search
- [ ] Relational queries

**Connection model**
Network client (TCP/HTTP) or embedded?

**Estimated scope**
Approximate lines of code and timeline?
