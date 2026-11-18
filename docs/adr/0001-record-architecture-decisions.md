# 0001. Record architecture decisions as ADRs

Status: Accepted

## Context

People and coding agents change this package. An agent starts each task without the history of earlier tasks. Without a record, it can undo a deliberate choice because the choice looks arbitrary in the code.

## Decision

We record each decision that shapes the architecture as an ADR in `docs/adr/`. `AGENTS.md` tells a contributor when to write one. The format is short: context, decision, consequences, alternatives.

## Consequences

- A contributor reads `docs/adr/README.md` before an architecture change.
- A change that adds a service, an argument group, a trust boundary, or a dependency comes with an ADR.
- An accepted ADR is a constraint. To change it, write a new ADR that supersedes it.
- Code comments explain what the code does. The ADR explains why the design is so.

## Alternatives

- Long comments in the code: they explain one file, not a choice that spans several.
- Commit messages only: an agent does not read the full history before it edits.
