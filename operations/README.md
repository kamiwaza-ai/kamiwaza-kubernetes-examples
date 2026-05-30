# Operations

Routine cluster operations for a running Kamiwaza platform. Each subfolder is a
self-contained procedure with verification steps.

**Tags:** #operations #day2 #maintenance

---

## Procedures

| Procedure | When to use |
| --- | --- |
| [`apply-overrides-reinstall/`](apply-overrides-reinstall/) | Apply values/overrides changes, reinstall, or uninstall the platform. |
| [`cluster-scaling-maxpods/`](cluster-scaling-maxpods/) | Raise the Kind pod ceiling to 1000 for large fan-out. |
| [`credential-rotation/`](credential-rotation/) | Rotate GHCR / registry credentials without redeploying. |

---

## Related

- [`../troubleshooting/`](../troubleshooting/) — diagnosis-first playbooks for failures.
- [`../security/`](../security/) — TLS trust, CA, ingress, and auth scenarios.
