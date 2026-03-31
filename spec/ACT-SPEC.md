# ACT: Agent Component Tools

**Protocol Specification — Version 0.2.0 (Draft)**

---

## 1. Introduction

ACT (Agent Component Tools) is a self-documenting RPC protocol built on top of the WebAssembly Component Model. It defines a standard interface for packaging callable tools as WASM components that can be consumed by AI agents, application developers, and orchestration platforms alike.

A single ACT component is a `.wasm` file that exports a well-known set of interfaces. A host runtime loads the component, inspects its metadata and capabilities, discovers available tools, and invokes them — receiving results as a stream.

### 1.1 Design Goals

- **Universal access** — one component serves both agent-oriented (MCP-compatible) and application-oriented (binary RPC) consumers through transport adapters.
- **Self-documenting** — every tool carries localized descriptions, parameter schemas, usage hints, and behavioral annotations directly in the component.
- **Sandboxed** — WASM isolation provides capability-based security by default. Components cannot access host resources unless explicitly linked.
- **Stateless protocol** — metadata is passed per-call, enabling horizontal scaling and CDN/proxy compatibility. Components MAY maintain internal state (caches, connection pools) as a private optimization, but the protocol does not manage or expose it.
- **Streaming** — tool results are always delivered as a stream, unifying atomic and incremental result patterns.
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
package act:core@0.2.0;
```

### 3.2 Component Info (Custom Section)

Component-level metadata is stored in the WASM binary as a custom section named `act:component`, not as an exported function. This allows hosts, registries, and tooling to read component information without instantiating the component or executing any code.

The custom section contains a CBOR-encoded map. Keys are namespaced strings — well-known keys use the `std:` prefix, third-party keys use their own namespace (e.g. `acme:priority`). Values are CBOR-encoded.

**Well-known keys:**

| Key | CBOR type | Required | Description |
|-----|-----------|----------|-------------|
| `std:default-language` | tstr | MAY | BCP 47 language tag for the component's default language. If absent, `plain` strings have no declared language. |
| `std:description` | tstr or map | MAY | Localized description. Plain string or `{"en": "...", "ru": "..."}` map. |
| `std:capabilities` | map | MAY | Map of capability declarations keyed by capability identifier. Presence of a key declares that the component uses this capability. The value is an object with capability-specific parameters (may be empty). See Section 7. |

The standard WASM metadata fields `name` and `version` (set via `wasm-tools metadata add` or equivalent) provide the component's name and version. These MUST be present.

Custom keys follow the same namespacing convention as metadata elsewhere in the protocol. Hosts and tooling MUST ignore unrecognized keys.

**Example (CBOR diagnostic notation):**

```cbor
{
  "std:default-language": "en",
  "std:description": "Weather data tools",
  "std:capabilities": {
    "wasi:http": {}
  },
}
```

**Tooling:**
- SDK (`#[act_component]`) generates the custom section automatically at compile time.
- Non-SDK authors use `wasm-tools metadata add` for name/version and a CLI tool (e.g. `act component-info set`) to write the `act:component` section.

### 3.3 Types Interface

```wit
interface types {

  /// A localizable text value.
  ///
  /// - `plain` — an opaque UTF-8 string. If `std:default-language` is declared
  ///   in the `act:component` section, the string is assumed to be in that language.
  ///   Otherwise, the language is undefined.
  /// - `localized` — a list of (BCP 47 language-tag, text) pairs.
  ///   If `std:default-language` is declared, SHOULD include an entry for it.
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
    /// std:usage-hints, std:anti-usage-hints, std:examples, std:tags, std:timeout-ms,
    /// std:streaming.
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

  /// A single event in the tool result stream.
  /// A `stream-event::error` is terminal — the stream closes after it.
  variant stream-event {
    content(content-part),
    error(tool-error),
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
    stream-event,
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

  /// Invokes a tool and returns a stream of results.
  /// Metadata is carried inside `tool-call.metadata`.
  /// Each stream-event is either content or a terminal error.
  call-tool: async func(call: tool-call) -> stream<stream-event>;
}
```

### 3.5 World

```wit
world act-world {
  export tool-provider;
}
```

Components MAY additionally export `event-provider` (Section 3.6) and/or `resource-provider` (Section 3.7). The host detects available interfaces at load time.

### 3.6 Event Provider Interface (Optional)

Components that emit events export the `event-provider` interface (defined in `act-events.wit`, part of the `act:core@0.2.0` package):

```wit
interface event-types {
  use types.{localized-string, metadata};

  record event-type-info {
    kind: string,
    description: localized-string,
    metadata: metadata,
  }

  record event {
    kind: string,
    data: option<list<u8>>,
    metadata: metadata,
  }
}

interface event-provider {
  use event-types.{event-type-info, event};
  use types.{metadata};

  get-event-types: func() -> list<event-type-info>;
  subscribe: async func(metadata: metadata) -> stream<event>;
}
```

- `get-event-types` returns the list of event kinds the component can emit. The host calls this at load time and MAY cache the result.
- `subscribe` opens a stream of events. The host reads events as they arrive. The stream stays open until the component closes it or the host drops the handle (cancellation).
- `metadata` follows the same pattern as `list-tools` and `call-tool` — bridge components may need credentials for external event sources.

### 3.7 Resource Provider Interface (Optional)

Components that provide resources export the `resource-provider` interface (defined in `act-resources.wit`, part of the `act:core@0.2.0` package):

```wit
interface resource-types {
  use types.{localized-string, metadata};

  record resource-info {
    uri: string,
    mime-type: option<string>,
    description: localized-string,
    metadata: metadata,
  }

  record resource-response {
    mime-type: option<string>,
    metadata: metadata,
    body: stream<u8>,
  }
}

interface resource-provider {
  use resource-types.{resource-info, resource-response};
  use types.{metadata};

  list-resources: async func(metadata: metadata) -> list<resource-info>;
  get-resource: async func(metadata: metadata, uri: string) -> resource-response;
}
```

- `list-resources` returns the list of available resources with URIs, MIME types, and descriptions.
- `get-resource` returns a `resource-response` with the actual MIME type, metadata, and a byte stream body. The MIME type MAY differ from the one declared in `resource-info` (content negotiation).
- Well-known URI: `std:icon` — component icon (PNG or SVG).

---

## 4. Component Lifecycle

### 4.1 Loading

1. The host loads the `.wasm` component binary.
2. The host reads the `act:component` custom section (CBOR-encoded) and standard WASM metadata (`name`, `version`) to obtain component information. If the `act:component` section is absent, the host MUST reject the component.
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
6. The host receives a `stream<stream-event>` and reads events from it:
   - `content(part)` — a piece of result content. There may be zero or more.
   - `error(e)` — a terminal error. The stream ends after this event.
7. When the stream completes without an `error` event, the call is considered successful.
8. If the error occurs before execution begins (e.g. tool not found, capability denied), the component returns a stream with a single `error` event.

### 4.4 Cancellation

1. The host drops the stream handle returned by `call-tool`.
2. The wasmtime runtime propagates cancellation to the component's async context.
3. The component SHOULD release resources promptly upon receiving cancellation.
4. The host is NOT required to wait for the component to acknowledge cancellation.
5. Any `content-part` events delivered before cancellation are considered valid and delivered.

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

### 4.6 Event Subscription

If the component exports `event-provider`:

1. The host calls `get-event-types()` at load time to discover available event kinds.
2. The host calls `subscribe(metadata)` to open an event stream.
3. The host reads `event` values from the stream. Each event has a `kind` (matching a declared event kind), optional `data` (dCBOR payload), and `metadata`.
4. The stream stays open until the component closes it or the host drops the handle.
5. If the host drops the handle, the component SHOULD release resources promptly.

### 4.7 Resource Access

If the component exports `resource-provider`:

1. The host calls `list-resources(metadata)` to discover available resources.
2. The host calls `get-resource(metadata, uri)` to retrieve a specific resource.
3. The host reads the byte stream from `resource-response.body`.
4. The host uses `resource-response.mime-type` (or falls back to `resource-info.mime-type`) to determine the content type.

---

## 5. Localization

### 5.1 Default Language

A component MAY declare a default language via `std:default-language` in the `act:component` custom section (a BCP 47 tag). This is the language the component author writes in natively.

If `std:default-language` is not declared, `plain` strings have no declared language and the host treats them as opaque UTF-8 text.

### 5.2 Localized Strings

The `localized-string` type is a variant with two cases:

- **`plain(string)`** — an opaque UTF-8 string. If `std:default-language` is declared, the string is assumed to be in that language. Otherwise, the language is undefined.
- **`localized(list<tuple<string, string>>)`** — a list of `(language-tag, text)` pairs. If `std:default-language` is declared, the component SHOULD include an entry for it.

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

Hosts and SDKs MUST handle both forms: a bare text string is `plain`, a map of strings is `localized`. This applies to the `act:component` custom section (`std:description`), metadata values containing localized strings, and any external CBOR/JSON representation.

### 5.4 Host Resolution

When a transport adapter needs a single-language string (e.g. for an MCP response), the resolution strategy is implementation-defined. Hosts SHOULD use `Accept-Language` or equivalent mechanisms to select the best match.

For `plain(text)`:
1. Use `text` directly.

For `localized(entries)`:
1. Select the best match using the host's language resolution strategy (e.g. `Accept-Language` matching).
2. If no match is found, fall back to `std:default-language` (if declared), then to the first available entry.

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

A component declares its capabilities through the `std:capabilities` map in the `act:component` custom section. The host uses this declaration to make linking decisions and to communicate capability requirements to clients (agents, UIs).

### 7.2 Declaration

The component declares each capability by adding its identifier as a key in the `std:capabilities` map. The value is an object containing capability-specific parameters; an empty object `{}` means the capability is used without specific restrictions. If a capability identifier is absent from the map, the component does not use that capability.

Within a declared capability, an absent parameter means the parameter is unrestricted (the host uses its default).

Language SDKs SHOULD populate this declaration automatically from the component's `world` definition.

### 7.3 Enforcement

The host links (or refuses to link) WASI imports based on its capability policy:

- **Strict mode** — the host refuses to load a component if any declared capability is not permitted by policy.
- **Permissive mode** — the host links all available capabilities regardless of declaration.

If a component invokes an import that was not linked, the call will trap. The capability declaration helps prevent this by allowing the host to reject incompatible components early.

### 7.4 Well-Known Capability Identifiers

The following identifiers are defined by this specification. Hosts SHOULD recognize them:

| Capability ID | Parameters | Description |
|--------------|------------|-------------|
| `wasi:http` | _(none yet)_ | Outbound HTTP requests. |
| `wasi:filesystem` | `mount-root` (string) | Filesystem access. `mount-root` sets the internal WASM root path for all host mounts (default: `/`). |
| `wasi:sockets` | _(none yet)_ | Outbound TCP and UDP connections. |

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

For the complete list of well-known `std:` constants — including tool definition metadata, content part metadata, cross-cutting metadata, bridge metadata, event kinds, and resource URIs — see `ACT-CONSTANTS.md`.

Commonly used tool definition metadata keys include `std:read-only`, `std:idempotent`, `std:destructive`, `std:streaming`, and `std:timeout-ms`. All metadata values are CBOR-encoded.

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
act:core@0.1.0  ->  ...  ->  act:core@0.1.6  ->  act:core@0.2.0
```

A host MAY support multiple interface versions simultaneously. A component declares which version it implements through its WIT world.

---

## 9. Error Handling

### 9.1 Stream Error Model

All errors from `call-tool` are delivered as `stream-event::error(tool-error)` events in the result stream. A `stream-event::error` is terminal — the stream MUST close after it. There is no separate early-error path; errors that occur before execution begins (e.g. tool not found, capability denied) are returned as a stream with a single `error` event.

Content parts delivered before an `error` event are valid and SHOULD be delivered to the caller.

### 9.2 Error Kind Semantics

The `tool-error.kind` field is a string. Well-known values use the `std:` prefix. Custom error kinds use their own namespace (e.g. `"acme:rate-limited"`).

For the complete list of well-known error kinds, see `ACT-CONSTANTS.md` Section 8. Commonly used error kinds include `std:not-found`, `std:invalid-args`, `std:timeout`, `std:capability-denied`, and `std:internal`.

Hosts MUST NOT reject `tool-error` values with unrecognized `kind` strings. Unknown error kinds SHOULD be treated as equivalent to `std:internal` for transport error code mapping purposes.

---

## 10. Conformance

### 10.1 Conformant Component

A conformant ACT component:
- MUST export the `act-world` world as defined in Section 3.5.
- MUST include standard WASM metadata fields `name` and `version`.
- MUST include an `act:component` custom section with a valid CBOR-encoded map (Section 3.2).
- If `std:default-language` is declared, SHOULD include an entry for it in every `localized-string::localized` it produces.
- MUST return valid `tool-definition` records from `list-tools()`.
- MUST accept any `tool-call` whose `arguments` conform to the declared schemas (encoded as dCBOR).
- MUST produce a well-formed `stream<stream-event>` from `call-tool()`. The stream is returned directly — there is no response wrapper.
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
- MUST propagate cancellation by dropping the stream handle (Section 4.4).
- MUST ignore unrecognized metadata keys (Section 8.1).
- MUST handle `tool-error` returned by `list-tools` and surface it to the caller through the appropriate transport mechanism (Section 4.2).
- MUST NOT reject `tool-error` values with unrecognized `kind` strings (Section 9.2).

---

## Appendix A: Complete WIT

The WIT is split across three files in a single package `act:core@0.2.0`. All interfaces share the same package namespace.

**`wit/act-core.wit`** — types, tool-provider, and world.

Component-level metadata (name, version, description, capabilities) is stored in the `act:component` WASM custom section (CBOR-encoded) and standard WASM metadata fields, not as an exported function. See Section 3.2.

```wit
package act:core@0.2.0;

interface types {

  /// A localizable text value.
  ///
  /// - `plain` — an opaque UTF-8 string. If `std:default-language` is declared
  ///   in the `act:component` section, the string is assumed to be in that language.
  ///   Otherwise, the language is undefined.
  /// - `localized` — a list of (BCP 47 language-tag, text) pairs.
  ///   If `std:default-language` is declared, SHOULD include an entry for it.
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
    /// std:usage-hints, std:anti-usage-hints, std:examples, std:tags, std:timeout-ms,
    /// std:streaming.
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

  /// A single event in the tool result stream.
  /// A `stream-event::error` is terminal — the stream closes after it.
  variant stream-event {
    content(content-part),
    error(tool-error),
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
    stream-event,
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

  /// Invokes a tool and returns a stream of results.
  /// Metadata is carried inside `tool-call.metadata`.
  /// Each stream-event is either content or a terminal error.
  call-tool: async func(call: tool-call) -> stream<stream-event>;
}

world act-world {
  export tool-provider;
  /// Optional: export event-provider for push notifications.
  /// Optional: export resource-provider for static/dynamic resources.
}
```

**`wit/act-events.wit`** — event types and event-provider interface:

```wit
package act:core@0.2.0;

interface event-types {
  use types.{localized-string, metadata};

  /// Describes a type of event the component can emit.
  record event-type-info {
    /// Event kind identifier. Well-known: "std:tools:changed",
    /// "std:resources:changed", "std:events:changed".
    /// Custom kinds use namespace prefix (e.g. "acme:order_updated").
    kind: string,
    description: localized-string,
    metadata: metadata,
  }

  /// A single event emitted by the component.
  record event {
    /// Event kind, matching one of the kinds from get-event-types.
    kind: string,
    /// Optional dCBOR-encoded payload.
    data: option<list<u8>>,
    metadata: metadata,
  }
}

interface event-provider {
  use event-types.{event-type-info, event};
  use types.{metadata};

  /// Returns the list of event types this component can emit.
  /// The host calls this at load time and MAY cache the result.
  get-event-types: func() -> list<event-type-info>;

  /// Opens a stream of events. The host reads events as they arrive.
  /// The stream stays open until the component closes it or the host drops the handle.
  subscribe: async func(metadata: metadata) -> stream<event>;
}
```

**`wit/act-resources.wit`** — resource types and resource-provider interface:

```wit
package act:core@0.2.0;

interface resource-types {
  use types.{localized-string, metadata};

  /// Describes a resource available from the component.
  record resource-info {
    /// Resource URI. Well-known: "std:icon".
    uri: string,
    /// Expected MIME type of the resource.
    mime-type: option<string>,
    description: localized-string,
    metadata: metadata,
  }

  /// Response from get-resource.
  record resource-response {
    /// Actual MIME type (may differ from resource-info listing).
    mime-type: option<string>,
    metadata: metadata,
    body: stream<u8>,
  }
}

interface resource-provider {
  use resource-types.{resource-info, resource-response};
  use types.{metadata};

  /// Returns the list of resources available from this component.
  list-resources: async func(metadata: metadata) -> list<resource-info>;

  /// Returns a resource by URI.
  /// Returns a resource-response with mime-type, metadata, and a byte stream.
  get-resource: async func(metadata: metadata, uri: string) -> resource-response;
}
```

---

## Appendix B: Examples (Informative)

### B.1 Simple Component (no metadata)

A calculator component — `get-metadata-schema([])` returns `none`.

**WASM metadata:** `name = "calculator"`, `version = "1.0.0"`

**`act:component` custom section (CBOR):**

```cbor
{
  "std:default-language": "en",
  "std:description": "Basic arithmetic tools"
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

### B.5 Tool Result Stream

A successful `call-tool` returns a `stream<stream-event>`. Example stream (shown as pseudo-JSON for readability):

```
[
  content({ data: "Hello, world!", mime_type: "text/plain", metadata: [] }),
  content({ data: "<additional data>", mime_type: "text/plain", metadata: [] })
]
```

An error stream — the error event is terminal, the stream closes after it:

```
[
  error({ kind: "std:not-found", message: "Tool foo does not exist", metadata: [] })
]
```

A stream may contain content before an error (partial results):

```
[
  content({ data: "partial result...", mime_type: "text/plain", metadata: [] }),
  error({ kind: "std:timeout", message: "Operation timed out", metadata: [] })
]
```
