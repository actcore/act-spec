# ACT HTTP API

**Protocol Version 0.2 (Draft)**

A stateless HTTP API for discovering and invoking tools. Any HTTP server that conforms to this specification is a valid implementation — no WebAssembly runtime or specific programming language is required.

The protocol is stateless — every request carries all necessary context. Implementations MAY maintain internal state (caches, connection pools, pre-fetched schemas) as a private optimization, but the protocol does not manage or expose it.

This specification is HTTP version agnostic — it works over HTTP/1.1, HTTP/2, or HTTP/3. All examples use HTTP/1.1 syntax for readability.

An OpenAPI 3.2 definition is available in `ACT-HTTP-openapi.yaml`.

---

## 1. Overview

An ACT HTTP server exposes a set of **tools** — callable operations with typed parameters and structured results. Each tool has a name, description, parameter schema, and optional metadata.

The API supports:
- **Tool discovery** — list available tools with their schemas and descriptions.
- **Tool invocation** — call a tool with JSON arguments, receive structured results.
- **Streaming** — optionally stream results via Server-Sent Events.
- **Metadata** — pass per-request context (credentials, endpoint URLs) without server-side sessions.
- **Localization** — tool descriptions and error messages support multiple languages.

---

## 2. Data Types

### 2.1 Tool Definition

Returned by the tool discovery endpoint.

```json
{
  "name": "search_web",
  "description": "Search the web for information",
  "parameters_schema": {
    "type": "object",
    "properties": {
      "query": { "type": "string", "description": "Search query" },
      "limit": { "type": "integer", "description": "Max results", "default": 10 }
    },
    "required": ["query"]
  },
  "metadata": {
    "std:read-only": true,
    "std:tags": ["search", "web"]
  }
}
```

| Field | Type | Description |
|---|---|---|
| `name` | string | Unique tool identifier. |
| `description` | string | Human-readable description (resolved to requested language). |
| `parameters_schema` | object | JSON Schema describing the tool's parameters. MUST have `type: "object"`. |
| `metadata` | object | Optional key-value metadata (see Section 7). |

### 2.2 Content Part

A single piece of content in a tool's response.

```json
{
  "data": "Search completed. Found 5 results.",
  "mime_type": "text/plain"
}
```

| Field | Type | Description |
|---|---|---|
| `data` | string | Payload. Plain text for `text/*` types, base64-encoded for binary types. |
| `mime_type` | string or null | MIME type. Defaults to `application/json` if absent. (Note: the underlying ACT protocol defaults to `application/cbor`; the HTTP API maps this to JSON.) |
| `metadata` | object | Optional key-value metadata. |

### 2.3 Tool Error

```json
{
  "kind": "std:invalid-args",
  "message": "Parameter 'limit' must be a positive integer"
}
```

| Field | Type | Description |
|---|---|---|
| `kind` | string | Error category. Well-known values use the `std:` prefix (see Section 6). Custom values use a namespace prefix (e.g. `acme:rate-limited`). |
| `message` | string | Human-readable error message (resolved to requested language). |
| `metadata` | object | Optional key-value metadata. |

### 2.4 Component Info

Returned by the info endpoint. Uses the same format as the `act:component` WASM custom section (see ACT-SPEC.md Section 3.2).

```json
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

**`std` table fields:**

| Field | Type | Description |
|---|---|---|
| `name` | string | Component name. Required. |
| `version` | string | Component SemVer version string. Required. |
| `description` | string | Human-readable description. |
| `default-language` | string | BCP 47 language tag for the component's default language. |
| `capabilities` | object | Map of capability declarations (see Section 8). |

Additional namespaces (e.g. `acme`) MAY be present. Clients MUST ignore unrecognized namespaces.

---

## 3. Endpoints

An ACT HTTP server exposes a single set of tools. Hosting multiple components behind one HTTP endpoint is an implementation concern of the host, not part of this specification.

| Method | Path | Description |
|---|---|---|
| `GET` | `/info` | Server metadata |
| `POST` | `/metadata-schema` | Metadata JSON Schema (metadata in body for iterative discovery) |
| `QUERY` | `/metadata-schema` | Metadata JSON Schema (safe, cacheable) |
| `POST` | `/tools` | List tools (metadata in request body) |
| `QUERY` | `/tools` | List tools (metadata in request body; safe, cacheable) |
| `POST` | `/tools/{name}` | Invoke a tool |
| `QUERY` | `/tools/{name}` | Invoke a read-only, idempotent tool (safe, cacheable) |
| `POST` | `/events` | Subscribe to server events (SSE, metadata in body) |
| `QUERY` | `/events` | Subscribe to server events (SSE, metadata in body; safe) |
| `POST` | `/resources` | List available resources (metadata in body) |
| `QUERY` | `/resources` | List available resources (metadata in body; safe) |
| `POST` | `/resources/{uri}` | Get a resource (metadata in body) |
| `QUERY` | `/resources/{uri}` | Get a resource (metadata in body; safe) |

Metadata is always passed in the request body. There are no metadata-related headers.

`QUERY` is defined in [draft-ietf-httpbis-safe-method-w-body](https://datatracker.ietf.org/doc/draft-ietf-httpbis-safe-method-w-body/). It is a safe, idempotent method that accepts a request body. Every endpoint that accepts metadata supports both `POST` and `QUERY` with identical request/response formats. `POST` is the universal fallback for clients or intermediaries that do not support `QUERY`. `QUERY` enables HTTP caching and signals that the operation is safe.

Servers MUST support `QUERY /tools/{name}` for tools that declare both `std:read-only` and `std:idempotent` in their metadata. The server MUST reject `QUERY /tools/{name}` for tools that are not both read-only and idempotent, returning `405 Method Not Allowed`.

---

## 4. Operations

### 4.1 Component Info — `GET /info`

Returns component metadata in the same format as the `act:component` custom section.

```
GET /info

200 OK
Content-Type: application/json

{
  "std": {
    "name": "weather-tools",
    "version": "1.2.0",
    "description": "Weather data tools",
    "default-language": "en"
  }
}
```

### 4.2 Metadata Schema — `POST /metadata-schema`

Returns a JSON Schema describing the metadata this server accepts. Returns `204 No Content` if the server does not require metadata.

The client MAY include current metadata in the request body for iterative schema discovery (see ACT-SPEC.md Section 4.5). An empty body or `{}` requests the initial schema.

```
POST /metadata-schema
Content-Type: application/json

{}

200 OK
Content-Type: application/json

{
  "type": "object",
  "properties": {
    "api_key": { "type": "string" }
  },
  "required": ["api_key"]
}
```

Iterative discovery example (bridge component):

```
POST /metadata-schema
Content-Type: application/json

{"metadata": {"act:remote_url": "https://api.example.com"}}

200 OK
Content-Type: application/json

{
  "type": "object",
  "properties": {
    "act:remote_url": { "type": "string" },
    "std:forward": {
      "type": "object",
      "properties": { "api_key": { "type": "string" } },
      "required": ["api_key"]
    }
  },
  "required": ["act:remote_url"]
}
```

### 4.3 Tool Discovery — `POST /tools` or `QUERY /tools`

Returns the list of available tools. Both `POST` and `QUERY` accept the same request body. Use `QUERY` when available (safe, cacheable); `POST` is the universal fallback.

```
QUERY /tools
Content-Type: application/json
Accept-Language: en

{
  "metadata": { "api_key": "abc123" }
}

200 OK
Content-Type: application/json

{
  "tools": [
    {
      "name": "get_weather",
      "description": "Get current weather for a location",
      "parameters_schema": {
        "type": "object",
        "properties": {
          "city": { "type": "string" }
        },
        "required": ["city"]
      },
      "metadata": {
        "std:read-only": true
      }
    }
  ]
}
```

For servers that do not require metadata, the `metadata` field is omitted (or the body may be empty).

The response MAY include a top-level `metadata` object with server-defined key-value pairs.

On error, the server returns the appropriate HTTP status code (see Section 6).

### 4.4 Tool Invocation — `POST /tools/{name}` or `QUERY /tools/{name}`

Invokes a tool and returns the result.

**Request:**

```
POST /tools/get_weather
Content-Type: application/json

{
  "id": "call-1",
  "arguments": { "city": "London" },
  "metadata": { "api_key": "abc123" }
}
```

| Field | Type | Description |
|---|---|---|
| `id` | string | Caller-assigned identifier for correlation. |
| `arguments` | object | Tool arguments conforming to `parameters_schema`. |
| `metadata` | object | Optional metadata matching the metadata schema. |

**`QUERY` method for read-only idempotent tools:**

Tools that declare both `std:read-only: true` and `std:idempotent: true` in their metadata MAY also be invoked via `QUERY /tools/{name}`. The request body is identical to `POST`. Because `QUERY` is safe and idempotent, responses are cacheable by HTTP intermediaries.

The server MUST return `405 Method Not Allowed` if a client sends `QUERY` to a tool that is not both read-only and idempotent.

**Response (non-streaming):**

```
200 OK
Content-Type: application/json

{
  "id": "call-1",
  "content": [
    { "data": "London: 15°C, partly cloudy", "mime_type": "text/plain" }
  ]
}
```

The `content` array contains one or more content parts. The response MAY include a top-level `metadata` object.

**Response (streaming):**

The response format is determined by the client's `Accept` header:
- `Accept: application/json` (or absent) — the server collects all stream events and returns a single JSON response. This is the default.
- `Accept: text/event-stream` — the server forwards stream events as Server-Sent Events (SSE) as they become available.

The server MUST NOT send SSE unless the client explicitly requests it. When the client requests `text/event-stream` but the server does not support streaming, it SHOULD return a plain JSON response with `Content-Type: application/json` (standard HTTP content negotiation).

Tools MAY declare `std:streaming` (boolean) in their metadata to indicate that they produce results incrementally. Clients can use this hint to decide whether to request SSE. However, the hint is advisory — correctness does not depend on it. The server always buffers or streams based solely on the `Accept` header.

SSE streaming example:

```
POST /tools/search_web
Content-Type: application/json
Accept: text/event-stream

{
  "id": "call-1",
  "arguments": { "query": "rust wasm" }
}

200 OK
Content-Type: text/event-stream

event: content
data: {"data": "First result...", "mime_type": "text/plain"}

event: content
data: {"data": "Second result...", "mime_type": "text/plain"}

event: done
data: {}
```

If an error occurs mid-stream:

```
event: error
data: {"kind": "std:internal", "message": "Connection lost"}
```

The `error` and `done` events are terminal — the stream closes after either.

### 4.5 Event Subscription — `POST /events` or `QUERY /events`

Opens a Server-Sent Events stream for push notifications from the server. Metadata is passed in the request body.

```
QUERY /events
Content-Type: application/json
Accept: text/event-stream

{"metadata": {"api_key": "abc123"}}

200 OK
Content-Type: text/event-stream

event: std:tools:changed
data: {}

event: acme:order_updated
data: {"order_id": "123"}
```

Each SSE event has:
- `event:` — the event kind (e.g. `std:tools:changed`)
- `data:` — JSON-encoded payload (or `{}` for events with no payload)

The stream stays open until the client closes the connection. The server SHOULD release resources promptly when the client disconnects.

Servers that do not support events return `404 Not Found`.

### 4.6 Resource Listing — `POST /resources` or `QUERY /resources`

Returns the list of available resources. Metadata is passed in the request body.

```
QUERY /resources
Content-Type: application/json
Accept-Language: en

{}

200 OK
Content-Type: application/json

{
  "resources": [
    {
      "uri": "std:icon",
      "mime_type": "image/png",
      "description": "Component icon"
    }
  ]
}
```

| Field | Type | Description |
|---|---|---|
| `uri` | string | Resource identifier. |
| `mime_type` | string or null | Expected MIME type. |
| `description` | string | Human-readable description (resolved to requested language). |
| `metadata` | object | Optional key-value metadata. |

### 4.7 Resource Retrieval — `POST /resources/{uri}` or `QUERY /resources/{uri}`

Returns a resource as raw bytes. Metadata is passed in the request body.

```
QUERY /resources/std:icon
Content-Type: application/json

{}

200 OK
Content-Type: image/png

<binary PNG data>
```

The `Content-Type` header of the response reflects the actual MIME type of the resource.

If the resource does not exist, the server returns `404 Not Found`.

---

## 5. Metadata

Servers that require per-request context (API keys, endpoint URLs, user preferences) declare a metadata schema via `POST /metadata-schema`. Clients pass metadata on every request.

### 5.1 Metadata Delivery

Metadata is always passed as a `metadata` field in the JSON request body:

```json
{
  "metadata": { "api_key": "abc123" }
}
```

Both `POST` and `QUERY` use the same request body format. For servers that do not require metadata (`POST /metadata-schema` returns `204`), the `metadata` field is omitted.

---

## 6. Error Handling

### 6.1 Well-Known Error Kinds

For the complete list of well-known error kinds, see `ACT-CONSTANTS.md` Section 8.

The HTTP status code mapping for well-known error kinds is:

| `kind` | HTTP Status |
|---|---|
| `std:not-found` | `404 Not Found` |
| `std:invalid-args` | `422 Unprocessable Entity` |
| `std:timeout` | `504 Gateway Timeout` |
| `std:capability-denied` | `403 Forbidden` |
| `std:internal` | `500 Internal Server Error` |

Custom error kinds use a namespace prefix (e.g. `acme:rate-limited`). Servers MAY map custom kinds to appropriate HTTP status codes.

### 6.2 Error Response Format

```
422 Unprocessable Entity
Content-Type: application/json

{
  "error": {
    "kind": "std:invalid-args",
    "message": "Parameter 'limit' must be a positive integer"
  }
}
```

The error response MAY include a `metadata` field.

For non-streaming responses (and streaming responses where the error occurs before the first SSE event is sent), the server returns the appropriate HTTP status code with a JSON error body. Once SSE streaming has begun, errors are delivered as `event: error` SSE events.

---

## 7. Well-Known Metadata Keys

Metadata is an optional key-value object on tool definitions, content parts, errors, and responses. Well-known keys use the `std:` prefix. Third-party keys use their own namespace (e.g. `acme:priority`).

Well-known `std:` constants are defined in `ACT-CONSTANTS.md`. The following subsections summarize their use in the HTTP API context.

### 7.1 Tool Definition Metadata

Well-known tool definition metadata keys are defined in `ACT-CONSTANTS.md` Section 3. Commonly used keys include `std:read-only`, `std:idempotent`, `std:destructive`, `std:streaming`, and `std:timeout-ms`.

### 7.2 Content Part Metadata

Well-known content part metadata keys are defined in `ACT-CONSTANTS.md` Section 4. Commonly used keys include `std:progress` and `std:progress-total`.

Example SSE event with progress:

```
event: content
data: {"data": "Processing item 3...", "mime_type": "text/plain", "metadata": {"std:progress": 3, "std:progress-total": 10}}
```

### 7.3 Cross-Cutting Metadata

Well-known cross-cutting metadata keys are defined in `ACT-CONSTANTS.md` Section 5. These keys (e.g. `std:traceparent`, `std:tracestate`, `std:request-id`) may appear on any metadata field (request, response, content part).

Servers SHOULD propagate `std:traceparent` and `std:tracestate` to/from the standard HTTP `traceparent` and `tracestate` headers.

### 7.4 Bridge Metadata

Well-known bridge metadata keys are defined in `ACT-CONSTANTS.md` Section 6. The `std:forward` key carries an opaque metadata blob forwarded by bridge components to the next component in a chain.

See ACT-SPEC.md Section 8.3 for bridge forwarding details.

---

## 8. Capabilities

The `std.capabilities` map in component info declares external dependencies. Each key is a capability identifier; the value is an object with capability-specific parameters (may be empty):

```json
{
  "std": {
    "capabilities": {
      "wasi:http": {},
      "wasi:filesystem": { "mount-root": "/data" }
    }
  }
}
```

Presence of a key declares that the component uses the capability. An empty object `{}` means the capability is used without specific restrictions. A capability absent from the map is not used by the component.

For the list of well-known capability identifiers and their parameters, see ACT-SPEC.md Section 7.4 and ACT-CONSTANTS.md Section 11.

---

## 9. Content Negotiation

The server MUST support `application/json`. The server MAY additionally support `application/cbor`.

The client signals preferred encoding via `Accept` and `Content-Type` headers. If no `Accept` header is provided, the server defaults to `application/json`.

Language selection uses the standard `Accept-Language` header. The server resolves localized values (descriptions, error messages) to the best matching language.

---

## 10. Cancellation

The client cancels a streaming request by closing the HTTP connection. The server SHOULD stop processing and release associated resources promptly.

---

## 11. Protocol Version Negotiation

The ACT-HTTP protocol is versioned using SemVer `major.minor`. Patch versions are not used — patch-level changes do not affect the wire format.

### 11.1 Version Header

Every request SHOULD include:

```
ACT-Protocol-Version: 0.2
```

Every response MUST include:

```
ACT-Protocol-Version: 0.2
```

The server's response header indicates the protocol version it is actually using for this response.

### 11.2 Compatibility Rules

Version compatibility follows standard SemVer semantics:

- **major=0 (unstable):** exact `major.minor` match required. `0.1` and `0.2` are incompatible.
- **major≥1 (stable):** same major version is compatible. A server at `1.5` can serve a client at `1.2` — the effective protocol version is `min(server, client)` within the same major.
- **Different major versions** are always incompatible.

### 11.3 Negotiation Flow

1. Client sends `ACT-Protocol-Version` header with its maximum supported version.
2. Server checks compatibility:
   - **Compatible:** responds normally with its effective version in the `ACT-Protocol-Version` response header.
   - **Incompatible:** responds with `406 Not Acceptable` and a JSON body listing supported versions:
     ```json
     {"supported_versions": ["0.2"]}
     ```
3. If the client omits the header, the server uses its current version and includes it in the response header. The client SHOULD check the response header and verify compatibility.

---

## 12. Conformance

A conformant ACT HTTP server:
- MUST implement `GET /info`, `POST /metadata-schema`, `QUERY /metadata-schema`, `POST /tools`, `QUERY /tools`, and `POST /tools/{name}`.
- MUST support both `POST` and `QUERY` for every endpoint that accepts metadata (`/metadata-schema`, `/tools`, `/events`, `/resources`, `/resources/{uri}`).
- MUST support `QUERY /tools/{name}` for tools that declare both `std:read-only` and `std:idempotent`.
- MUST include the `ACT-Protocol-Version` header in every response.
- MUST return `406 Not Acceptable` when the client requests an incompatible protocol version.
- MUST support `application/json` content type.
- MUST support `Accept-Language` for localization.
- MUST return tool definitions with valid JSON Schema in `parameters_schema`.
- MUST validate tool arguments against declared schemas before execution.
- MUST map well-known error kinds (`std:*`) to HTTP status codes as defined in Section 6.1.
- SHOULD support SSE streaming via `Accept: text/event-stream`.
- SHOULD implement `/events` if the server supports push notifications.
- SHOULD implement `/resources` and `/resources/{uri}` if the server provides resources.

---

## 13. Relationship to ACT Component Model

This HTTP API is one of several transport bindings defined by the ACT (Agent Component Tools) specification. The full ACT specification (`ACT-SPEC.md`) defines a WebAssembly Component Model contract that can be exposed over this HTTP API, MCP, or other transports.

An ACT host automatically implements this HTTP API by translating between HTTP requests and the underlying component calls. However, this HTTP specification is intentionally self-contained — any HTTP server can implement it directly without WebAssembly.

For the full ACT specification, see `ACT-SPEC.md`. For MCP mapping guidance, see `ACT-MCP.md`. For authentication patterns, see `ACT-AUTH.md`.
