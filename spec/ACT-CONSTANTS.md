# ACT Well-Known Constants

**Protocol Version 0.2 (Draft)**

This document is the authoritative registry of all well-known `std:`-prefixed strings in the ACT protocol. All other ACT specifications reference this document rather than defining `std:` constants inline.

When adding a new `std:` constant, it MUST be registered here first.

---

## 1. Namespacing

Well-known constants use the `std:` prefix. Third-party constants use their own namespace (e.g. `acme:priority`). Hosts and components MUST ignore unrecognized constants.

---

## 2. Component Info Keys

Used in the `act:component` WASM custom section and `GET /info` HTTP response.

| Key | Type | Description |
|-----|------|-------------|
| `std:name` | string | Component name. |
| `std:version` | string | Component SemVer version. |
| `std:description` | string or localized map | Human-readable description. |
| `std:default-language` | string | BCP 47 language tag for the component's default language. Optional. |
| `std:capabilities` | map | Capability declarations keyed by capability ID (see Section 11). |

---

## 3. Tool Definition Metadata

Used in `tool-definition.metadata`.

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:read-only` | bool | Tool does not modify state. |
| `std:idempotent` | bool | Repeated calls with same arguments produce the same result. |
| `std:destructive` | bool | Tool may irreversibly modify state. |
| `std:streaming` | bool | Tool produces results incrementally. |
| `std:timeout-ms` | uint | Suggested timeout in milliseconds. Host MAY override. |
| `std:usage-hints` | localized-string | When to use this tool (for AI agents). |
| `std:anti-usage-hints` | localized-string | When NOT to use this tool (for AI agents). |
| `std:examples` | array of bstr | Example tool calls as CBOR-encoded argument maps. |
| `std:tags` | array of string | Categorization tags. |

---

## 4. Content Part Metadata

Used in `content-part.metadata` within tool result streams.

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:progress` | uint | Number of units completed so far. |
| `std:progress-total` | uint | Total number of units, if known. |

---

## 5. Cross-Cutting Metadata

May appear on any metadata field (tool-call, list-tools-response, content-part, etc.).

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:traceparent` | string | W3C Trace Context `traceparent` header value. |
| `std:tracestate` | string | W3C Trace Context `tracestate` header value. |
| `std:request-id` | string | Correlation ID for logging. |
| `std:progress-token` | string | MCP-compatible progress token. |

Transport adapters SHOULD propagate `std:traceparent` and `std:tracestate` to/from the corresponding HTTP headers or MCP request extensions.

---

## 6. Bridge Metadata

Used for component chaining via bridge components.

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:forward` | object (CBOR-encoded metadata) | Opaque metadata blob forwarded to the next component in a chain. Each bridge level unwraps one layer. |

---

## 7. Authentication Metadata

Used in `tool-call.metadata` for component-to-external-service authentication.

| Key | Value type | Description |
|-----|-----------|-------------|
| `std:api-key` | string | API key for the external service. |
| `std:bearer-token` | string | OAuth2/OIDC access token. |
| `std:username` | string | Username for basic auth. |
| `std:password` | string | Password for basic auth. |

See `ACT-AUTH.md` for authentication patterns.

---

## 8. Error Kinds

Used in `tool-error.kind`.

| Kind | Description |
|------|-------------|
| `std:not-found` | The named tool does not exist. |
| `std:invalid-args` | Arguments or metadata failed schema validation. |
| `std:timeout` | The call exceeded the declared or host-configured timeout. |
| `std:capability-denied` | The component attempted to use a capability that was not granted. |
| `std:internal` | An unrecoverable error within the component. |

---

## 9. Event Kinds

Used in `event-type-info.kind` and `event.kind`.

| Kind | Description |
|------|-------------|
| `std:tools:changed` | Tool list has changed. Clients SHOULD re-fetch via `list-tools`. |
| `std:resources:changed` | Resource list has changed. Clients SHOULD re-fetch via `list-resources`. |
| `std:events:changed` | Event type list has changed. Clients SHOULD re-fetch via `get-event-types`. |

---

## 10. Resource URIs

Well-known resource identifiers for `resource-provider`.

| URI | Description |
|-----|-------------|
| `std:icon` | Component icon. Expected MIME type: `image/png` or `image/svg+xml`. |

---

## 11. Capability Identifiers

Used as keys in the `std:capabilities` map. Values are objects with capability-specific parameters.

| Capability ID | Parameters | Description |
|--------------|------------|-------------|
| `wasi:http` | _(none yet)_ | Outbound HTTP requests. |
| `wasi:filesystem` | `mount-root` (string) | Filesystem access. `mount-root` is the internal WASM path prefix for all host mounts (default: `/`). |
| `wasi:sockets` | _(none yet)_ | Outbound TCP and UDP connections. |

Third-party capabilities use their own namespace (e.g. `acme:gpu/compute`). Hosts that do not recognize a capability identifier SHOULD treat it according to their enforcement mode.

---

## 12. WASM Custom Sections

| Section name | Format | Description |
|-------------|--------|-------------|
| `act:component` | CBOR map | Component metadata (Section 2 keys). |
| `act:skill` | Uncompressed tar | Agent Skills package. See `ACT-AGENTSKILLS.md`. |

---

## 13. MIME Types

Used in `content-part.mime-type` and content negotiation.

| Constant | Value |
|----------|-------|
| `application/json` | JSON |
| `application/cbor` | CBOR-encoded structured data |
| `text/plain` | Plain text (UTF-8) |
| `text/event-stream` | Server-Sent Events |
