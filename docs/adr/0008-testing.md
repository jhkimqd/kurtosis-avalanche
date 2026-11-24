# 0008. Test Starlark logic in Python and the real interpreter with dry runs

Status: Accepted

## Context

Most errors in a package are in parsing, validation, sizing, and the wiring of services. A live deployment finds them, but it takes minutes. Kurtosis has no built-in unit test runner. kurtosis-pos uses the external `kurtosis-test` tool, which is one more binary to install.

## Decision

Three levels of tests:

1. **Unit tests in Python** (`tests/`, seconds). The Starlark modules stay within the syntax that Starlark and Python share. `tests/starlark.py` loads them with `exec`, with a fake `plan` that records each call. The tests cover the defaults, the validation rules, the node config of each role, the bootstrap sizing, and the order of the plan. The loader rejects the common Python constructs that Starlark does not have; the dry run of level 2 is the authority.
2. **Dry runs** (`helpers/check-package.sh`). The real Kurtosis interpreter lints the package and plans every file in `examples/` and `.github/configs/`.
3. **Live runs** (`kurtosis run` in a new enclave, the integration workflow). Each deployment ends with its own checks: the validator set on the P-Chain, a bridge transfer, test transfers, and agreement of the RPC nodes.

The bash helpers of the setup scripts have unit tests in Python (`tests/test_scripts.py`).

## Consequences

- A contributor needs only Python for the fast loop.
- A module must use only what both languages accept and treat alike. For example: `import_module` instead of `load()`, and no `while`, `try`, `class`, or f-string.
- A semantic difference between the two languages can hide a bug. For that reason the dry run is a required check, and a change to `src/` needs a live run.
- A new Kurtosis type in a module needs an entry in the fake builtins of `tests/starlark.py`.

## Alternatives

- `kurtosis-test`: runs real Starlark, but cannot assert on the rendered files as directly, and it is a further tool to install in CI.
- Live runs only: too slow for the edit loop.
