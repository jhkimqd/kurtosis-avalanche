# 0004. Sign transactions in a Go tool that journals every step

Status: Superseded by 0018

## Context

Starlark cannot generate keys or sign transactions. An L1 needs P-Chain transactions, Warp messages with aggregated BLS signatures, and contract calls, in a strict order. A step can fail after its transaction was sent. A blind retry would then create a second subnet or register a validator twice.

## Decision

A Go program, `lab` (`tools/`), does this work. It runs in one long-lived service, `tools`, and the package calls it with `plan.exec`.

- `lab` uses the AvalancheGo libraries at the same commit as the node images.
- Before `lab` sends a setup transaction, it writes the signed bytes to a journal under `/state`. A repeated command finds the journal and sends the same bytes again. Only the test transfers of `lab run` have no journal.
- A journal records its deployment (the hash of the P-Chain genesis block) and a hash of its inputs. `lab` refuses a journal that belongs to another deployment or to other inputs.
- One file lock lets a single command run at a time, because all commands sign with the same account. A second command at the same time fails.
- The package stores `/state` as the `deployment-state` artifact.

## Consequences

- Each setup command of `lab` is safe to repeat.
- An enclave is used for one deployment. A second `kurtosis run` in the same enclave is not supported; `scripts/run.sh` refuses it.
- `/state` holds every node key. Treat the artifact as a secret if its keys are reused anywhere.
- The tools image builds from source on the first run, which takes a few minutes. `images.tools` accepts a prebuilt image.

## Alternatives

- Shell scripts with `avalanche-cli` or `cast`: no control over exactly-once behaviour, and a second set of versions to pin.
- One container per command (`plan.run_sh`): no shared journal directory without more artifact copies.
