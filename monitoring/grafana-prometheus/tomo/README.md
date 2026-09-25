# Tomo monitoring

`connect-tomo.sh` connects every installed Tomo extension to this monitoring stack for two dashboards:

- `../dashboards/kam-10-tomo-product.json`, **Tomo product insight**: how do members use Tomo, where do they struggle, and which features earn their place?
- `../dashboards/kam-09-tomo.json`, **Tomo operations**: is Tomo answering members, and how are its models and tools doing?

## What Tomo records, and where

| Question                                                       | Where Tomo keeps the answer                                                                           | Read through           |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------- |
| Who sent what kind of input, to which model, agent, and effort | `conversation_input`, one row per message, steer, or stop                                             | `turns()`, `members()` |
| Which features members used                                    | `audit_event`, one row per member action                                                              | `member_events()`      |
| How members rated answers                                      | `audit_event`, `member.chat.feedback` rows                                                            | `answer_votes()`       |
| Which models answered, how fast, with how many tokens          | `llm_audit_event`, one row per model call                                                             | `model_calls()`        |
| Which connector tools ran, and how they ended                  | `capability_invocation_receipt`                                                                       | `connector_calls()`    |
| First-party tool calls by tool and outcome                     | `tool_run_total{tool, capability, outcome}`                                                           | Prometheus             |
| Model-call failures by provider route and reason, live         | `kaizen_llm_request_total{route, purpose, outcome, failure}`                                          | Prometheus             |
| Member API, search, scheduled tasks, sandboxes, dependencies   | `kaizen_member_request_*`, `kaizen_retrieval_*`, `kaizen_task_*`, `sandbox_*`, `kaizen_dependency_up` | Prometheus             |

Tomo's metrics deliberately carry the provider route, not the model or the member: a label per model or member would multiply every series. Those are recorded only in the database, so product and per-model views come from there. The metrics are the live, alertable view; the database is the durable, per-member and per-model view.

The API serves `/metrics` on port 8000. The background and document workers serve it on port 9100. Each process counts only what it handled, so every panel sums across them.

## What the reporting functions expose

`reporting.sql` creates a schema, `tomo_reporting`, in each install's database, with one function per source above. Each takes a time range and returns rows without content: no message text, prompt, name, or email, and no audit payload except a vote's direction.

A member appears only as `member_key`, a keyed hash of their identity. The key is random per install and lives in `tomo_reporting.member_key_secret`, which the reader cannot read, so a key cannot be reversed by hashing known identities. A member keeps the same key across runs of the script, which is what lets kam-10 count active members, repeat use, and retention.

The function bodies are plain SQL text, so PostgreSQL records no dependency on Tomo's tables. A Tomo migration never fails because of them; a column Tomo renames makes only the panel that reads it report an error until `reporting.sql` is updated.

## Connect

Run the script after installing, reinstalling, or removing Tomo. It connects every install at once:

```bash
monitoring/grafana-prometheus/tomo/connect-tomo.sh
```

It finds each Tomo extension in namespace `kamiwaza` by its `extensions.kamiwaza.ai/name=kaizen` label. Pass `--extension <name>` to act on one install only, and `--namespace` or `--monitoring-namespace` for other namespaces.

For each install, the script applies, in order:

1. **Scrape.** A PodMonitor, `tomo-<install>`, for the API and both workers, and a NetworkPolicy, `<install>-allow-prometheus`, that admits only the Prometheus pods to ports 8000 and 9100. Port 8000 also serves Tomo's member API; that API still authenticates every request. Every install's targets share `job="tomo"` and carry `extension="<install>"`.
2. **Database access.** A PostgreSQL role, `grafana_reader`, in that install's database, created through the database pod's own superuser. The role holds no privilege on any Tomo table: it can only call the functions in `reporting.sql`, which its search path finds by name. It is read-only by default, holds at most 6 connections, and each statement is cancelled after 15 seconds.
3. **Datasource.** A Service, `<install>-reporting-db`, in front of that database; a NetworkPolicy, `<install>-allow-grafana-db`, that admits only the Grafana pods to it; and a Secret, `tomo-datasource-<install>`, that Grafana's datasource sidecar provisions as **Tomo · &lt;install&gt;**. kam-09 and kam-10 select that datasource when you select the install.

Every object the script creates carries `app.kubernetes.io/name: tomo-connection` and `monitoring.kamiwaza.ai/extension: <install>`.

Every run sets a new random password on each role and rewrites its datasource, so repeating it is safe. The password exists only in that Secret.

## Installs that are starting, failing, or gone

Each install is handled on its own, so one that cannot be connected never stops the others.

- **Starting or failing.** Scrape comes first because it needs nothing from the database, so a failing install still reports what its running processes can. If its database is not running, or its API has not created its tables, the script says so for that install and moves on. It exits with status 3 when any install is left waiting; run it again later.
- **Gone.** An install that no longer exists is disconnected: its PodMonitor, NetworkPolicies, and Service are deleted. Its database, and the role in it, went with the install.
- **Its datasource.** Deleting a provisioning file does not remove the datasource from Grafana, and Grafana refuses to delete a provisioned datasource through its API. So the script replaces a disconnected install's datasource Secret with one that tells Grafana to delete the datasource, labelled `app.kubernetes.io/name: tomo-connection-retired`. The next run deletes that Secret.

kam-09 shows the same states. The **Tomo installs** table lists every install with its readiness, the operator's reason, pods ready, and how many of its metrics targets Prometheus reaches. For the selected install, **Failing components** lists every pod that is not ready and why. A tile whose source is down or not yet created reads **Unknown** rather than a healthy zero.

## When to run it again

- **After installing, reinstalling, or removing Tomo.** A new install is a new extension name and a new, empty database.
- **After updating `reporting.sql`**, for example when a Tomo upgrade renames a column it reads. Until then, only the panel that reads that column reports an error.

An upgrade of the same install keeps the extension name, so the Service, NetworkPolicies, PodMonitor, and role keep working.

## Disconnect

```bash
monitoring/grafana-prometheus/tomo/connect-tomo.sh --remove                      # every connected install
monitoring/grafana-prometheus/tomo/connect-tomo.sh --remove --extension <install> # one install
```

This deletes each install's PodMonitor, NetworkPolicies, and Service, retires its datasource, and, when its database is still running, drops the `tomo_reporting` schema and the role.

## Boundaries

- Grafana reads each Tomo database directly. That couples kam-09 and kam-10 to Tomo's schema, and crosses each install's isolation for one role and one port. The functions, the read-only role, the connection limit, and the statement timeout keep that crossing narrow; remove it with `--remove`.
- The connection to the database is not encrypted, the same as Tomo's own services inside the cluster.
- Anyone who can edit dashboards in Grafana can call the functions with their own SQL. They return no content and no identity, but they do reveal usage volume, timing, and one member's activity pattern under a pseudonymous key.
