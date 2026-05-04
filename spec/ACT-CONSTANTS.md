---
title: ACT Well-Known Constants
version: 0.4.0
status: normative
requires: [act:core@0.4.0, act:tools@0.1.0]
---

# ACT Well-Known Constants

This document is the authoritative registry of all well-known `std:`-prefixed strings in the ACT protocol. All other ACT specifications reference this document rather than defining `std:` constants inline.

When adding a new `std:` constant, it MUST be registered here first.

---

## 1. Namespacing

Well-known constants use the `std:` prefix. Third-party constants use their own namespace (e.g. `acme:priority`). Hosts and components MUST ignore unrecognized constants.

---

## 2. Component Info Keys

Used in the `act:component` WASM custom section and `GET /info` HTTP response. The custom section is a CBOR map of namespaced tables; well-known metadata lives in the `std` table.

**`std` table keys:**

| Key | Type | Description |
|-----|------|-------------|
| `name` | string | Component name. Required. |
| `version` | string | Component SemVer version. Required. |
| `description` | string or localized map | Human-readable description. |
| `default-language` | string | BCP 47 language tag for the component's default language. |
| `capabilities` | map | Capability declarations keyed by capability ID (see Section 11). |

---

## 3. Tool Definition Metadata

Used in `tool-definition.metadata`.

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:read-only` | bool | Tool does not modify state. |
| `std:idempotent` | bool | Repeated calls with same arguments produce the same result. |
| `std:destructive` | bool | Tool may irreversibly modify state. |
| `std:timeout-ms` | uint | Suggested timeout in milliseconds. Host MAY override. |
| `std:usage-hints` | localized-string | When to use this tool (for AI agents). |
| `std:anti-usage-hints` | localized-string | When NOT to use this tool (for AI agents). |
| `std:examples` | array of bstr | Example tool calls as CBOR-encoded argument maps. |
| `std:tags` | array of string | Categorization tags. |
| `std:session-op` | string | When set on a tool synthesized by a transport adapter, identifies it as a session lifecycle operation. Values: `"open"`, `"close"`. See `ACT-SESSIONS.md` §6.1. |

### 3.1 Reserved Tool Names

Tool names beginning with `_act_` are reserved for transport-adapter use. The following are currently reserved:

| Name | Synthesized by | Purpose |
|---|---|---|
| `open_session` | MCP adapter (when component exports `act:sessions/session-provider`) | Open a new session. |
| `close_session` | MCP adapter (when component exports `act:sessions/session-provider`) | Close a session. |

Components MUST NOT define tools with these reserved names. If a host detects a collision, it SHOULD suffix the synthesized tool name (e.g. `open_session__act`) and emit a warning.

---

## 4. Content Part Metadata

Used in `content-part.metadata` within tool result streams.

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:progress` | uint | Number of units completed so far. |
| `std:progress-total` | uint | Total number of units, if known. |

---

## 5. Cross-Cutting Metadata

May appear on any metadata field (tool-call, list-tools-response, content-part, open-session, etc.).

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:traceparent` | string | W3C Trace Context `traceparent` header value. |
| `std:tracestate` | string | W3C Trace Context `tracestate` header value. |
| `std:request-id` | string | Correlation ID for logging. |
| `std:progress-token` | string | MCP-compatible progress token. |
| `std:agent-id` | string | Identifier of the agent making the call (informational; format implementation-defined). |
| `std:session-id` | string | Session identifier issued by `act:sessions/session-provider`. See `ACT-SESSIONS.md`. |

Transport adapters SHOULD propagate `std:traceparent` and `std:tracestate` to/from the corresponding HTTP headers or MCP request extensions.

### 5.1 Reserved Keys (Future Use)

The following keys are reserved for future use; their normative semantics are deferred to a future minor version. Implementations MAY use them with application-defined semantics but MUST NOT depend on cross-implementation interoperability.

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:on-behalf-of` | object (CBOR map) | User identity context for which the call is made (multi-tenant agent scenarios). See `ACT-AUTH.md` §3. |

---

## 6. Bridge Metadata

Used for component chaining via bridge components.

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:forward` | object (CBOR-encoded metadata) | Opaque metadata blob forwarded to the next component in a chain. Each bridge level unwraps one layer. |

---

## 7. Authentication Metadata

Used in `open-session.args` (preferred — see `ACT-SESSIONS.md` §4) for component-to-external-service authentication. Components MAY also accept these in `call-tool.metadata` for stateless ad-hoc cases (discouraged for new designs; see `ACT-AUTH.md` §1.6).

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:api-key` | string | API key for the external service. |
| `std:bearer-token` | string | OAuth2/OIDC access token or generic bearer-style token. |
| `std:username` | string | Username for basic auth. |
| `std:password` | string | Password for basic auth. |

See `ACT-AUTH.md` for full authentication semantics.

---

## 8. Error Kinds

Used in `error.kind`.

| Kind | Description |
|------|-------------|
| `std:not-found` | The named tool does not exist. |
| `std:invalid-args` | Arguments or metadata failed schema validation. |
| `std:timeout` | The call exceeded the declared or host-configured timeout. |
| `std:capability-denied` | The component attempted to use a capability that was not granted. |
| `std:session-not-found` | A capability call referenced a session-id the component does not recognize. See `ACT-SESSIONS.md` §2.3. |
| `std:internal` | An unrecoverable error within the component. |

---

## 9. Capability Identifiers

Used as keys in the `std:capabilities` map. Values are objects with capability-specific parameters.

| Capability ID | Parameters | Description |
|--------------|------------|-------------|
| `wasi:http` | _(none yet)_ | Outbound HTTP requests. |
| `wasi:filesystem` | `mount-root` (string) | Filesystem access. `mount-root` is the internal WASM path prefix for all host mounts (default: `/`). |
| `wasi:sockets` | _(none yet)_ | Outbound TCP and UDP connections. |

Third-party capabilities use their own namespace (e.g. `acme:gpu/compute`). Hosts that do not recognize a capability identifier SHOULD treat it according to their enforcement mode.

---

## 10. WASM Custom Sections

| Section name | Format | Description |
|-------------|--------|-------------|
| `act:component` | CBOR map | Component metadata (Section 2 keys). |
| `act:skill` | Uncompressed tar | Agent Skills package. See `ACT-AGENTSKILLS.md`. |

---

## 11. MIME Types

Used in `content-part.mime-type` and content negotiation.

| Constant | Value |
|----------|-------|
| `application/json` | JSON |
| `application/cbor` | CBOR-encoded structured data |
| `text/plain` | Plain text (UTF-8) |
| `text/event-stream` | Server-Sent Events |
