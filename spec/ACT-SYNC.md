# ACT-SYNC — Sync compatibility interfaces (informative)

**Status:** Informative. Compatibility tier — **not** part of the normative ACT
wire protocol.

## 1. Why this exists

ACT's canonical capability interfaces (`act:tools/tool-provider`,
`act:sessions/session-provider`) declare their functions `async` and carry a
`stream<tool-event>`-bearing `tool-result`. Today only Rust's wit-bindgen
backend generates that cleanly; the `cpp` / `csharp` / `go` backends panic on
`stream<>` inside a variant or emit no glue for `async func`. Until native
async codegen (wasip3) is universal across these backends — years out — those
languages cannot author a conformant ACT component directly.

The **sync compatibility packages** bridge that gap:

- `act:tools-sync/tool-provider-sync@0.1.0` — sync, no-stream mirror of
  `act:tools/tool-provider@0.2.0`.
- `act:sessions-sync/session-provider-sync@0.1.0` — sync mirror of
  `act:sessions/session-provider@0.2.0`.

A constrained-language guest implements the **sync** interface; an official
generic Rust adapter shim (`act:shim-tools-sync` / `act:shim-sessions-sync`,
published as OCI components on actcore.dev) is composed on top with `wac plug`
and exports the **canonical async** interface.

## 2. Normative rules

- The canonical async packages are **unchanged**. The `-sync` packages are
  additional sibling packages.
- A component authored against a `-sync` interface **MUST** be composed with an
  adapter so that the shipped component exports the canonical async interface
  and the `-sync` import is fully internalized. Such a `-sync` import MUST NOT
  appear in a shipped component's import surface.
- Hosts are **NOT** required to implement the `-sync` interfaces. The reference
  host (`act-cli`) does not, and will not.
- The `-sync` packages reuse the canonical `types` interfaces
  (`act:tools/types@0.2.0`, `act:sessions/types@0.2.0`, `act:core/types@0.4.0`),
  so the adapter forwards with no type conversion.

## 3. Sunset

This tier is transitional. It SHOULD be deprecated once native async / stream
codegen is universally available across the constrained-language wit-bindgen
backends (tracked broadly as "wasip3 everywhere"). Existing components continue
to work via the shim; new components in those languages should move to native
async authoring once their toolchains support it.

## 4. Official shims

Prebuilt adapter shims are published as OCI components under the `act:shim-*`
family on actcore.dev:

| Shim | Bridges | OCI reference |
|------|---------|---------------|
| `act:shim-tools-sync` | `act:tools-sync` → `act:tools` | `ghcr.io/actcore/act/shim-tools-sync:0.1.0` |
| `act:shim-sessions-sync` | `act:sessions-sync` → `act:sessions` | `ghcr.io/actcore/act/shim-sessions-sync:0.1.0` |

The `act:shim-*` family is reserved for official shims in general and is not
limited to ACT's own WIT (e.g. a future wasip2→wasip3 HTTP adapter would be
`act:shim-wasi-http-p2`). Sources and build for the ACT sync shims live in the
`act-shims` repository.

Author flow:

```bash
wkg oci pull ghcr.io/actcore/act/shim-tools-sync:0.1.0 -o shim-tools-sync.wasm
# author inner.wasm exporting act:tools-sync/tool-provider-sync@0.1.0
wac plug shim-tools-sync.wasm --plug inner.wasm -o composed.wasm
act-build pack composed.wasm && act-build validate composed.wasm
```
