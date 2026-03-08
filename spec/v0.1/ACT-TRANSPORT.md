# ACT Transport Bindings

**Version 0.1.2 (Draft)**

This document specifies how ACT protocol operations map to external transport protocols. It is a companion to the core ACT specification (`ACT-SPEC.md`).

---

## 1. General Principles

### 1.1 Transport Independence

The ACT core protocol defines a component-level contract (WIT interfaces). Transport bindings translate between external protocols and ACT host calls. A conformant ACT host MAY support multiple transports simultaneously.

### 1.2 Stateless Design

ACT components are stateless — there are no server-side sessions. Each call to `list-tools` or `call-tool` carries all necessary context via the optional `config` parameter.

Transport adapters MAY introduce session-like abstractions (e.g. caching config server-side) as an optimization, but this is a transport concern, not a component contract.

### 1.3 Config Delivery

Components that require configuration (as declared by `get-config-schema`) receive it as `option<list<u8>>` — dCBOR-encoded bytes (RFC 8949 §4.2) — in every `list-tools` and `call-tool` invocation. Config is analogous to HTTP headers — it carries per-call context (credentials, endpoint URLs, preferences) orthogonal to tool arguments.

Transport adapters accept config in the transport-native format (JSON, HTTP headers, etc.) and convert it to dCBOR before passing it to the component. The host ensures config bytes are valid dCBOR.

Transport adapters map config to the natural mechanism for each transport:

| Transport | Config mechanism |
|---|---|
| MCP stdio | Host-level configuration (command-line args, config file, environment) |
| MCP SSE | Extensions in `initialize` request params |
| HTTP | `X-ACT-Config` header or request body field |

The host MAY merge config from multiple sources (e.g. server defaults + client-provided values) before passing it to the component.

### 1.4 Bridge Components

A bridge component adapts an external protocol into the ACT `tool-provider` interface. The bridge fetches a remote schema or spec, maps discovered operations to `list-tools`, and translates `call-tool` invocations into the external protocol's native calls.

The general pattern:

```
External protocol     ACT tool-provider
  discovery       →     list-tools
  invoke          →     call-tool
  schema          →     parameter-meta
```

Bridge components are configured via `config`: each call specifies which external endpoint to use. One bridge component instance can serve requests to different APIs simultaneously.

Example bridge components:
- **OpenAPI bridge** — fetches an OpenAPI spec, exposes each operation as a tool.
- **MCP client bridge** — connects to a remote MCP server, exposes its tools as ACT tools.
- **ACP client bridge** — delegates tasks to remote agents via the Agent Communication Protocol.

### 1.5 Language Selection

Transport adapters resolve `localized-string` values to a single language before sending responses to clients.

The adapter determines the client's preferred language from transport-specific mechanisms:
- MCP: `Accept-Language` in `initialize` params extensions, or host configuration.
- HTTP: standard `Accept-Language` header.

Resolution follows the order defined in ACT-SPEC Section 5.3: exact match, prefix match, `default-language`, `"en"`, first available.

### 1.6 Lifecycle

```
Host loads component
    -> Host calls get-info(), caches metadata
    -> Host calls get-config-schema(), caches schema
    -> Component is ready to accept calls

Client request arrives
    -> Adapter extracts config from transport-specific mechanism
    -> Adapter calls list-tools(config) or call-tool(config, call)
    -> Adapter translates response back to transport protocol
```

---

## 2. MCP Transport Binding

This section defines how an ACT host exposes components as an MCP-compatible server conforming to the Model Context Protocol specification.

### 2.1 Server Identity

The MCP `initialize` response MUST include:

```json
{
  "protocolVersion": "2024-11-05",
  "serverInfo": {
    "name": "<component-info.name>",
    "version": "<component-info.version>"
  },
  "capabilities": {
    "tools": {}
  }
}
```

The adapter MAY include additional MCP capabilities (e.g. `resources`, `prompts`) if the component exports corresponding ACT interfaces in future spec versions.

### 2.2 Config Resolution

For MCP stdio, config is fixed for the lifetime of the process. The adapter obtains config from:

1. Command-line arguments or a config file provided at server startup.
2. Extensions in the MCP `initialize` request params (if the client provides them).

The adapter caches the resolved config and passes it to every `list-tools` and `call-tool` invocation.

For components that do not require config (`get-config-schema` returns `none`), the adapter passes `none`.

### 2.3 Tool Discovery — `tools/list`

When the MCP client calls `tools/list`, the adapter calls `list-tools(config)`. On success, the adapter receives a `list-tools-response` containing `metadata` and `tools`, and translates each `tool-definition` to an MCP tool object. On error (`tool-error`), the adapter returns an MCP error response.

**Mapping:**

| ACT `tool-definition` | MCP `Tool` |
|---|---|
| `name` | `name` |
| `description` | `description` (resolved to single language) |
| `parameters[*].schema` | Combined into `inputSchema` (JSON Schema object with `type: "object"`) |
| `parameters[*].description` | `inputSchema.properties[name].description` (resolved) |
| `parameters[*].required` | Collected into `inputSchema.required` array |
| `metadata` key `std:read-only` | `annotations.readOnlyHint` |
| `metadata` key `std:idempotent` | `annotations.idempotentHint` |
| `metadata` key `std:destructive` | `annotations.destructiveHint` |

**inputSchema construction:**

The adapter MUST construct a single JSON Schema object from the parameter list:

```json
{
  "type": "object",
  "properties": {
    "<param.name>": <param.schema with "description" injected>,
    ...
  },
  "required": ["<names of params where required=true>"]
}
```

ACT metadata keys with no MCP equivalent (`std:usage-hints`, `std:anti-usage-hints`, `std:examples`, `std:tags`, `std:timeout-ms`) are not included in the MCP response. The adapter MAY append `std:usage-hints` and `std:anti-usage-hints` values to the `description` string as additional paragraphs.

Response-level `metadata` from `list-tools-response` MAY be passed as MCP response extensions if applicable.

### 2.4 Tool Invocation — `tools/call`

When the MCP client calls `tools/call`:

1. The adapter constructs a `tool-call`:
   - `id` — from MCP JSON-RPC `id`
   - `name` — from `params.name`
   - `arguments` — `params.arguments` converted from JSON to dCBOR bytes
   - `metadata` — empty (or populated from MCP extensions if applicable)
2. The adapter calls `call-tool(config, call)` with the cached config.
3. The adapter receives a `call-response` containing `metadata` and `body: result<stream, tool-error>`.

**Result mapping (success — `body` is `ok(stream)`):**

The adapter reads all `stream-event::content(part)` events from the stream and collects them into the MCP response. Response-level `metadata` from `call-response` MAY be passed as MCP result extensions if applicable.

```json
{
  "content": [
    {
      "type": "<mapped from mime-type>",
      "text": "<content-part.data>"
    }
  ]
}
```

| ACT `content-part.mime-type` | MCP content type |
|---|---|
| `text/*` | `{ "type": "text", "text": "<data as UTF-8>" }` |
| `image/*` | `{ "type": "image", "data": "<data as base64>", "mimeType": "<mime-type>" }` |
| `application/cbor` (or absent) | `{ "type": "text", "text": "<data decoded from CBOR, serialized as JSON>" }` |
| Other | `{ "type": "text", "text": "<data as base64>" }` (fallback) |

**Result mapping (error):**

- Early error (`body` is `err(tool-error)`) → MCP error response with `isError: true`:
  ```json
  {
    "content": [{ "type": "text", "text": "<error.message>" }],
    "isError": true
  }
  ```
  Response-level `metadata` is still available on `call-response` even in the error path.

- Stream error (`stream-event::error`) → same format. Any content-parts received before the error are included in the response, followed by the error content.

**Error kind to MCP error code mapping:**

| ACT `tool-error.kind` | MCP JSON-RPC error code |
|---|---|
| `std:not-found` | `-32601` (Method not found) |
| `std:invalid-args` | `-32602` (Invalid params) |
| `std:timeout` | `-32001` (Server error) |
| `std:capability-denied` | `-32001` (Server error) |
| `std:internal` | `-32603` (Internal error) |

The adapter SHOULD use MCP tool result with `isError: true` for tool-level errors (`std:not-found`, `std:invalid-args`) and JSON-RPC error responses only for protocol-level failures.

### 2.5 Streaming via Progress Notifications

MCP does not natively support streaming tool results. When the client provides a `progressToken` in the tool call, the adapter MAY send intermediate content as `notifications/progress`:

```json
{
  "method": "notifications/progress",
  "params": {
    "progressToken": "<from request>",
    "progress": <parts_sent>,
    "total": null
  }
}
```

The adapter MAY include partial content in progress notification extensions. The final MCP result contains the complete accumulated content.

### 2.6 Cancellation

When the MCP client sends `notifications/cancelled` for an in-flight `tools/call`:

1. The adapter drops the ACT stream handle for the corresponding call.
2. The adapter returns an MCP error response with code `-32800` (Request cancelled).

---

## 3. HTTP Transport Binding

This section defines how an ACT host exposes components over HTTP with JSON (or CBOR) payloads.

### 3.1 Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/info` | Component metadata |
| `GET` | `/config-schema` | Config JSON Schema (or 204 if none) |
| `GET` | `/tools` | List tools |
| `POST` | `/tools/{name}` | Invoke a tool |

When the host serves multiple components, paths are prefixed with the component name:

| Method | Path | Description |
|---|---|---|
| `GET` | `/components` | List available components |
| `GET` | `/components/{component}/info` | Component metadata |
| `GET` | `/components/{component}/config-schema` | Config schema |
| `GET` | `/components/{component}/tools` | List tools |
| `POST` | `/components/{component}/tools/{name}` | Invoke a tool |

### 3.2 Content Negotiation

The adapter MUST support `application/json`. The adapter MAY support `application/cbor`.

The client signals preferred encoding via `Accept` and `Content-Type` headers. If no `Accept` header is provided, the adapter defaults to `application/json`.

Language selection uses the standard `Accept-Language` header.

### 3.3 Config Delivery

The client passes config via the `X-ACT-Config` header (base64-encoded JSON) or as a `config` field in the request body for POST requests.

```
GET /tools
X-ACT-Config: eyJzcGVjLXVybCI6Imh0dHBzOi8vLi4uIn0=
Accept-Language: en

200 OK
Content-Type: application/json

{
  "tools": [...]
}
```

For components that do not require config, the header is omitted and the adapter passes `none`.

The adapter MAY also support session-based config caching as an optimization (see Section 3.8).

### 3.4 Tool Discovery

The adapter calls `list-tools(config)` and returns a `list-tools-response`. Response-level `metadata` from `list-tools-response` MAY be mapped to HTTP response headers with an `X-ACT-Meta-` prefix.

```
GET /tools
X-ACT-Config: eyJzcGVjLXVybCI6Imh0dHBzOi8vLi4uIn0=
Accept-Language: ru

200 OK
Content-Type: application/json

{
  "tools": [
    {
      "name": "search_web",
      "description": "Поиск в интернете",
      "parameters": [ ... ],
      "metadata": { ... }
    }
  ]
}
```

On error (`tool-error`), the adapter returns the appropriate HTTP error status (see Section 3.6).

Localized strings in the response are resolved to the language requested via `Accept-Language`.

### 3.5 Tool Invocation

The adapter receives a `call-response` containing `metadata` and `body`. Response-level `metadata` from `call-response` MAY be mapped to HTTP response headers with an `X-ACT-Meta-` prefix.

**Non-streaming:**

```
POST /tools/search_web
X-ACT-Config: eyJzcGVjLXVybCI6Imh0dHBzOi8vLi4uIn0=
Content-Type: application/json

{
  "id": "call-1",
  "arguments": { "query": "rust wasm", "limit": 5 }
}

200 OK
Content-Type: application/json

{
  "id": "call-1",
  "content": [
    { "data": "...", "mime_type": "text/plain" },
    { "data": "AQIDBA==", "mime_type": "image/png" }
  ]
}
```

Each `content-part` is serialized as a JSON object with `data` (text or base64 for binary), `mime_type` (string or null for default `application/cbor`), and optional `metadata`. The adapter collects all stream events and returns the complete result.

**Streaming (Server-Sent Events):**

When the client includes `Accept: text/event-stream`, the adapter streams results as SSE:

```
POST /tools/search_web
X-ACT-Config: eyJzcGVjLXVybCI6Imh0dHBzOi8vLi4uIn0=
Content-Type: application/json
Accept: text/event-stream

{
  "id": "call-1",
  "arguments": { "query": "rust wasm", "limit": 5 }
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
data: {"kind": "std:internal", "message": "Connection to search provider lost"}
```

The `error` and `done` events are terminal — the stream closes after either.

### 3.6 Error Responses

| ACT `tool-error.kind` | HTTP status |
|---|---|
| `std:not-found` | `404 Not Found` |
| `std:invalid-args` | `422 Unprocessable Entity` |
| `std:timeout` | `504 Gateway Timeout` |
| `std:capability-denied` | `403 Forbidden` |
| `std:internal` | `500 Internal Server Error` |

Error response body:

```json
{
  "error": {
    "kind": "std:invalid-args",
    "message": "Parameter 'limit' must be a positive integer"
  }
}
```

For early errors (before streaming), the adapter returns the appropriate HTTP status code. For stream errors during SSE, the adapter sends an `event: error` SSE event and closes the connection.

### 3.7 Cancellation

The client cancels a streaming request by closing the HTTP connection. The adapter drops the ACT stream handle, triggering cancellation as defined in ACT-SPEC Section 4.4.

### 3.8 Optional Session Optimization

For clients that make multiple calls with the same config, the adapter MAY offer a session mechanism to avoid repeating config on every request:

```
POST /sessions
Content-Type: application/json

{
  "component": "openapi-bridge",
  "config": {
    "spec-url": "https://api.example.com/openapi.json",
    "auth-header": "Bearer sk-..."
  }
}

200 OK
{
  "session_id": "abc123",
  "idle_timeout_ms": 300000
}
```

Once a session is established, the client uses it in place of `X-ACT-Config`:

```
GET /sessions/abc123/tools
POST /sessions/abc123/tools/search_web
DELETE /sessions/abc123
```

This is purely a transport optimization. The adapter internally passes the cached config to `list-tools` and `call-tool` on every invocation. The component is unaware of sessions.

---

## 4. Conformance

### 4.1 Conformant MCP Adapter

A conformant MCP transport adapter:
- MUST resolve config from host configuration or MCP `initialize` extensions and convert it to dCBOR before passing to the component.
- MUST convert JSON arguments from MCP `tools/call` to dCBOR bytes for `tool-call.arguments`.
- MUST translate `tools/list` and `tools/call` as defined in Sections 2.3–2.4, including `list-tools-response` and `call-response` handling.
- MUST resolve localized strings to a single language before sending MCP responses.
- MUST map `tool-definition.metadata` keys `std:read-only`, `std:idempotent`, `std:destructive` to MCP annotation hints.
- MUST map `tool-error.kind` values with `std:` prefix to MCP error codes as defined in Section 2.4.
- MUST propagate MCP cancellation to ACT stream handle drops.

### 4.2 Conformant HTTP Adapter

A conformant HTTP transport adapter:
- MUST support config delivery via `X-ACT-Config` header and convert it to dCBOR before passing to the component.
- MUST convert JSON arguments from request body to dCBOR bytes for `tool-call.arguments`.
- MUST support `application/json` content type.
- MUST support `Accept-Language` for localization.
- MUST map `tool-error.kind` values with `std:` prefix to HTTP status codes as defined in Section 3.6.
- MUST support non-streaming tool invocation with `call-response` handling.
- SHOULD support SSE streaming via `Accept: text/event-stream`.
- SHOULD map response-level `metadata` from `list-tools-response` and `call-response` to HTTP response headers.
