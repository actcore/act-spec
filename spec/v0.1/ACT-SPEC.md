# ACT: Agent Component Tools

**Protocol Specification — Version 0.1.2 (Draft)**

---

## 1. Introduction

ACT (Agent Component Tools) is a self-documenting RPC protocol built on top of the WebAssembly Component Model. It defines a standard interface for packaging callable tools as WASM components that can be consumed by AI agents, application developers, and orchestration platforms alike.

A single ACT component is a `.wasm` file that exports a well-known set of interfaces. A host runtime loads the component, inspects its metadata and capabilities, discovers available tools, and invokes them — receiving results as a stream.

### 1.1 Design Goals

- **Universal access** — one component serves both agent-oriented (MCP-compatible) and application-oriented (binary RPC) consumers through transport adapters.
- **Self-documenting** — every tool carries localized descriptions, parameter schemas, usage hints, and behavioral annotations directly in the component.
- **Sandboxed** — WASM isolation provides capability-based security by default. Components cannot access host resources unless explicitly linked.
- **Stateless** — components are stateless functions. Configuration is passed per-call, enabling horizontal scaling and CDN/proxy compatibility.
- **Streaming** — tool results are always delivered as a stream, unifying atomic and incremental result patterns.
- **Efficient** — Deterministically Encoded CBOR for arguments, config, and content data. Native binary support without base64 overhead.
- **Extensible** — every record carries a `metadata` field with namespaced key-value pairs; breaking changes are handled through WIT package versioning.

### 1.2 Relationship to Existing Standards

ACT builds on:
- **WebAssembly Component Model** — for component packaging, linking, and type system.
- **WIT (WebAssembly Interface Types)** — as the sole IDL.
- **WASI Preview 3 (wasip3)** — for async functions, `future`, and `stream` types.
- **JSON Schema** — for dynamic parameter description consumed by agents.
- **CBOR (RFC 8949)** — for binary encoding of arguments, config, and content data. Specifically, Deterministically Encoded CBOR (§4.2).
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
| **Config** | An optional dCBOR-encoded value passed to `list-tools` and `call-tool`, carrying per-call context (credentials, endpoint URLs, etc.). Analogous to HTTP headers. |
| **dCBOR** | Deterministically Encoded CBOR as defined in RFC 8949 §4.2. |
| **Metadata** | A list of key-value pairs (`list<tuple<string, list<u8>>>`) carried by every record type in the protocol. Keys are namespaced strings (`std:` for well-known, vendor prefix for custom). Values are CBOR-encoded. Components produce valid CBOR; the host canonicalizes to dCBOR when needed. |
| **Transport Adapter** | A layer that translates between an external protocol (MCP, HTTP, etc.) and ACT host calls. |
| **Capability** | A host-side resource (network, filesystem, etc.) identified by a URI that a component may require. |
| **Bridge Component** | A component that adapts an external protocol (OpenAPI, MCP, ACP) into the ACT `tool-provider` interface, configured via `config`. |

---

## 3. WIT Specification

### 3.1 Package

```wit
package act:core@0.1.2;
```

### 3.2 Types Interface

```wit
interface types {

  /// A localized string is a list of (language-tag, text) pairs.
  /// Language tags follow BCP 47 (e.g. "en", "ru", "zh-Hans").
  /// Every localized-string MUST include an entry for the component's default language
  /// (declared in component-info.default-language).
  type localized-string = list<tuple<string, string>>;

  /// Key-value metadata. Keys are namespaced strings, values are CBOR-encoded.
  /// Components produce valid CBOR; the host canonicalizes to dCBOR if needed.
  /// Well-known keys use the `std:` prefix (e.g. "std:read-only", "std:timeout-ms").
  /// Third-party keys use their own namespace (e.g. "acme:priority").
  type metadata = list<tuple<string, list<u8>>>;


  // ──────────────────────────────────────────────
  //  Component-level types
  // ──────────────────────────────────────────────

  /// A capability required or optionally used by the component.
  /// The `id` field is a namespaced URI (e.g. "wasi:sockets/tcp", "wasi:filesystem/types").
  record capability {
    id: string,
    description: option<localized-string>,
    metadata: metadata,
  }

  /// Capabilities declared by the component.
  record component-capabilities {
    required: list<capability>,
    optional: list<capability>,
    metadata: metadata,
  }

  /// Top-level metadata about the component. Returned once at load time.
  record component-info {
    name: string,
    version: string,
    /// BCP 47 language tag for the component's default language.
    /// Every localized-string in this component MUST include an entry for this language.
    default-language: string,
    description: localized-string,
    capabilities: component-capabilities,
    metadata: metadata,
  }


  // ──────────────────────────────────────────────
  //  Tool-level types
  // ──────────────────────────────────────────────

  /// Metadata for a single tool parameter.
  record parameter-meta {
    name: string,
    description: localized-string,
    /// JSON Schema describing the parameter type and constraints.
    schema: string,
    required: bool,
    metadata: metadata,
  }

  /// Full definition of a tool, returned by list-tools.
  record tool-definition {
    name: string,
    description: localized-string,
    parameters: list<parameter-meta>,
    /// Well-known keys: std:read-only, std:idempotent, std:destructive,
    /// std:usage-hints, std:anti-usage-hints, std:examples, std:tags, std:timeout-ms.
    metadata: metadata,
  }


  // ──────────────────────────────────────────────
  //  Call / Result types
  // ──────────────────────────────────────────────

  /// A request to invoke a tool.
  record tool-call {
    /// Caller-assigned identifier for correlation.
    id: string,
    /// Tool name, as returned by list-tools.
    name: string,
    /// Deterministically Encoded CBOR arguments (RFC 8949 §4.2).
    /// Validated by the host against parameter schemas before being passed to the component.
    arguments: list<u8>,
    metadata: metadata,
  }

  /// A single piece of content in a tool's result stream.
  record content-part {
    /// Payload bytes. Interpretation depends on `mime-type`.
    data: list<u8>,
    /// MIME type of the data. If absent, defaults to "application/cbor".
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

  /// A single event in the tool result stream.
  variant stream-event {
    content(content-part),
    error(tool-error),
  }


  // ──────────────────────────────────────────────
  //  Response wrappers
  // ──────────────────────────────────────────────

  /// Response from call-tool. Metadata is available for both success and error paths.
  record call-response {
    metadata: metadata,
    body: result<stream<stream-event>, tool-error>,
  }

  /// Response from list-tools.
  record list-tools-response {
    metadata: metadata,
    tools: list<tool-definition>,
  }
}
```

### 3.3 Component Metadata Interface

```wit
interface component-metadata {
  use types.{ component-info };

  /// Returns component-level information.
  /// The host calls this once at load time and caches the result.
  get-info: func() -> component-info;
}
```

### 3.4 Tool Provider Interface

```wit
interface tool-provider {
  use types.{
    tool-definition,
    tool-call,
    call-response,
    list-tools-response,
    tool-error,
  };

  /// Returns JSON Schema describing the configuration this component accepts.
  /// Returns `none` if the component does not require configuration.
  get-config-schema: func() -> option<string>;

  /// Returns the list of tools available for the given configuration.
  /// `config` is dCBOR validated against the schema from `get-config-schema`.
  list-tools: func(config: option<list<u8>>) -> result<list-tools-response, tool-error>;

  /// Invokes a tool and returns a response with metadata and a stream of results.
  /// Metadata is available regardless of whether the call succeeds or fails.
  call-tool: async func(config: option<list<u8>>, call: tool-call) -> call-response;
}
```

### 3.5 World

```wit
world act-world {
  export component-metadata;
  export tool-provider;
}
```

---

## 4. Component Lifecycle

### 4.1 Loading

1. The host loads the `.wasm` component binary.
2. The host links WASI and other imports according to its capability policy.
3. The host calls `component-metadata.get-info()` to obtain component metadata, including declared capabilities.
4. The host calls `tool-provider.get-config-schema()` to determine whether the component requires configuration.
5. The component is now ready to accept calls.

If the component imports a WASI interface that the host did not link, the component will trap at the point of use. The host MAY inspect `component-capabilities` from `get-info()` to make linking decisions proactively, but this is not required.

### 4.2 Tool Discovery

1. The host (or transport adapter) calls `list-tools(config)`.
2. The component returns a `list-tools-response` containing response-level metadata and a list of `tool-definition` records.
3. The host SHOULD cache the result for a given config value unless the component indicates dynamism through metadata.

For components without configuration (`get-config-schema` returns `none`), the host calls `list-tools(none)` and MAY cache the result for the lifetime of the component instance.

### 4.3 Tool Invocation

1. The caller constructs a `tool-call` with a unique `id`, tool `name`, and dCBOR `arguments`.
2. The host MUST validate `arguments` (after decoding from CBOR) against the JSON Schema declared in `parameter-meta` for the named tool. If validation fails, the host MUST return a `tool-error` with kind `std:invalid-args` without calling the component.
3. The host MUST validate `config` against the schema from `get-config-schema` if present. If the component requires config and `none` is provided, or if the config does not match the schema, the host MUST return a `tool-error` with kind `std:invalid-args`.
4. The host MUST ensure `arguments` and `config` are deterministically encoded before passing them to the component.
5. The host calls `call-tool(config, call)`.
6. The host receives a `call-response` with response-level `metadata` and a `body` result. On success, the host reads `stream-event` values from the stream in `body`:
   - `content(part)` — a piece of result content. There may be zero or more.
   - `error(e)` — a terminal error. The stream ends after this event.
7. When the stream completes without an `error` event, the call is considered successful.

### 4.4 Cancellation

1. The host drops the stream handle returned by `call-tool`.
2. The wasmtime runtime propagates cancellation to the component's async context.
3. The component SHOULD release resources promptly upon receiving cancellation.
4. The host is NOT required to wait for the component to acknowledge cancellation.
5. Any `content-part` events delivered before cancellation are considered valid and delivered.

### 4.5 Config as Context

Config serves the same role as HTTP headers: it carries per-call context (authentication, endpoint URLs, preferences) that is orthogonal to tool arguments.

- **Arguments** describe _what_ to do (the request body).
- **Config** describes _where_ and _as whom_ (the request context).

Transport adapters map config to the natural mechanism for each transport:

| Transport | Config mechanism |
|-----------|-----------------|
| HTTP | Headers (e.g. `X-ACT-Config`) or derived from session state |
| MCP stdio | Process environment or host configuration |
| MCP SSE | Extensions in `initialize` request |

The host MAY merge config from multiple sources (e.g. server defaults + client-provided values) before passing it to the component.

---

## 5. Localization

### 5.1 Default Language

Each component declares a default language in `component-info.default-language` (a BCP 47 tag). This is the language the component author writes in natively.

Every `localized-string` value produced by the component MUST include an entry matching `default-language`. This guarantees that at least one localization is always present for every string.

### 5.2 Localized Strings

All human-readable text intended for agents or end users is represented as `localized-string` — a list of `(language-tag, text)` tuples.

- Every `localized-string` MUST include an entry for the component's `default-language`.
- Components MAY provide additional entries for any number of languages.
- Language tags MUST conform to BCP 47.

### 5.3 Host Resolution

When a transport adapter needs a single-language string (e.g. for an MCP response):

1. Match the client's preferred language exactly.
2. Match by prefix (e.g. `"zh"` matches `"zh-Hans"`).
3. Fall back to the component's `default-language`.
4. Fall back to `"en"` (host MAY implement this as a hardcoded fallback).
5. Fall back to the first available entry.

The component is not involved in language selection — it returns all available localizations, and the host or adapter chooses.

---

## 6. Data Encoding

### 6.1 Deterministically Encoded CBOR

Tool arguments and config are encoded as Deterministically Encoded CBOR (RFC 8949 §4.2). This provides:

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

Each parameter in `tool-definition.parameters` carries a `schema` field containing a JSON Schema string. The schema describes the type, constraints, and structure of the parameter value.

JSON Schema remains the schema language because JSON and CBOR share nearly identical data models (maps, arrays, strings, numbers, booleans, null). The host validates arguments against JSON Schema after decoding from CBOR to a generic value.

The top-level `arguments` field of `tool-call` is a dCBOR map where keys correspond to parameter names.

### 6.4 Host-Side Validation

The host MUST validate tool call arguments and config before passing them to the component:

1. Decode CBOR to a generic value.
2. Validate against the declared JSON Schema.
3. Re-encode as dCBOR (if the input was not already deterministically encoded).
4. Pass to the component.

This guarantees that:
- Components never receive malformed input.
- Validation errors are surfaced early with `tool-error` kind `std:invalid-args`.
- Components do not spend WASM cycles on input validation.

### 6.5 Content Data

The `content-part.data` field is `list<u8>` — raw bytes. The `mime-type` field determines how to interpret them. If `mime-type` is absent, it defaults to `"application/cbor"` — structured data encoded as CBOR. Components produce valid CBOR; the host canonicalizes to dCBOR before passing to external consumers.

Common MIME types:

| MIME type | `data` encoding |
|-----------|-----------------|
| `application/cbor` | CBOR-encoded structured data (default); host canonicalizes to dCBOR |
| `text/plain` | UTF-8 encoded text |
| `text/markdown` | UTF-8 encoded Markdown |
| `image/png` | Raw PNG bytes |
| `audio/wav` | Raw WAV bytes |

No base64 encoding is needed — binary data is passed directly as bytes.

Hosts that do not recognize a MIME type SHOULD pass the content through to the client unmodified.

### 6.6 SDK Generation

Language-specific SDKs SHOULD generate JSON Schema from native type signatures automatically. The developer writes typed functions; the SDK produces the `parameter-meta` records. SDKs SHOULD handle CBOR encoding/decoding transparently — the developer works with native types.

---

## 7. Capabilities

### 7.1 Capability Model

Capabilities represent host-side resources that a component may need. They are identified by namespaced URI strings.

A component declares its capabilities through the `component-capabilities` record returned by `get-info()`. This declaration is informational — the host uses it to make linking decisions and to communicate capability requirements to clients (agents, UIs).

### 7.2 Declaration

The component MUST declare the capabilities it requires in `component-capabilities.required` and those it can function without in `component-capabilities.optional`.

Language SDKs SHOULD populate this declaration automatically from the component's `world` definition.

### 7.3 Enforcement

The host links (or refuses to link) WASI imports based on its capability policy:

- **Strict mode** — the host refuses to load a component if any required capability is not permitted by policy.
- **Permissive mode** — the host links all available capabilities regardless of declaration.

If a component invokes an import that was not linked, the call will trap. The capability declaration helps prevent this by allowing the host to reject incompatible components early.

### 7.4 Well-Known Capability Identifiers

The following identifiers are defined by this specification. Hosts SHOULD recognize them:

| Capability ID | Description |
|--------------|-------------|
| `wasi:sockets/tcp` | Outbound TCP connections |
| `wasi:sockets/udp` | Outbound UDP datagrams |
| `wasi:http/outgoing-handler` | Outbound HTTP requests |
| `wasi:filesystem/types` | Filesystem access |
| `wasi:threads` | Thread spawning |

Additional capability identifiers MAY be defined by third parties using their own namespace (e.g. `acme:gpu/compute`). Hosts that do not recognize a capability identifier SHOULD treat it according to their enforcement mode.

---

## 8. Extensibility

### 8.1 Metadata Fields

Every record type in this specification includes a `metadata` field of type `list<tuple<string, list<u8>>>`. This field carries namespaced key-value pairs for well-known annotations and vendor-specific data. Values are CBOR-encoded. Components produce valid CBOR; the host canonicalizes to dCBOR when passing data to external consumers.

- Well-known keys use the `std:` prefix (e.g. `"std:read-only"`, `"std:timeout-ms"`).
- Third-party keys use their own namespace (e.g. `"acme:priority"`).
- Hosts and components MUST ignore unrecognized metadata keys.
- Metadata MUST NOT change the semantics of any standard field.

### 8.2 Well-Known Metadata Keys

The following well-known keys are defined for `tool-definition.metadata`. All values are CBOR-encoded.

| Key | CBOR type | Description |
|-----|-----------|-------------|
| `std:read-only` | bool | Tool does not modify state. |
| `std:idempotent` | bool | Repeated calls with same arguments produce the same result. |
| `std:destructive` | bool | Tool may irreversibly modify state. |
| `std:usage-hints` | localized-string | When to use this tool. |
| `std:anti-usage-hints` | localized-string | When NOT to use this tool. |
| `std:examples` | array of bstr | Example tool calls as CBOR-encoded argument maps. |
| `std:tags` | array of tstr | Categorization tags. |
| `std:timeout-ms` | uint | Suggested timeout in milliseconds. The host MAY override this. |

Response metadata (`call-response.metadata`, `list-tools-response.metadata`) has no well-known keys defined in this version. Hosts and components MAY define their own (e.g. `std:request-id`, `acme:cache-ttl-ms`).

Hosts MUST NOT reject metadata entries with unrecognized keys. Components MUST NOT require specific response metadata keys to be present.

### 8.3 Versioning

Breaking changes to the WIT interfaces are handled through WIT package versioning:

```
act:core@0.1.0  ->  act:core@0.1.1  ->  act:core@0.1.2  ->  act:core@1.0.0
```

A host MAY support multiple interface versions simultaneously. A component declares which version it implements through its WIT world.

---

## 9. Error Handling

### 9.1 Two-Level Error Model

Errors are surfaced at two levels:

**Level 1 — Early errors (before streaming begins):**

`call-response.body` is `result<stream<stream-event>, tool-error>`. If it is `Err`, the stream was never opened. The response-level `metadata` is still available. This covers:
- Tool not found (`std:not-found`)
- Argument validation failure (`std:invalid-args`)
- Config validation failure (`std:invalid-args`)
- Capability denied (`std:capability-denied`)

**Level 2 — Stream errors (during execution):**

A `stream-event::error(tool-error)` event may appear at any point in the stream. It is terminal — the stream ends after this event. This covers:
- Timeouts (`std:timeout`)
- Internal failures (`std:internal`)
- Any error that occurs after execution has begun

### 9.2 Error Kind Semantics

The `tool-error.kind` field is a string. Well-known values use the `std:` prefix. Custom error kinds use their own namespace (e.g. `"acme:rate-limited"`).

| Kind | Source | Description |
|------|--------|-------------|
| `std:not-found` | Host or Component | The named tool does not exist. |
| `std:invalid-args` | Host | Arguments or config failed schema validation. |
| `std:timeout` | Host | The call exceeded the declared or host-configured timeout. |
| `std:capability-denied` | Host | The component attempted to use a capability that was not granted. |
| `std:internal` | Component | An unrecoverable error within the component. |

---

## 10. Conformance

### 10.1 Conformant Component

A conformant ACT component:
- MUST export the `act-world` world as defined in Section 3.5.
- MUST return valid `component-info` from `get-info()`, including a valid BCP 47 `default-language`.
- MUST include the `default-language` entry in every `localized-string` it produces.
- MUST return valid `tool-definition` records from `list-tools()`.
- MUST accept any `tool-call` whose `arguments` conform to the declared schemas (encoded as dCBOR).
- MUST produce a well-formed `stream<stream-event>` from `call-tool()`.
- MUST return a valid JSON Schema from `get-config-schema()` if configuration is required, or `none` if not.
- MUST accept `none` as config in `list-tools` and `call-tool` if `get-config-schema` returns `none`.
- MUST produce valid CBOR in all output (metadata values, content-part data) but is NOT required to produce deterministic CBOR. The host canonicalizes.
- Is NOT required to verify deterministic CBOR encoding of incoming data but MUST support the deterministic subset.

### 10.2 Conformant Host

A conformant ACT host:
- MUST encode arguments and config as dCBOR before passing them to the component (Section 6.2).
- MUST canonicalize CBOR produced by components (metadata values, content-part data) to dCBOR before passing to external consumers.
- MUST validate tool call arguments against declared schemas before invoking the component (Section 6.4).
- MUST validate config against the config schema if present (Section 6.4).
- MUST support the `localized-string` fallback resolution order (Section 5.3).
- MUST propagate cancellation by dropping the stream handle (Section 4.4).
- MUST ignore unrecognized metadata keys (Section 8.1).

---

## Appendix A: Complete WIT

The complete WIT package as a single file:

```wit
package act:core@0.1.2;

interface types {

  /// A localized string is a list of (language-tag, text) pairs.
  /// Language tags follow BCP 47 (e.g. "en", "ru", "zh-Hans").
  /// Every localized-string MUST include an entry for the component's default language
  /// (declared in component-info.default-language).
  type localized-string = list<tuple<string, string>>;

  /// Key-value metadata. Keys are namespaced strings, values are CBOR-encoded.
  /// Components produce valid CBOR; the host canonicalizes to dCBOR if needed.
  /// Well-known keys use the `std:` prefix (e.g. "std:read-only", "std:timeout-ms").
  /// Third-party keys use their own namespace (e.g. "acme:priority").
  type metadata = list<tuple<string, list<u8>>>;


  // ──────────────────────────────────────────────
  //  Component-level types
  // ──────────────────────────────────────────────

  /// A capability required or optionally used by the component.
  /// The `id` field is a namespaced URI (e.g. "wasi:sockets/tcp", "wasi:filesystem/types").
  record capability {
    id: string,
    description: option<localized-string>,
    metadata: metadata,
  }

  /// Capabilities declared by the component.
  record component-capabilities {
    required: list<capability>,
    optional: list<capability>,
    metadata: metadata,
  }

  /// Top-level metadata about the component. Returned once at load time.
  record component-info {
    name: string,
    version: string,
    /// BCP 47 language tag for the component's default language.
    /// Every localized-string in this component MUST include an entry for this language.
    default-language: string,
    description: localized-string,
    capabilities: component-capabilities,
    metadata: metadata,
  }


  // ──────────────────────────────────────────────
  //  Tool-level types
  // ──────────────────────────────────────────────

  /// Metadata for a single tool parameter.
  record parameter-meta {
    name: string,
    description: localized-string,
    /// JSON Schema describing the parameter type and constraints.
    schema: string,
    required: bool,
    metadata: metadata,
  }

  /// Full definition of a tool, returned by list-tools.
  record tool-definition {
    name: string,
    description: localized-string,
    parameters: list<parameter-meta>,
    /// Well-known keys: std:read-only, std:idempotent, std:destructive,
    /// std:usage-hints, std:anti-usage-hints, std:examples, std:tags, std:timeout-ms.
    metadata: metadata,
  }


  // ──────────────────────────────────────────────
  //  Call / Result types
  // ──────────────────────────────────────────────

  /// A request to invoke a tool.
  record tool-call {
    /// Caller-assigned identifier for correlation.
    id: string,
    /// Tool name, as returned by list-tools.
    name: string,
    /// Deterministically Encoded CBOR arguments (RFC 8949 §4.2).
    /// Validated by the host against parameter schemas before being passed to the component.
    arguments: list<u8>,
    metadata: metadata,
  }

  /// A single piece of content in a tool's result stream.
  record content-part {
    /// Payload bytes. Interpretation depends on `mime-type`.
    data: list<u8>,
    /// MIME type of the data. If absent, defaults to "application/cbor".
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

  /// A single event in the tool result stream.
  variant stream-event {
    content(content-part),
    error(tool-error),
  }


  // ──────────────────────────────────────────────
  //  Response wrappers
  // ──────────────────────────────────────────────

  /// Response from call-tool. Metadata is available for both success and error paths.
  record call-response {
    metadata: metadata,
    body: result<stream<stream-event>, tool-error>,
  }

  /// Response from list-tools.
  record list-tools-response {
    metadata: metadata,
    tools: list<tool-definition>,
  }
}

interface component-metadata {
  use types.{ component-info };

  /// Returns component-level information.
  /// The host calls this once at load time and caches the result.
  get-info: func() -> component-info;
}

interface tool-provider {
  use types.{
    tool-definition,
    tool-call,
    call-response,
    list-tools-response,
    tool-error,
  };

  /// Returns JSON Schema describing the configuration this component accepts.
  /// Returns `none` if the component does not require configuration.
  get-config-schema: func() -> option<string>;

  /// Returns the list of tools available for the given configuration.
  /// `config` is dCBOR validated against the schema from `get-config-schema`.
  list-tools: func(config: option<list<u8>>) -> result<list-tools-response, tool-error>;

  /// Invokes a tool and returns a response with metadata and a stream of results.
  /// Metadata is available regardless of whether the call succeeds or fails.
  call-tool: async func(config: option<list<u8>>, call: tool-call) -> call-response;
}

world act-world {
  export component-metadata;
  export tool-provider;
}
```

---

## Appendix B: Example (Informative)

### B.1 Simple Component (no config)

A calculator component — `get-config-schema()` returns `none`.

**component-info:**

```json
{
  "name": "calculator",
  "version": "1.0.0",
  "default_language": "en",
  "description": [["en", "Basic arithmetic tools"]],
  "capabilities": {
    "required": [],
    "optional": [],
    "metadata": []
  },
  "metadata": []
}
```

**call-tool(none, call) — arguments in CBOR diagnostic notation:**

```
{"a": 2, "b": 3}
```

The host encodes this as dCBOR bytes before passing to the component.

### B.2 Bridge Component (with config)

An OpenAPI bridge — `get-config-schema()` returns a schema.

**get-config-schema():**

```json
{
  "type": "object",
  "properties": {
    "spec-url": {
      "type": "string",
      "format": "uri",
      "description": "URL of the OpenAPI specification"
    },
    "base-url": {
      "type": "string",
      "format": "uri",
      "description": "Base URL for API requests (overrides spec servers)"
    },
    "auth-header": {
      "type": "string",
      "description": "Value for the Authorization header"
    }
  },
  "required": ["spec-url"]
}
```

**Config in CBOR diagnostic notation:**

```
{"spec-url": "https://api.example.com/openapi.json"}
```

**list-tools(config) returns tools derived from the OpenAPI spec.** Tool definitions use JSON Schema in `parameter-meta.schema` as before — schemas are always JSON strings regardless of the CBOR encoding of runtime values.

### B.3 Tool Definition with Metadata

A tool definition using well-known metadata keys (shown as JSON for readability; actual metadata values are CBOR-encoded):

```json
{
  "name": "delete_user",
  "description": [["en", "Delete a user account permanently"]],
  "parameters": [
    {
      "name": "user_id",
      "description": [["en", "The user ID to delete"]],
      "schema": "{\"type\": \"string\", \"format\": \"uuid\"}",
      "required": true,
      "metadata": []
    }
  ],
  "metadata": [
    ["std:destructive", true],
    ["std:idempotent", true],
    ["std:anti-usage-hints", [["en", "Do not use for deactivation — use deactivate_user instead"]]],
    ["std:timeout-ms", 30000]
  ]
}
```

### B.4 Call Response

A successful `call-response` (shown as JSON for readability):

```json
{
  "metadata": [
    ["acme:request-id", "req-abc-123"]
  ],
  "body": {
    "ok": "<stream of stream-events>"
  }
}
```

An early error `call-response` — metadata is still available:

```json
{
  "metadata": [
    ["acme:request-id", "req-abc-456"]
  ],
  "body": {
    "err": {
      "kind": "std:not-found",
      "message": [["en", "Tool 'foo' does not exist"]],
      "metadata": []
    }
  }
}
