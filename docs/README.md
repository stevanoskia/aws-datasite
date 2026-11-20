# Documentation

Docs are written **while** each part is built, not at the end. Every major decision is an ADR (Architecture Decision Record) that
answers the same questions: what, why, how, alternatives, why this one, drawbacks, how validated, outcome.

| Document | What it covers |
|---|---|
| [requirements.md](requirements.md) | The requirement checklist (IDs R1–R8, OPT) that every other document refers to |
| [adr/](adr/) | Decision records, numbered in the order they were made ([template](adr/_template.md)) |
| [investigations/](investigations/) | PostgreSQL query investigations, one per query ([template](investigations/_template.md)) |
| [runbooks/](runbooks/) | What to do when an alert fires or a procedure is needed ([template](runbooks/_template.md)) |

## Decision records

| ADR | Title | Status |
|---|---|---|
| [0001](adr/0001-ci-access-without-oidc.md) | CI access to AWS without OIDC | Accepted |
| [0002](adr/0002-terraform-layout-and-state.md) | Terraform layout and state | Accepted |
