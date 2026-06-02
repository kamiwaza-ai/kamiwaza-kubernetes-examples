# Offline / air-gap readiness evidence

## Target

- Date:
- Tester:
- Kajiya run:
- Kamiwaza URL:
- Kamiwaza IP / private endpoint:
- Branches / refs:
- Offline bundle artifact:

## Network controls

- Client control:
- Server control:
- DNS behavior:
- Explicit allowlist:

## Phase results

| Phase | Result | Evidence |
| --- | --- | --- |
| Browser-only smoke |  | HAR summary: |
| Locked-down client VM |  | Firewall output / HAR summary: |
| Server-side egress deny |  | NSG/Firewall logs / `server-egress-probe.sh` output: |

## Workflow matrix

| Area | Workflow | Result | Notes |
| --- | --- | --- | --- |
| Core | Load UI |  |  |
| Core | Login/logout |  |  |
| Core | Model list |  |  |
| Core | Offline chat/inference |  |  |
| Core | Embedding behavior |  |  |
| Core | File upload/download |  |  |
| Core | Offline App Garden/catalog |  |  |
| Kaizen | Launch |  |  |
| Kaizen | Create workroom |  |  |
| Kaizen | Agent/task with offline model |  |  |
| Kaizen | File flows |  |  |
| Kaizen | Basic skill |  |  |
| Kaizen | Skill with Python requirements |  |  |
| Extensions | DDE |  |  |
| Extensions | Graphiti |  |  |
| Extensions | Milvus |  |  |
| Extensions | Vespa |  |  |
| Extensions | Omniparse |  |  |
| Extensions | Connector Builder internal/mock API |  |  |

## External origins / egress attempts

| Origin or destination | Source | Required? | Classification | Issue |
| --- | --- | --- | --- | --- |
|  |  |  |  |  |

## Decision

- Decision:
- Blocking issues:
- Non-blocking noise:
- Follow-up owner:
