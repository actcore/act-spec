---
title: ACT Protocol Specification
version: 0.3.0
status: normative
requires: [act:core@0.3.0]
---

# ACT: Agent Component Tools

## 1. Introduction

ACT (Agent Component Tools) is a self-documenting RPC protocol built on top of the WebAssembly Component Model. It defines a standard interface for packaging callable tools as WASM components that can be consumed by AI agents, application developers, and orchestration platforms alike.

A single ACT component is a `.wasm` file that exports a well-known set of interfaces. A host runtime loads the component, inspects its metadata and capabilities, discovers available tools, and invokes them — receiving results as a sequence of events.

### 1.1 Design Goals

- **Universal access** — one component serves both agent-oriented (MCP-compatible) and application-oriented (binary RPC) consumers through transport adapters.
- **Self-documenting** — every tool carries localized descriptions, parameter schemas, usage hints, and behavioral annotations directly in the component.
- **Sandboxed** — WASM isolation provides capability-based security by default. Components cannot access host resources unless explicitly linked.
- **Stateless protocol** — metadata is passed per-call, enabling horizontal scaling and CDN/proxy compatibility. Components MAY maintain internal state (caches, connection pools) as a private optimization, but the protocol does not manage or expose it.
- **Uniform result shape** — tool results are delivered as an event sequence, either immediate (bounded list) or streaming (unbounded stream), with identical event semantics.
- **Efficient** — Deterministically Encoded CBOR for arguments and content data. Native binary support without base64 overhead.
- **Extensible** — every record carries a `metadata` field with namespaced key-value pairs; breaking changes are handled through WIT package versioning.

### 1.2 Relationship to Existing Standards

ACT builds on:
- **WebAssembly Component Model** — for component packaging, linking, and type system.
- **WIT (WebAssembly Interface Types)** — as the sole IDL.
- **WASI Preview 3 (wasip3)** — for async functions, `future`, and `stream` types.
- **JSON Schema** — for parameter and metadata schema description. Hosts MAY also support JSON Structure (json-structure.org), detected via the `$schema` field.
- **CBOR (RFC 8949)** — for binary encoding of arguments and content data. Specifically, Deterministically Encoded CBOR (§4.2).
- **BCP 47** — for language tags in localized strings.

ACT is not a transport protocol. It defines the component-level contract. Transport bindings (MCP, HTTP+JSON, HTTP+CBOR) are specified separately.

### 1.3 Notational Conventions

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in RFC 2119.

WIT snippets use the syntax defined by the Component Model specification.

CBOR examples use CBOR diagnostic notation (RFC 8949 §8).

---

## 2. Terminology

| Term | Definition |
|------|-----------|
| **Component** | A `.wasm` file conforming to the WebAssembly Component Model that exports the ACT world. |
| **Host** | A runtime (e.g. wasmtime) that loads, links, and executes ACT components. |
| **Tool** | A named callable function exposed by a component through the `tool-provider` interface. |
| **Metadata** | A list of key-value pairs (`list<tuple<string, list<u8>>>`) carried by every record type in the protocol and passed as a parameter to discovery and invocation functions. Keys are namespaced strings (`std:` for well-known, vendor prefix for custom). Values are CBOR-encoded. Components produce valid CBOR; the host canonicalizes to dCBOR when needed. |
| **dCBOR** | Deterministically Encoded CBOR as defined in RFC 8949 §4.2. |
| **Transport Adapter** | A layer that translates between an external protocol (MCP, HTTP, etc.) and ACT host calls. |
| **Capability** | A host-side resource (network, filesystem, etc.) identified by a URI that a component may require. |
| **Bridge Component** | A component that adapts an external protocol (OpenAPI, MCP, ACT-HTTP) into the ACT `tool-provider` interface, configured via metadata. |

---

## 3. WIT Specification

### 3.1 Package

```wit
package act:core@0.3.0;
```

### 3.2 Component Info (Custom Section)

Component-level metadata is stored in the WASM binary as a custom section named `act:component`, not as an exported function. This allows hosts, registries, and tooling to read component information without instantiating the component or executing any code.

The custom section contains a CBOR-encoded map of namespaced tables. Well-known metadata lives in the `std` table, third-party extensions use their own namespace (e.g. `acme`). This structure maps directly to TOML (`act.toml`) for authoring convenience.

**`std` table keys:**

| Key | CBOR type | Required | Description |
|-----|-----------|----------|-------------|
| `name` | tstr | MUST | Component name. |
| `version` | tstr | MUST | SemVer version string. |
| `description` | tstr or map | MAY | Localized description. Plain string or `{"en": "...", "ru": "..."}` map. |
| `default-language` | tstr | MAY | BCP 47 language tag for the component's default language. If absent, `plain` strings have no declared language. |
| `capabilities` | map | MAY | Map of capability declarations keyed by capability identifier. Presence of a key declares that the component uses this capability. The value is an object with capability-specific parameters (may be empty). See Section 7. |

Custom namespaces follow the same convention. Hosts and tooling MUST ignore unrecognized namespaces and keys.

Components SHOULD also set standard WASM metadata fields `name` and `version` (via `wasm-tools metadata add` or equivalent) for compatibility with WASM registries and tooling.

**Example (CBOR diagnostic notation):**

```cbor
{
  "std": {
    "name": "weather-tools",
    "version": "1.2.0",
    "description": "Weather data tools",
    "default-language": "en",
    "capabilities": {
      "wasi:http": {}
    }
  }
}
```

**Corresponding `act.toml`:**

```toml
[std]
name = "weather-tools"
version = "1.2.0"
description = "Weather data tools"
default-language = "en"

[std.capabilities."wasi:http"]
```

**Tooling:**
- Rust SDK (`#[act_component]`) reads `act.toml` and generates the custom section automatically at compile time.
- Python components use `componentize-py`; the build step converts `act.toml` to CBOR via `tomllib` + `cbor2`.
- `wasm-tools metadata add` sets standard WASM metadata for registry compatibility.

### 3.3 Types Interface

```wit
interface types {

  /// A localizable text value.
  ///
  /// - `plain` — an opaque UTF-8 string. If `std.default-language` is declared
  ///   in the `act:component` section, the string is assumed to be in that language.
  ///   Otherwise, the language is undefined.
  /// - `localized` — a list of (BCP 47 language-tag, text) pairs.
  ///   If `std.default-language` is declared, SHOULD include an entry for it.
  variant localized-string {
    plain(string),
    localized(list<tuple<string, string>>),
  }

  /// Key-value metadata. Keys are namespaced strings, values are CBOR-encoded.
  /// Components produce valid CBOR; the host canonicalizes to dCBOR if needed.
  /// Well-known keys use the `std:` prefix (e.g. "std:read-only", "std:timeout-ms").
  /// Third-party keys use their own namespace (e.g. "acme:priority").
  type metadata = list<tuple<string, list<u8>>>;



  // ──────────────────────────────────────────────
  //  Tool-level types
  // ──────────────────────────────────────────────

  /// Full definition of a tool, returned by list-tools.
  record tool-definition {
    name: string,
    description: localized-string,
    /// Parameter schema as a JSON Schema string (default).
    /// Hosts MAY also accept JSON Structure (json-structure.org),
    /// detected via the `$schema` field.
    parameters-schema: string,
    /// Well-known keys: std:read-only, std:idempotent, std:destructive,
    /// std:usage-hints, std:anti-usage-hints, std:examples, std:tags, std:timeout-ms.
    metadata: metadata,
  }


  // ──────────────────────────────────────────────
  //  Call / Result types
  // ──────────────────────────────────────────────

  /// A request to invoke a tool.
  record tool-call {
    /// Tool name, as returned by list-tools.
    name: string,
    /// Deterministically Encoded CBOR arguments (RFC 8949 §4.2).
    /// Validated by the host against parameter schemas before being passed to the component.
    arguments: list<u8>,
    metadata: metadata,
  }

  /// A single piece of content in a tool's result stream.
  record content-part {
    /// Payload bytes. Interpretation depends on `mime-type`:
    /// - `text/*` — raw UTF-8 text
    /// - `application/cbor` — CBOR-encoded structured data
    /// - `application/json` — JSON
    /// - `image/*` — binary image data
    /// - absent or other — opaque bytes (application/octet-stream)
    data: list<u8>,
    /// MIME type of the data. If absent, data is treated as opaque bytes.
    mime-type: option<string>,
    metadata: metadata,
  }

  /// Structured error returned by tools.
  /// Well-known kind values: std:not-found, std:invalid-args, std:timeout,
  /// std:capability-denied, std:internal. Custom kinds use namespaced strings.
  record tool-error {
    kind: string,
    message: localized-string,
    metadata: metadata,
  }

  /// A single event in a tool's result.
  /// A `tool-event::error` is terminal — no further events follow.
  variant tool-event {
    content(content-part),
    error(tool-error),
  }

  /// The result of a tool call.
  ///
  /// Two shapes exist to accommodate different guest capabilities; they are
  /// semantically equivalent. Both carry an ordered sequence of `tool-event`s
  /// with identical terminal-error semantics. Hosts, intermediaries, and callers
  /// MUST treat both variants as equivalent event sequences. Intermediaries MAY
  /// freely convert between variants.
  ///
  /// - `immediate` — event list is materialized when the tool returns.
  /// - `streaming` — events are emitted to a stream as they are produced.
  variant tool-result {
    immediate(list<tool-event>),
    streaming(stream<tool-event>),
  }


  // ──────────────────────────────────────────────
  //  Response wrappers
  // ──────────────────────────────────────────────

  /// Response from list-tools.
  record list-tools-response {
    metadata: metadata,
    tools: list<tool-definition>,
  }
}
```

### 3.4 Tool Provider Interface

```wit
interface tool-provider {
  use types.{
    tool-definition,
    tool-call,
    tool-result,
    list-tools-response,
    tool-error,
    metadata,
  };

  /// Returns a JSON Schema (type "object") describing the metadata keys
  /// this component accepts. Returns `none` if no metadata is required.
  ///
  /// When called with empty metadata, the component MUST return immediately
  /// without performing any network I/O.
  ///
  /// The host MAY call this multiple times with progressively filled
  /// metadata to support iterative schema discovery (Section 4.5).
  /// Subsequent calls with non-empty metadata MAY perform network I/O
  /// (e.g. fetching a remote component's schema).
  get-metadata-schema: async func(metadata: metadata) -> option<string>;

  /// Returns the list of tools available for the given metadata.
  /// Async because bridge components may need to fetch remote schemas.
  list-tools: async func(metadata: metadata) -> result<list-tools-response, tool-error>;

  /// Invokes a tool. Metadata is carried inside `tool-call.metadata`.
  ///
  /// Returns either `immediate` (bounded, sync-friendly) or `streaming`
  /// (unbounded or incremental). Both carry `tool-event`s with the same
  /// semantics: `tool-event::error` is terminal.
  call-tool: async func(call: tool-call) -> tool-result;
}
```

### 3.5 World

```wit
world act-world {
  export tool-provider;
}
```

The `event-provider` and `resource-provider` interfaces are informative (RFC) design sketches, documented separately in `ACT-EVENTS.md` and `ACT-RESOURCES.md`. They are not part of the normative `act:core@0.3.0` contract.

---

## 4. Component Lifecycle

### 4.1 Loading

1. The host loads the `.wasm` component binary.
2. The host reads the `act:component` custom section (CBOR-encoded) to obtain component information. The `std.name` and `std.version` fields MUST be present. If the `act:component` section is absent, the host MUST reject the component.
3. The host links WASI and other imports according to its capability policy. The host MAY use `capabilities` from the custom section to make linking decisions proactively.
4. The host calls `tool-provider.get-metadata-schema([])` to determine whether the component requires metadata.
5. The component is now ready to accept calls (if no metadata is required).

If the component imports a WASI interface that the host did not link, the component will trap at the point of use.

### 4.2 Tool Discovery

`list-tools` is an async function. Bridge components may need to fetch remote schemas (e.g. OpenAPI specs) during discovery, which requires I/O. Simple components return immediately; the async signature imposes no overhead in that case.

1. The host (or transport adapter) calls `list-tools(metadata)` and awaits the result.
2. If `list-tools` returns `Ok(list-tools-response)`, the host processes the response metadata and tool definitions.
3. If `list-tools` returns `Err(tool-error)`, the host MUST surface the error to the caller through the appropriate transport mechanism. The host MUST NOT cache error results.
4. The host SHOULD cache successful results for a given metadata value unless the component indicates dynamism through metadata.

For components without metadata requirements (`get-metadata-schema` returns `none`), the host calls `list-tools([])` and MAY cache the result for the lifetime of the component instance.

### 4.3 Tool Invocation

1. The caller constructs a `tool-call` with a tool `name`, dCBOR `arguments`, and `metadata`. Correlation identifiers (if needed) are a transport-layer concern, not part of the protocol.
2. The host MUST validate `arguments` (after decoding from CBOR) against the schema declared in `tool-definition.parameters-schema` for the named tool. If validation fails, the host MUST return a `tool-error` with kind `std:invalid-args` without calling the component.
3. The host MUST validate metadata against the schema from `get-metadata-schema` if present. If the component requires metadata and none is provided, or if the metadata does not match the schema, the host MUST return a `tool-error` with kind `std:invalid-args`.
4. The host MUST ensure `arguments` are deterministically encoded before passing them to the component.
5. The host calls `call-tool(call)`.
6. The host receives a `tool-result` and dispatches on the variant:
   - `immediate(events)` — the full event list is available synchronously. The host processes events in order.
   - `streaming(stream)` — the host reads events from the stream as they arrive.
7. In both cases, events are interpreted identically:
   - `content(part)` — a piece of result content. There may be zero or more.
   - `error(e)` — a terminal error. No further events follow.
8. The call is successful when the sequence ends without an `error` event. Early failures (tool not found, capability denied) are returned as `immediate([error(e)])`.

The two variants carry **identical observable semantics**: an ordered sequence of `tool-event`s with a terminal `error` event. The choice between them is a guest implementation detail driven by the language, runtime, and expected output size — not a protocol-level classification of the tool. Hosts, intermediaries, and callers treat both variants uniformly.

#### 4.3.1 Why Two Variants Exist

`immediate` exists to let components without an async runtime (and components without incremental output) implement `call-tool` as a simple function that returns a list. `streaming` exists to let components emit events as they are produced, without buffering the entire result or blocking the guest instance on unbounded computation.

Guest-side considerations that typically inform the choice:

| Guest situation | Typical guest implementation choice |
|---|---|
| Sync function returning a bounded result (hash, encode, parse) | `immediate` |
| Language without async runtime (MoonBit, Go with limited async) | `immediate` |
| Incremental producer with live progress (LLM tokens, SQL cursor, log tail) | `streaming` |
| Large or unbounded output where buffering is wasteful | `streaming` |
| I/O-bound bridge forwarding upstream events | `streaming` |

The `async` keyword on `call-tool` and this choice are orthogonal: a guest function may await I/O and still return `immediate`, or be a sync body and still return `streaming`. Languages lowering `async func` as a sync export can only produce `immediate`, which is sufficient for a large class of tools.

#### 4.3.2 Variant Conversion by Intermediaries

Because observable semantics are identical, intermediaries (bridges, proxies, adapters) MAY freely convert between variants based on their own characteristics. Event ordering and terminal-error semantics MUST be preserved.

- **`immediate` → `streaming`.** An intermediary that performs I/O on every call (e.g. `act-http-bridge` forwarding over HTTP, `mcp-bridge` forwarding over MCP Streamable HTTP) SHOULD return `streaming` to its caller regardless of what the upstream returned. The intermediary is already async by nature; wrapping events in a local stream lets the caller begin processing as soon as they arrive over the wire, rather than blocking on the full upstream round-trip.
- **`streaming` → `immediate`.** An intermediary whose output channel cannot carry partial results (e.g. MCP stdio, request/reply HTTP with bounded body) MAY buffer a `streaming` source into `immediate`. This requires the source to be bounded. Intermediaries MAY rely on host-level memory limits for overflow protection; those that enforce their own size limit SHOULD surface the overflow as a terminal `tool-event::error` with kind `std:internal`.

Callers MUST NOT infer anything about a tool's nature from the runtime variant observed at a given call site — that choice belongs to whoever implemented the nearest producer.

**Host fairness.** A very large `immediate(list<tool-event>)` arrives in a single allocation — the host cannot backpressure on it the way it can on a stream. Components producing large or unbounded results SHOULD prefer `streaming`. Hosts MAY enforce an upper bound on `immediate` size via wasmtime memory limits.

### 4.4 Cancellation

Cancellation is a uniform host-side concern. The host initiates cancellation when the caller disconnects, on timeout, or on any other policy trigger. The mechanism used depends on where the guest is in its execution, not on which `tool-result` variant the component returns.

Hosts have two cancellation mechanisms, in order of preference:

- **Cooperative cancellation.** The host drops the async future (for an in-flight `call-tool`) or the stream reader (for a returned `streaming` result). The wasmtime runtime propagates cancellation to the affected guest task at its next yield point. Other concurrent invocations on the same instance are unaffected. This is the preferred mechanism.
- **Runtime-level interruption.** The host triggers wasmtime's epoch bump or fuel exhaustion, causing the guest to trap at the next compiled-in check. The host catches the trap and tears down the instance. Every concurrent invocation on that instance fails. This is a fallback for runaway components that never yield.

**Two execution phases:**

1. **In-flight `call-tool` invocation.** The guest is still inside `call-tool`: computing, awaiting an I/O import, or preparing to return. No `tool-result` has been produced yet. The host SHOULD cancel by dropping the call future and waiting (up to a policy-defined grace period) for the guest task to observe the cancel at its next yield. If the guest yields, any partially-constructed result is discarded. If the guest fails to yield within the grace period, the host MAY escalate to runtime-level interruption. For short-lived tools, hosts MAY simply wait for `call-tool` to complete and then discard the returned `tool-result` — this preserves instance integrity with no protocol-visible difference for the caller.

2. **After `call-tool` returns with `streaming`.** The guest has returned a stream handle; a spawned guest task continues to produce events. A spawned task belongs to this phase once `call-tool` returns, regardless of when it was spawned. The host cancels by dropping the stream reader; the runtime propagates cancellation at the spawned task's next yield. Runtime-level interruption remains available as a fallback for non-yielding producers, at the cost of destroying the instance.

There is no separate "after `call-tool` returns with `immediate`" phase: an `immediate` result is fully materialized at return, so there is no in-guest work remaining to cancel.

Hosts SHOULD document their cancellation policy (grace period before escalating, epoch tick interval, fuel budget) so component authors can reason about worst-case cancellation latency.

Any `tool-event::content` values already delivered to the caller before cancellation are considered valid and MUST NOT be withdrawn.

**Component guidelines for cancellable long-running work.** Guest components producing `streaming` results MUST ensure the producer task yields periodically (either naturally via async I/O or explicitly via cooperative yield); otherwise drop-reader cancellation is ineffective and the host falls back to instance-destroying trap. Guest components producing `immediate` results SHOULD also yield during the in-flight phase for responsive cancellation. Recommended techniques:

- **Prefer async I/O for bulk data.** Hashing, compressing, or parsing large inputs SHOULD read through `wasi:filesystem` / `wasi:http` streams. Each `read` is a natural yield point; cancellation via dropping the result handle cooperates cleanly. Small inputs (≤ a few MB of in-memory argument) do not need special treatment — they complete before any reasonable cancellation timeout.
- **Yield explicitly in CPU-bound loops.** Components that cannot route work through async I/O (e.g. computation over an in-memory buffer passed as argument) SHOULD periodically `await` a cooperative yield (`tokio::task::yield_now` equivalent, or an explicit `futures::pending!` once with a cleared waker). A yield every ~1ms of CPU work gives the host responsive cancellation without measurable throughput cost.
- **WASM has no thread offload.** Unlike `tokio::spawn_blocking` or ASGI's `run_in_executor`, WASM has no OS-thread pool to absorb sync CPU work. Cooperative yields or async I/O are the only portable mechanisms. A future threads proposal may relax this.
- **Guest languages without async runtime.** MoonBit, Go, and similar toolchains that lower `async func` as sync exports cannot yield cooperatively. Components written in such languages SHOULD be short-lived and SHOULD NOT produce `streaming` results requiring mid-stream cancellation; long-running work is not portable to these languages until their WIT async bindings mature.

### 4.5 Metadata as Context

Metadata unifies what was previously split between `config` and `metadata`. It carries per-call context (authentication, endpoint URLs, preferences) and infrastructure data (trace context, progress tokens) in a single mechanism.

- **Arguments** describe _what_ to do (the request body).
- **Metadata** describes _where_, _as whom_, and _how_ (the request context).

Transport adapters map metadata to the natural mechanism for each transport:

| Transport | Metadata mechanism |
|-----------|-------------------|
| HTTP | Metadata fields in request body or `X-ACT-Metadata` header |
| MCP stdio | Process environment, host configuration, or request extensions |

The host MAY merge metadata from multiple sources (e.g. server defaults + client-provided values) before passing it to the component.

#### Iterative Schema Discovery

For bridge components, the metadata schema may depend on metadata already provided. The host uses `get-metadata-schema` iteratively:

1. Call `get-metadata-schema([])`. The component MUST return immediately without network I/O. It returns a JSON Schema describing its initial metadata requirements.
2. If the schema has `required` properties without values in the current metadata, the host prompts the caller for those values.
3. Call `get-metadata-schema(partial_metadata)` with the values obtained. This call MAY perform network I/O (e.g. a bridge connecting to a remote component to discover its metadata schema). The component MAY return an expanded schema.
4. Repeat until all `required` properties are satisfied.
5. Call `list-tools(metadata)`.

Simple components return `none` from `get-metadata-schema` and accept empty metadata. They are unaffected by this mechanism.

---

## 5. Localization

### 5.1 Default Language

A component MAY declare a default language via `std.default-language` in the `act:component` custom section (a BCP 47 tag). This is the language the component author writes in natively.

If `std.default-language` is not declared, `plain` strings have no declared language and the host treats them as opaque UTF-8 text.

### 5.2 Localized Strings

The `localized-string` type is a variant with two cases:

- **`plain(string)`** — an opaque UTF-8 string. If `std.default-language` is declared, the string is assumed to be in that language. Otherwise, the language is undefined.
- **`localized(list<tuple<string, string>>)`** — a list of `(language-tag, text)` pairs. If `std.default-language` is declared, the component SHOULD include an entry for it.

All human-readable text intended for agents or end users is represented as `localized-string`.

- Language tags MUST conform to BCP 47.
- Components MAY provide entries for any number of languages.

### 5.3 CBOR Encoding

In WIT, `localized-string` is represented as `variant { plain(string), localized(list<tuple<string, string>>) }`. In CBOR (used in the `act:component` custom section, metadata values, and external representations), a more natural encoding is used:

- **`plain`** — a CBOR text string (`tstr`).
- **`localized`** — a CBOR map (`{tstr → tstr}`) where keys are BCP 47 language tags and values are the localized text.

Examples (CBOR diagnostic notation):

```cbor
"Weather data tools"

{"en": "Weather data tools", "ru": "Инструменты для погоды"}
```

Hosts and SDKs MUST handle both forms: a bare text string is `plain`, a map of strings is `localized`. This applies to the `act:component` custom section (`std.description`), metadata values containing localized strings, and any external CBOR/JSON representation.

### 5.4 Host Resolution

When a transport adapter needs a single-language string (e.g. for an MCP response), the resolution strategy is implementation-defined. Hosts SHOULD use `Accept-Language` or equivalent mechanisms to select the best match.

For `plain(text)`:
1. Use `text` directly.

For `localized(entries)`:
1. Select the best match using the host's language resolution strategy (e.g. `Accept-Language` matching).
2. If no match is found, fall back to `std.default-language` (if declared), then to the first available entry.

The component is not involved in language selection — it returns all available localizations, and the host or adapter chooses.

---

## 6. Data Encoding

### 6.1 Deterministically Encoded CBOR

Tool arguments are encoded as Deterministically Encoded CBOR (RFC 8949 §4.2). This provides:

- **Efficiency** — compact binary encoding, smaller than JSON for most payloads.
- **Native binary data** — CBOR byte strings (`bstr`) carry binary data directly, eliminating base64 overhead.
- **Determinism** — deterministic encoding ensures the same logical value always produces the same bytes.

### 6.2 Encoding Contract

The **host** MUST ensure that all CBOR passed to a component is deterministically encoded. This means:
- Integers use the shortest encoding.
- Map keys are sorted by byte comparison of their encoded form.
- No indefinite-length items.
- No duplicate map keys.

**Components** are NOT required to verify deterministic encoding of incoming CBOR. They may assume it is deterministic if the host is conformant. Components are only required to support the deterministic subset of CBOR — they MAY reject non-deterministic encodings.

**Components** that produce CBOR (e.g. in `content-part.data`, `metadata` values) MUST produce valid CBOR but are NOT required to use deterministic encoding. The host is responsible for canonicalizing component-produced CBOR to dCBOR before passing it to external consumers.

### 6.3 Parameter Schemas

`tool-definition.parameters-schema` contains a JSON Schema string describing the tool's parameters as a JSON Schema object type. The schema defines parameter names, types, constraints, required fields, and descriptions.

JSON Schema is the default schema language because JSON and CBOR share nearly identical data models (maps, arrays, strings, numbers, booleans, null). Hosts MAY also support JSON Structure (json-structure.org), which offers stronger typing and built-in localization via the `altnames` companion spec. The schema format is detected via the `$schema` field.

The top-level `arguments` field of `tool-call` is a dCBOR map where keys correspond to parameter names defined in the schema.

### 6.4 Host-Side Validation

The host MUST validate tool call arguments and metadata before passing them to the component:

1. Decode CBOR to a generic value.
2. Validate against the declared schema.
3. Re-encode as dCBOR (if the input was not already deterministically encoded).
4. Pass to the component.

This guarantees that:
- Components never receive malformed input.
- Validation errors are surfaced early with `tool-error` kind `std:invalid-args`.
- Components do not spend WASM cycles on input validation.

#### Metadata Validation

If `get-metadata-schema` returns a JSON Schema:

1. The host constructs a JSON object from the metadata key-value pairs (decoding each CBOR value).
2. The host validates this object against the schema.
3. If validation fails, the host MUST return a `tool-error` with kind `std:invalid-args`.

If `get-metadata-schema` returns `none`, the host passes metadata through without validation.

### 6.5 Content Data

The `content-part.data` field is `list<u8>` — raw bytes. The `mime-type` field determines how to interpret them:

- **`text/*`** — raw UTF-8 text.
- **`application/json`** — raw UTF-8 text (JSON). Treated the same as `text/*` for encoding purposes.
- **`application/cbor`** — CBOR-encoded structured data. Components produce valid CBOR; the host canonicalizes to dCBOR before passing to external consumers.
- **`image/*`** — binary image data.
- **absent or other** — opaque bytes (`application/octet-stream`).

Common MIME types:

| MIME type | `data` encoding |
|-----------|-----------------|
| `text/plain` | UTF-8 encoded text |
| `text/markdown` | UTF-8 encoded Markdown |
| `application/cbor` | CBOR-encoded structured data; host canonicalizes to dCBOR |
| `application/json` | JSON |
| `image/png` | Raw PNG bytes |
| `audio/wav` | Raw WAV bytes |

No base64 encoding is needed — binary data is passed directly as bytes.

Hosts that do not recognize a MIME type SHOULD pass the content through to the client unmodified.

### 6.6 SDK Generation

Language-specific SDKs SHOULD generate parameter schemas from native type signatures automatically. The developer writes typed functions; the SDK produces the `parameters-schema` string. SDKs SHOULD handle CBOR encoding/decoding transparently — the developer works with native types.

---

## 7. Capabilities

### 7.1 Capability Model

Capabilities represent host-side resources — external dependencies such as network access or filesystem — that a component may need. Only resources that require explicit host linking are declared; ambient capabilities (e.g. `wasi:clocks`, `wasi:random`) are always available and are not declared.

A component declares its capabilities through the `std.capabilities` map in the `act:component` custom section. The host uses this declaration to make linking decisions and to communicate capability requirements to clients (agents, UIs).

### 7.2 Declaration

The component declares each capability by adding its identifier as a key in the `std.capabilities` map. The value is an object containing capability-specific parameters. If a capability identifier is absent from the map, the component does not use that capability.

Capabilities that affect host resources (currently `wasi:filesystem` and `wasi:http`) carry an `allow` array enumerating what the component needs. Each entry is a positive statement — no `deny`, no global `mode` field, no other narrower mechanisms. An empty `allow` array means the component declares the class but requests zero access.

Language SDKs SHOULD populate the declaration automatically from the component's `world` definition plus author-supplied narrowing rules.

### 7.3 Enforcement

Declarations are a **ceiling** the host applies to the user's own policy. The effective policy is `user_policy ∩ component_declaration`:

- Capability identifier absent → host denies every operation of that class, regardless of user policy.
- Capability declared with empty `allow` → same hard deny.
- Capability declared with entries → the user's policy can only narrow further. Any user-policy rule that no declared entry "covers" drops from the effective allow list.

The declaration model is positive-only: components describe what they need; the user's policy independently decides what to grant within that ceiling. A separate harness-level axis (not covered here) gates which tool *names* the calling agent may invoke on a component.

### 7.4 Well-Known Capability Identifiers

The following identifiers are defined by this specification. Hosts MUST recognize them:

| Capability ID | Declaration fields | Description |
|--------------|--------------------|-------------|
| `wasi:filesystem` | `allow: array<{path, mode}>`, `mount-root?: string` | Filesystem access. Each `allow` entry has a required glob `path` and a required `mode` of `"ro"` or `"rw"`. `mount-root` sets the internal WASM root path for all host mounts (default: `/`). |
| `wasi:http` | `allow: array<{host, scheme?, methods?, ports?}>` | Outbound HTTP requests. Each `allow` entry has a required `host` (exact hostname, `*.suffix` wildcard, or `*` for any host). Optional narrowers: `scheme` (`"http"` or `"https"`), `methods` (case-insensitive list), `ports` (list of u16). |
| `wasi:sockets` | _(reserved)_ | Outbound TCP and UDP connections. Declaration format to be specified when enforcement lands. |

**Broad-access idioms:**
- `[std.capabilities."wasi:filesystem"].allow = [{ path = "**", mode = "rw" }]` — any path, read-write.
- `[std.capabilities."wasi:http"].allow = [{ host = "*" }]` — any host.

Additional capability identifiers MAY be defined by third parties using their own namespace (e.g. `acme:gpu/compute`). Hosts that do not recognize a capability identifier SHOULD treat it as hard-denied unless explicitly configured otherwise.

---

## 8. Extensibility

### 8.1 Metadata Fields

Every record type in this specification includes a `metadata` field of type `list<tuple<string, list<u8>>>`. This field carries namespaced key-value pairs for well-known annotations and vendor-specific data. Values are CBOR-encoded. Components produce valid CBOR; the host canonicalizes to dCBOR when passing data to external consumers.

- Well-known keys use the `std:` prefix (e.g. `"std:read-only"`, `"std:timeout-ms"`).
- Third-party keys use their own namespace (e.g. `"acme:priority"`).
- Hosts and components MUST ignore unrecognized metadata keys.
- Metadata MUST NOT change the semantics of any standard field.

### 8.2 Well-Known Metadata Keys

For the complete list of well-known `std:` constants — including tool definition metadata, content part metadata, cross-cutting metadata, bridge metadata, event kinds, and resource URIs — see `ACT-CONSTANTS.md`.

Commonly used tool definition metadata keys include `std:read-only`, `std:idempotent`, `std:destructive`, and `std:timeout-ms`. All metadata values are CBOR-encoded.

Transport adapters SHOULD propagate `std:traceparent` and `std:tracestate` to/from the corresponding HTTP headers (`traceparent`, `tracestate`) or MCP request extensions.

Hosts MUST NOT reject metadata entries with unrecognized keys. Components MUST NOT require specific response metadata keys to be present.

Custom event kinds use namespace prefix (e.g. `acme:order_updated`).

### 8.3 Bridge Forwarding

Bridge components chain ACT components across network boundaries. The `std:forward` metadata key enables multi-level chaining without namespace collisions.

A bridge component:
1. Consumes its own metadata keys (e.g. `act:remote_url`).
2. Decodes `std:forward` as a metadata list and passes it to the remote component.
3. The remote component may itself be a bridge with its own `std:forward` — recursion is natural.

The `get-metadata-schema` function supports this pattern through iterative discovery:

```
1. get-metadata-schema([])
   → {"properties": {"act:remote_url": {"type": "string"}}, "required": ["act:remote_url"]}

2. get-metadata-schema([("act:remote_url", cbor("https://..."))])
   → {
       "properties": {
         "act:remote_url": {"type": "string"},
         "std:forward": {
           "type": "object",
           "properties": {"api_key": {"type": "string"}},
           "required": ["api_key"]
         }
       },
       "required": ["act:remote_url"]
     }

3. list-tools([
     ("act:remote_url", cbor("https://...")),
     ("std:forward", cbor({"api_key": "sk-..."}))
   ])
```

The bridge forwards `std:forward` as the remote component's metadata. Each level of nesting unwraps one layer.

### 8.4 Versioning

Breaking changes to the WIT interfaces are handled through WIT package versioning:

```
act:core@0.1.0  ->  ...  ->  act:core@0.1.6  ->  act:core@0.2.0  ->  act:core@0.3.0
```

A host MAY support multiple interface versions simultaneously. A component declares which version it implements through its WIT world.

---

## 9. Error Handling

### 9.1 Event Error Model

All errors from `call-tool` are delivered as `tool-event::error(tool-error)` events inside the `tool-result`. A `tool-event::error` is terminal — no further events follow. There is no separate early-error path; errors that occur before execution begins (e.g. tool not found, capability denied) are returned as `immediate([error(e)])`.

Content parts delivered before an `error` event are valid and MUST be delivered to the caller (consistent with §4.4: already-delivered events MUST NOT be withdrawn).

### 9.2 Error Kind Semantics

The `tool-error.kind` field is a string. Well-known values use the `std:` prefix. Custom error kinds use their own namespace (e.g. `"acme:rate-limited"`).

For the complete list of well-known error kinds, see `ACT-CONSTANTS.md` Section 8. Commonly used error kinds include `std:not-found`, `std:invalid-args`, `std:timeout`, `std:capability-denied`, and `std:internal`.

Hosts MUST NOT reject `tool-error` values with unrecognized `kind` strings. Unknown error kinds SHOULD be treated as equivalent to `std:internal` for transport error code mapping purposes.

---

## 10. Conformance

### 10.1 Conformant Component

A conformant ACT component:
- MUST export the `act-world` world as defined in Section 3.5.
- MUST include an `act:component` custom section with a valid CBOR-encoded map containing `std.name` and `std.version` (Section 3.2).
- SHOULD include standard WASM metadata fields `name` and `version` for registry compatibility.
- If `std.default-language` is declared, SHOULD include an entry for it in every `localized-string::localized` it produces.
- MUST return valid `tool-definition` records from `list-tools()`.
- MUST accept any `tool-call` whose `arguments` conform to the declared schemas (encoded as dCBOR).
- MUST produce a well-formed `tool-result` from `call-tool()`. Either variant is conformant; see Section 4.3.1 for guidance. The result is returned directly — there is no response wrapper.
- MUST NOT emit any `tool-event` after a `tool-event::error` in either variant. A `streaming` stream that closes without emitting any events is semantically equivalent to `immediate([])` (a successful no-output call).
- MUST return a valid JSON Schema of type "object" from `get-metadata-schema()` if metadata is required, or `none` if not.
- MUST return immediately without network I/O when `get-metadata-schema` is called with empty metadata.
- MUST accept empty metadata in `list-tools` and `call-tool` if `get-metadata-schema` returns `none`.
- MUST produce valid CBOR in all output (metadata values, content-part data) but is NOT required to produce deterministic CBOR. The host canonicalizes.
- Is NOT required to verify deterministic CBOR encoding of incoming data but MUST support the deterministic subset.

### 10.2 Conformant Host

A conformant ACT host:
- MUST encode arguments as dCBOR before passing them to the component (Section 6.2).
- MUST canonicalize CBOR produced by components (metadata values, content-part data) to dCBOR before passing to external consumers.
- MUST validate tool call arguments against declared schemas before invoking the component (Section 6.4).
- MUST validate metadata against the metadata schema if present (Section 6.4).
- MUST implement a language resolution strategy for `localized-string` (Section 5.4). The specific strategy is implementation-defined.
- MUST propagate cancellation to the component. Hosts SHOULD prefer cooperative cancellation (drop the call future during in-flight `call-tool`; drop the stream reader after `call-tool` returns with `streaming`) and MAY escalate to runtime-level interruption (epoch/fuel) for non-yielding components. See Section 4.4.
- MAY ignore any `tool-event` received after a `tool-event::error` within a single `tool-result` (components MUST NOT emit such events; see §10.1).
- MUST ignore unrecognized metadata keys (Section 8.1).
- MUST handle `tool-error` returned by `list-tools` and surface it to the caller through the appropriate transport mechanism (Section 4.2).
- MUST NOT reject `tool-error` values with unrecognized `kind` strings (Section 9.2).

---

## Appendix A: Complete WIT

The normative WIT lives in `wit/act-core.wit` within the `act:core@0.3.0` package. Informative (RFC) interfaces in `wit/act-events.wit` and `wit/act-resources.wit` share the same package namespace; their listings are in `ACT-EVENTS.md` and `ACT-RESOURCES.md`.

**`wit/act-core.wit`** — types, tool-provider, and world.

Component-level metadata (name, version, description, capabilities) is stored in the `act:component` WASM custom section (CBOR-encoded), not as an exported function. See Section 3.2.

```wit
package act:core@0.3.0;

interface types {

  /// A localizable text value.
  ///
  /// - `plain` — an opaque UTF-8 string. If `std.default-language` is declared
  ///   in the `act:component` section, the string is assumed to be in that language.
  ///   Otherwise, the language is undefined.
  /// - `localized` — a list of (BCP 47 language-tag, text) pairs.
  ///   If `std.default-language` is declared, SHOULD include an entry for it.
  variant localized-string {
    plain(string),
    localized(list<tuple<string, string>>),
  }

  /// Key-value metadata. Keys are namespaced strings, values are CBOR-encoded.
  /// Components produce valid CBOR; the host canonicalizes to dCBOR if needed.
  /// Well-known keys use the `std:` prefix (e.g. "std:read-only", "std:timeout-ms").
  /// Third-party keys use their own namespace (e.g. "acme:priority").
  type metadata = list<tuple<string, list<u8>>>;


  // ──────────────────────────────────────────────
  //  Tool-level types
  // ──────────────────────────────────────────────

  /// Full definition of a tool, returned by list-tools.
  record tool-definition {
    name: string,
    description: localized-string,
    /// Parameter schema as a JSON Schema string (default).
    /// Hosts MAY also accept JSON Structure (json-structure.org),
    /// detected via the `$schema` field.
    parameters-schema: string,
    /// Well-known keys: std:read-only, std:idempotent, std:destructive,
    /// std:usage-hints, std:anti-usage-hints, std:examples, std:tags, std:timeout-ms.
    metadata: metadata,
  }


  // ──────────────────────────────────────────────
  //  Call / Result types
  // ──────────────────────────────────────────────

  /// A request to invoke a tool.
  record tool-call {
    /// Tool name, as returned by list-tools.
    name: string,
    /// Deterministically Encoded CBOR arguments (RFC 8949 §4.2).
    /// Validated by the host against parameter schemas before being passed to the component.
    arguments: list<u8>,
    metadata: metadata,
  }

  /// A single piece of content in a tool's result stream.
  record content-part {
    /// Payload bytes. Interpretation depends on `mime-type`:
    /// - `text/*` — raw UTF-8 text
    /// - `application/cbor` — CBOR-encoded structured data
    /// - `application/json` — JSON
    /// - `image/*` — binary image data
    /// - absent or other — opaque bytes (application/octet-stream)
    data: list<u8>,
    /// MIME type of the data. If absent, data is treated as opaque bytes.
    mime-type: option<string>,
    metadata: metadata,
  }

  /// Structured error returned by tools.
  /// Well-known kind values: std:not-found, std:invalid-args, std:timeout,
  /// std:capability-denied, std:internal. Custom kinds use namespaced strings.
  record tool-error {
    kind: string,
    message: localized-string,
    metadata: metadata,
  }

  /// A single event in a tool's result.
  /// A `tool-event::error` is terminal — no further events follow.
  variant tool-event {
    content(content-part),
    error(tool-error),
  }

  /// The result of a tool call.
  ///
  /// Two shapes exist to accommodate different guest capabilities; they are
  /// semantically equivalent. Both carry an ordered sequence of `tool-event`s
  /// with identical terminal-error semantics. Hosts, intermediaries, and callers
  /// MUST treat both variants as equivalent event sequences. Intermediaries MAY
  /// freely convert between variants.
  ///
  /// - `immediate` — event list is materialized when the tool returns.
  /// - `streaming` — events are emitted to a stream as they are produced.
  variant tool-result {
    immediate(list<tool-event>),
    streaming(stream<tool-event>),
  }


  // ──────────────────────────────────────────────
  //  Response wrappers
  // ──────────────────────────────────────────────

  /// Response from list-tools.
  record list-tools-response {
    metadata: metadata,
    tools: list<tool-definition>,
  }
}

/// Component-level metadata (name, version, description, capabilities) is stored
/// in the `act:component` WASM custom section (CBOR-encoded) and standard WASM
/// metadata fields, not as an exported function.

interface tool-provider {
  use types.{
    tool-definition,
    tool-call,
    tool-result,
    list-tools-response,
    tool-error,
    metadata,
  };

  /// Returns a JSON Schema (type "object") describing the metadata keys
  /// this component accepts. Returns `none` if no metadata is required.
  ///
  /// When called with empty metadata, the component MUST return immediately
  /// without performing any network I/O.
  ///
  /// The host MAY call this multiple times with progressively filled
  /// metadata to support iterative schema discovery for bridge components.
  /// Subsequent calls with non-empty metadata MAY perform network I/O
  /// (e.g. fetching a remote component's schema).
  get-metadata-schema: async func(metadata: metadata) -> option<string>;

  /// Returns the list of tools available for the given metadata.
  /// Async because bridge components may need to fetch remote schemas.
  list-tools: async func(metadata: metadata) -> result<list-tools-response, tool-error>;

  /// Invokes a tool. Metadata is carried inside `tool-call.metadata`.
  ///
  /// Returns either `immediate` (bounded, sync-friendly) or `streaming`
  /// (unbounded or incremental). Both carry `tool-event`s with the same
  /// semantics: `tool-event::error` is terminal.
  call-tool: async func(call: tool-call) -> tool-result;
}

world act-world {
  export tool-provider;
}
```

Informative (RFC) interfaces `event-provider` and `resource-provider` are documented in `ACT-EVENTS.md` and `ACT-RESOURCES.md`; their WIT lives in `wit/act-events.wit` and `wit/act-resources.wit`.

---

## Appendix B: Examples (Informative)

### B.1 Simple Component (no metadata)

A calculator component — `get-metadata-schema([])` returns `none`.

**`act:component` custom section (CBOR):**

```cbor
{
  "std": {
    "name": "calculator",
    "version": "1.0.0",
    "default-language": "en",
    "description": "Basic arithmetic tools"
  }
}
```

**call-tool(call) — arguments in CBOR diagnostic notation:**

```
tool-call {
  name: "add",
  arguments: {"a": 2, "b": 3},
  metadata: []
}
```

The host encodes arguments as dCBOR bytes before passing to the component.

### B.2 Bridge Component (with metadata)

An OpenAPI bridge — `get-metadata-schema` returns a schema describing required metadata.

**Iterative discovery:**

```
1. get-metadata-schema([])
   → {
       "type": "object",
       "properties": {
         "act:spec-url": {
           "type": "string",
           "format": "uri",
           "description": "URL of the OpenAPI specification"
         },
         "act:base-url": {
           "type": "string",
           "format": "uri",
           "description": "Base URL for API requests (overrides spec servers)"
         },
         "act:auth-header": {
           "type": "string",
           "description": "Value for the Authorization header"
         }
       },
       "required": ["act:spec-url"]
     }

2. list-tools([("act:spec-url", cbor("https://api.example.com/openapi.json"))])
   → tools derived from the OpenAPI spec
```

### B.3 Chained Bridges (with std:forward)

Host → bridge A → bridge B → component.

```
1. get-metadata-schema([])
   → {
       "properties": {
         "act:remote_url": {"type": "string"},
         "std:forward": {}
       },
       "required": ["act:remote_url"]
     }

2. get-metadata-schema([("act:remote_url", cbor("https://bridge-b.example.com"))])
   → {
       "properties": {
         "act:remote_url": {"type": "string"},
         "std:forward": {
           "type": "object",
           "properties": {
             "act:remote_url": {"type": "string"},
             "std:forward": {
               "type": "object",
               "properties": {"api_key": {"type": "string"}},
               "required": ["api_key"]
             }
           },
           "required": ["act:remote_url"]
         }
       },
       "required": ["act:remote_url"]
     }

3. call-tool({
     name: "fetch",
     arguments: {...},
     metadata: [
       ("act:remote_url", cbor("https://bridge-b.example.com")),
       ("std:forward", cbor({
         "act:remote_url": "https://component.example.com",
         "std:forward": {"api_key": "sk-..."}
       }))
     ]
   })
```

Bridge A extracts `act:remote_url`, decodes `std:forward` as metadata, and passes it to bridge B. Bridge B does the same, passing `{"api_key": "sk-..."}` to the final component.

### B.4 Tool Definition with Metadata

A tool definition using well-known metadata keys (shown as JSON for readability; actual metadata values are CBOR-encoded):

```json
{
  "name": "delete_user",
  "description": [["en", "Delete a user account permanently"]],
  "parameters-schema": {
    "type": "object",
    "properties": {
      "user_id": {
        "type": "string",
        "format": "uuid",
        "description": "The user ID to delete"
      }
    },
    "required": ["user_id"]
  },
  "metadata": [
    ["std:destructive", true],
    ["std:idempotent", true],
    ["std:anti-usage-hints", [["en", "Do not use for deactivation — use deactivate_user instead"]]],
    ["std:timeout-ms", 30000]
  ]
}
```

### B.5 Tool Result

A successful `call-tool` returns a `tool-result`. Bounded, sync-friendly tools use `immediate`:

```
immediate([
  content({ data: "Hello, world!", mime_type: "text/plain", metadata: [] }),
  content({ data: "<additional data>", mime_type: "text/plain", metadata: [] })
])
```

Unbounded or incrementally-produced results use `streaming`, yielding the same `tool-event`s over time:

```
streaming(<stream yielding>
  content({ data: "chunk 1", ... }),
  content({ data: "chunk 2", ... }),
  ...
)
```

Early failure is encoded as a single-error `immediate`:

```
immediate([
  error({ kind: "std:not-found", message: plain("Tool 'foo' not found"), metadata: [] })
])
```

A `streaming` result may also carry an error — the error event is terminal:

```
streaming(<stream yielding>
  error({ kind: "std:not-found", message: "Tool foo does not exist", metadata: [] })
)
```

Either variant may contain content before an error (partial results):

```
immediate([
  content({ data: "partial result...", mime_type: "text/plain", metadata: [] }),
  error({ kind: "std:timeout", message: "Operation timed out", metadata: [] })
])
```

A successful no-output call uses an empty list:

```
immediate([])
```
