# ACT HTTP API

**Version 0.1.3 (Draft)**

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
- **Configuration** — pass per-request context (credentials, endpoint URLs) without server-side sessions.
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

### 2.4 Server Info

Returned by the info endpoint.

```json
{
  "name": "weather-tools",
  "version": "1.2.0",
  "description": "Weather data tools",
  "default_language": "en"
}
```

| Field | Type | Description |
|---|---|---|
| `name` | string | Server/component name. |
| `version` | string | SemVer version string. |
| `description` | string | Human-readable description (resolved to requested language). |
| `default_language` | string | BCP 47 language tag for the server's default language. |
| `capabilities` | array | Optional list of capabilities the server requires (see Section 8). |
| `metadata` | object | Optional key-value metadata. |

---

## 3. Endpoints

### 3.1 Single-Server Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/info` | Server metadata |
| `GET` | `/config-schema` | Config JSON Schema (or `204 No Content` if none) |
| `GET` | `/tools` | List tools (config via `X-ACT-Config` header) |
| `QUERY` | `/tools` | List tools (config in request body) |
| `POST` | `/tools/{name}` | Invoke a tool |
| `GET` | `/events` | Subscribe to server events (SSE) |
| `GET` | `/resources` | List available resources |
| `GET` | `/resources/{uri}` | Get a resource |

`QUERY` is defined in [draft-ietf-httpbis-safe-method-w-body](https://datatracker.ietf.org/doc/draft-ietf-httpbis-safe-method-w-body/). It is a safe, idempotent method that accepts a request body — ideal for passing config without header encoding. Servers SHOULD support `QUERY` when possible; `GET` with the `X-ACT-Config` header is the fallback for clients or intermediaries that do not support `QUERY`.

### 3.2 Multi-Server Endpoints

When a host serves multiple tool servers, paths are prefixed with the server name:

| Method | Path | Description |
|---|---|---|
| `GET` | `/components` | List available servers |
| `GET` | `/components/{component}/info` | Server metadata |
| `GET` | `/components/{component}/config-schema` | Config schema |
| `GET` | `/components/{component}/tools` | List tools (config via header) |
| `QUERY` | `/components/{component}/tools` | List tools (config in body) |
| `POST` | `/components/{component}/tools/{name}` | Invoke a tool |
| `GET` | `/components/{component}/events` | Subscribe to server events (SSE) |
| `GET` | `/components/{component}/resources` | List available resources |
| `GET` | `/components/{component}/resources/{uri}` | Get a resource |

---

## 4. Operations

### 4.1 Server Info — `GET /info`

Returns server metadata.

```
GET /info
Accept-Language: en

200 OK
Content-Type: application/json

{
  "name": "weather-tools",
  "version": "1.2.0",
  "description": "Weather data tools",
  "default_language": "en"
}
```

### 4.2 Config Schema — `GET /config-schema`

Returns a JSON Schema describing the configuration this server accepts. Returns `204 No Content` if the server does not require configuration.

```
GET /config-schema

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

### 4.3 Tool Discovery — `GET /tools` or `QUERY /tools`

Returns the list of available tools.

**With `QUERY` (preferred when config is needed):**

```
QUERY /tools
Content-Type: application/json
Accept-Language: en

{
  "config": { "api_key": "abc123" }
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

**With `GET` (fallback):**

```
GET /tools
X-ACT-Config: eyJhcGlfa2V5IjoiYWJjMTIzIn0=
Accept-Language: en

200 OK
Content-Type: application/json

{
  "tools": [ ... ]
}
```

The `X-ACT-Config` header value is base64-encoded JSON. For servers that do not require config, both `GET /tools` and `QUERY /tools` (without a body) are equivalent.

The response MAY include a top-level `metadata` object with server-defined key-value pairs. Metadata values MAY also be returned as HTTP response headers with an `X-ACT-Meta-` prefix.

On error, the server returns the appropriate HTTP status code (see Section 6).

### 4.4 Tool Invocation — `POST /tools/{name}`

Invokes a tool and returns the result.

**Request:**

```
POST /tools/get_weather
Content-Type: application/json

{
  "id": "call-1",
  "arguments": { "city": "London" },
  "config": { "api_key": "abc123" }
}
```

| Field | Type | Description |
|---|---|---|
| `id` | string | Caller-assigned identifier for correlation. |
| `arguments` | object | Tool arguments conforming to `parameters_schema`. |
| `config` | object | Optional configuration matching the config schema. |

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

### 4.5 Event Subscription — `GET /events`

Opens a Server-Sent Events stream for push notifications from the server.

Config is passed via the `X-ACT-Config` header (base64-encoded JSON) if needed.

```
GET /events
Accept: text/event-stream
X-ACT-Config: eyJhcGlfa2V5IjoiYWJjMTIzIn0=

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

### 4.6 Resource Listing — `GET /resources`

Returns the list of available resources.

Config is passed via the `X-ACT-Config` header if needed.

```
GET /resources
Accept-Language: en

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

### 4.7 Resource Retrieval — `GET /resources/{uri}`

Returns a resource as raw bytes.

Config is passed via the `X-ACT-Config` header if needed.

```
GET /resources/std:icon

200 OK
Content-Type: image/png

<binary PNG data>
```

The `Content-Type` header reflects the actual MIME type of the resource. Resource metadata MAY be returned as `X-ACT-Meta-*` headers.

If the resource does not exist, the server returns `404 Not Found`.

---

## 5. Configuration

Servers that require per-request context (API keys, endpoint URLs, user preferences) declare a config schema via `GET /config-schema`. Clients pass config on every request.

### 5.1 Config Delivery

Config delivery depends on the HTTP method:

| Method | Config mechanism |
|---|---|
| `QUERY` | `config` field in request body (JSON) |
| `POST` | `config` field in request body (JSON) |
| `GET` | `X-ACT-Config` header (base64-encoded JSON) |

**Request body (preferred):**

```json
{
  "config": { "api_key": "abc123" }
}
```

**Header (fallback for `GET`):**

```
X-ACT-Config: eyJhcGlfa2V5IjoiYWJjMTIzIn0=
```

For servers that do not require config (`GET /config-schema` returns `204`), config is omitted.

---

## 6. Error Handling

### 6.1 Well-Known Error Kinds

| `kind` | HTTP Status | Description |
|---|---|---|
| `std:not-found` | `404 Not Found` | Tool not found. |
| `std:invalid-args` | `422 Unprocessable Entity` | Arguments do not match schema. |
| `std:timeout` | `504 Gateway Timeout` | Operation timed out. |
| `std:capability-denied` | `403 Forbidden` | Required capability not available. |
| `std:internal` | `500 Internal Server Error` | Unexpected server error. |

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

### 7.1 Tool Definition Metadata

| Key | Type | Description |
|---|---|---|
| `std:read-only` | boolean | Tool does not modify state. |
| `std:idempotent` | boolean | Repeated calls produce the same result. |
| `std:destructive` | boolean | Tool may cause irreversible changes. |
| `std:usage-hints` | string | When to use this tool (for AI agents). |
| `std:anti-usage-hints` | string | When NOT to use this tool (for AI agents). |
| `std:examples` | array | Example invocations. |
| `std:tags` | array | Classification tags. |
| `std:timeout-ms` | integer | Suggested timeout in milliseconds. |
| `std:streaming` | boolean | Tool produces results incrementally; clients may prefer SSE. |

### 7.2 Content Part Metadata

| Key | Type | Description |
|---|---|---|
| `std:progress` | integer | Number of units completed so far. |
| `std:progress-total` | integer | Total number of units, if known. |

Example SSE event with progress:

```
event: content
data: {"data": "Processing item 3...", "mime_type": "text/plain", "metadata": {"std:progress": 3, "std:progress-total": 10}}
```

### 7.3 Cross-Cutting Metadata

The following keys may appear on any metadata field (request, response, content part):

| Key | Type | Description |
|---|---|---|
| `std:traceparent` | string | W3C Trace Context `traceparent` value. Enables distributed tracing. |
| `std:tracestate` | string | W3C Trace Context `tracestate` value. Vendor-specific trace data. |

Servers SHOULD propagate `std:traceparent` and `std:tracestate` to/from the standard HTTP `traceparent` and `tracestate` headers.

---

## 8. Capabilities

The `capabilities` array in server info declares external dependencies:

```json
{
  "capabilities": [
    { "id": "network:http", "required": true, "description": "HTTP access for API calls" },
    { "id": "storage:kv", "required": false, "description": "Optional caching" }
  ]
}
```

| Field | Type | Description |
|---|---|---|
| `id` | string | Capability identifier. |
| `required` | boolean | Whether the server fails without this capability. |
| `description` | string | Human-readable description. |

---

## 9. Content Negotiation

The server MUST support `application/json`. The server MAY additionally support `application/cbor`.

The client signals preferred encoding via `Accept` and `Content-Type` headers. If no `Accept` header is provided, the server defaults to `application/json`.

Language selection uses the standard `Accept-Language` header. The server resolves localized values (descriptions, error messages) to the best matching language.

---

## 10. Cancellation

The client cancels a streaming request by closing the HTTP connection. The server SHOULD stop processing and release associated resources promptly.

---

## 11. Conformance

A conformant ACT HTTP server:
- MUST implement `GET /info`, `GET /tools`, and `POST /tools/{name}`.
- MUST support `application/json` content type.
- MUST support `Accept-Language` for localization.
- MUST return tool definitions with valid JSON Schema in `parameters_schema`.
- MUST validate tool arguments against declared schemas before execution.
- MUST map well-known error kinds (`std:*`) to HTTP status codes as defined in Section 6.1.
- MUST support config in `POST` request body (`config` field) if the server requires configuration.
- MUST support config via `X-ACT-Config` header for `GET /tools` if the server requires configuration.
- SHOULD implement `GET /config-schema` if the server requires configuration.
- SHOULD support `QUERY /tools` with config in request body.
- SHOULD support SSE streaming via `Accept: text/event-stream`.
- SHOULD implement `GET /events` if the server supports push notifications.
- SHOULD implement `GET /resources` and `GET /resources/{uri}` if the server provides resources.

---

## 12. Relationship to ACT Component Model

This HTTP API is one of several transport bindings defined by the ACT (Agent Component Tools) specification. The full ACT specification (`ACT-SPEC.md`) defines a WebAssembly Component Model contract that can be exposed over this HTTP API, MCP, or other transports.

An ACT host automatically implements this HTTP API by translating between HTTP requests and the underlying component calls. However, this HTTP specification is intentionally self-contained — any HTTP server can implement it directly without WebAssembly.

For the full ACT specification, see `ACT-SPEC.md`. For MCP mapping guidance, see `ACT-MCP.md`. For authentication patterns, see `ACT-AUTH.md`.
