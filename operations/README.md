# Operations

Routine cluster operations for a running Kamiwaza platform. Each subfolder is a
self-contained procedure with verification steps.

**Tags:** #operations #day2 #maintenance

---

## Procedures

| Procedure | When to use |
| --- | --- |
| [`backup-restore/`](backup-restore/) | Back up and restore platform-owned PostgreSQL and etcd state. |

---

## Related

- [`../troubleshooting/`](../troubleshooting/) — diagnosis-first playbooks for failures.
- [`../operator/upgrades/`](../operator/upgrades/) — change platform intent and roll workloads through the operator.
- [`../security/`](../security/) — TLS trust, authority, edge, and auth scenarios.
