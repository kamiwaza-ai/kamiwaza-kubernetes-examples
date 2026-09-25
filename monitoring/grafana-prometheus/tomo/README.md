# Tomo monitoring

`connect-tomo.sh` connects an installed Tomo extension to this monitoring stack, so that `../dashboards/kam-09-tomo.json` can answer: **is Tomo answering members, and how are its models and tools doing?**

## What Tomo publishes, and where

| Question                                                     | Where Tomo keeps the answer                                                                           | kam-09 reads it from             |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- | -------------------------------- |
| Which models answered, how fast, with how many tokens        | `llm_audit_event`, one row per model call, with the model ID                                          | The **Tomo database** datasource |
| Which model and agent served each turn, and how it ended     | `conversation_input`, one row per member or task turn                                                 | The **Tomo database** datasource |
| Which connector tools ran, and how they ended                | `capability_invocation_receipt`                                                                       | The **Tomo database** datasource |
| Member votes on answers                                      | `chat_answer_feedback`                                                                                | The **Tomo database** datasource |
| First-party tool calls by tool and outcome                   | `tool_run_total{tool, capability, outcome}`                                                           | Prometheus                       |
| Model-call failures by provider route and reason, live       | `kaizen_llm_request_total{route, purpose, outcome, failure}`                                          | Prometheus                       |
| Member API, search, scheduled tasks, sandboxes, dependencies | `kaizen_member_request_*`, `kaizen_retrieval_*`, `kaizen_task_*`, `sandbox_*`, `kaizen_dependency_up` | Prometheus                       |

Tomo's metrics deliberately carry the provider route, not the model: a label per model ID would let one misconfigured inventory multiply every series. The model ID is recorded only in the database, so per-model history comes from there. The metrics are the live, alertable view; the database is the durable, per-model view.

The API serves `/metrics` on port 8000. The background and document workers serve it on port 9100. Each process counts only what it handled, so every panel sums across them.

## Connect

Run the script after installing, reinstalling, or removing Tomo. It connects every install at once:

```bash
monitoring/grafana-prometheus/tomo/connect-tomo.sh
```

It finds each Tomo extension in namespace `kamiwaza` by its `extensions.kamiwaza.ai/name=kaizen` label. Pass `--extension <name>` to act on one install only, and `--namespace` or `--monitoring-namespace` for other namespaces.

For each install, the script applies, in order:

1. **Scrape.** A PodMonitor, `tomo-<install>`, for the API and both workers, and a NetworkPolicy, `<install>-allow-prometheus`, that admits only the Prometheus pods to ports 8000 and 9100. Port 8000 also serves Tomo's member API; that API still authenticates every request. Every install's targets share `job="tomo"` and carry `extension="<install>"`.
2. **Database access.** A PostgreSQL role, `grafana_reader`, in that install's database, created through the database pod's own superuser. The role can read only the columns kam-09 uses: model, route, purpose, outcome, error class, token counts, latency, turn status and timing, agent name, tool name, and vote. It cannot read message text, prompts, member identities, or any other table. It is read-only by default, holds at most 6 connections, and each statement is cancelled after 15 seconds.
3. **Datasource.** A Service, `<install>-reporting-db`, in front of that database; a NetworkPolicy, `<install>-allow-grafana-db`, that admits only the Grafana pods to it; and a Secret, `tomo-datasource-<install>`, that Grafana's datasource sidecar provisions as **Tomo · &lt;install&gt;**. kam-09 selects that datasource when you select the install.

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
- **After a Tomo upgrade that changes one of the four tables.** The column grants name exact columns; a renamed column shows as a query error on the panel that reads it.

An upgrade of the same install keeps the extension name, so the Service, NetworkPolicies, PodMonitor, and role keep working.

## Disconnect

```bash
monitoring/grafana-prometheus/tomo/connect-tomo.sh --remove                      # every connected install
monitoring/grafana-prometheus/tomo/connect-tomo.sh --remove --extension <install> # one install
```

This deletes each install's PodMonitor, NetworkPolicies, and Service, retires its datasource, and drops the role when its database is still running.

## Boundaries

- Grafana reads each Tomo database directly. That couples kam-09 to Tomo's schema, and crosses each install's isolation for one role and one port. The column grants, the read-only role, the connection limit, and the statement timeout keep that crossing narrow; remove it with `--remove`.
- The connection to the database is not encrypted, the same as Tomo's own services inside the cluster.
- Anyone who can edit dashboards in Grafana can run their own queries against the granted columns. Those columns carry no content and no identity, but they do reveal usage volume and timing.
