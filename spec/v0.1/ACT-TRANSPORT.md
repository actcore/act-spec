# ACT Transport Bindings

**Version 0.1.2 (Draft)**

This document specifies how ACT protocol operations map to external transport protocols. It is a companion to the core ACT specification (`ACT-SPEC.md`).

---

## 1. General Principles

### 1.1 Transport Independence

The ACT core protocol defines a component-level contract (WIT interfaces). Transport bindings translate between external protocols and ACT host calls. A conformant ACT host MAY support multiple transports simultaneously.

The HTTP binding is specified as a standalone document (`ACT-HTTP.md`) that can be implemented without WebAssembly components. The MCP binding (Section 2) defines how an ACT host maps component calls to the MCP protocol.

### 1.2 Stateless Design

ACT components are stateless. Each call to `list-tools` or `call-tool` carries all necessary context via the optional `config` parameter.

### 1.3 Config Delivery

Components that require configuration (as declared by `get-config-schema`) receive it as `option<list<u8>>` — dCBOR-encoded bytes (RFC 8949 §4.2) — in every `list-tools` and `call-tool` invocation. Config is analogous to HTTP headers — it carries per-call context (credentials, endpoint URLs, preferences) orthogonal to tool arguments.

Transport adapters accept config in the transport-native format (JSON, HTTP headers, etc.) and convert it to dCBOR before passing it to the component. The host ensures config bytes are valid dCBOR.

Transport adapters map config to the natural mechanism for each transport:

| Transport | Config mechanism |
|---|---|
| MCP stdio | Host-level configuration (command-line args, config file, environment) |
| MCP SSE | Extensions in `initialize` request params |
| HTTP (`QUERY`/`POST`) | `config` field in request body (JSON) |
| HTTP (`GET` fallback) | `X-ACT-Config` header (base64-encoded JSON) |

The host MAY merge config from multiple sources (e.g. server defaults + client-provided values) before passing it to the component.

### 1.4 Bridge Components

A bridge component adapts an external protocol into the ACT `tool-provider` interface. The bridge fetches a remote schema or spec, maps discovered operations to `list-tools`, and translates `call-tool` invocations into the external protocol's native calls.

The general pattern:

```
External protocol     ACT tool-provider
  discovery       →     list-tools
  invoke          →     call-tool
  schema          →     parameters-schema
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
| `parameters-schema` | `inputSchema` (passed through as JSON Schema) |
| `metadata` key `std:read-only` | `annotations.readOnlyHint` |
| `metadata` key `std:idempotent` | `annotations.idempotentHint` |
| `metadata` key `std:destructive` | `annotations.destructiveHint` |

**inputSchema construction:**

The `parameters-schema` is already a JSON Schema object with `type: "object"`, `properties`, and `required`. The adapter passes it through as the MCP `inputSchema`, resolving any localized descriptions (e.g. JSON Structure `altnames`) to the client's preferred language as plain `description` fields.

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
3. The adapter receives a `call-response` containing `metadata` and a `body` stream of `stream-event` values.

**Result mapping (success):**

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

If the stream contains a `stream-event::error(tool-error)`, the adapter returns an MCP error response with `isError: true`. Any content-parts received before the error are included in the response, followed by the error content.

```json
{
  "content": [{ "type": "text", "text": "<error.message>" }],
  "isError": true
}
```

Response-level `metadata` on `call-response` is always available, regardless of whether the stream contains an error.

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

The HTTP transport binding is specified as a standalone document: **`ACT-HTTP.md`**.

The ACT HTTP API is a self-contained specification — any HTTP server conforming to `ACT-HTTP.md` is a valid implementation, with or without WebAssembly components. This makes the ACT HTTP API usable as a lightweight, stateless alternative to MCP for tool integration.

When an ACT host exposes components over HTTP, the adapter translates between the HTTP API and component calls:

- `GET /tools` or `QUERY /tools` → `list-tools(config)`, with `localized-string` values resolved to the language requested via `Accept-Language`.
- `POST /tools/{name}` → `call-tool(config, call)`, with JSON arguments converted to dCBOR bytes.
- Config from request body (`config` field) or `X-ACT-Config` header (base64-encoded JSON, fallback for GET) is decoded and converted to dCBOR before passing to the component.
- Response-level `metadata` from `list-tools-response` and `call-response` MAY be mapped to HTTP response headers with an `X-ACT-Meta-` prefix.
- Cancellation: client closes the HTTP connection → adapter drops the ACT stream handle (Section 4.4 of ACT-SPEC).

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

A conformant HTTP transport adapter MUST produce an HTTP API conforming to `ACT-HTTP.md` (Section 11). In addition:
- MUST convert JSON config (from request body or `X-ACT-Config` header) to dCBOR before passing to the component.
- MUST convert JSON arguments from request body to dCBOR bytes for `tool-call.arguments`.
- MUST resolve `localized-string` values to the language requested via `Accept-Language`.
- SHOULD support `QUERY /tools` with config in request body.
- SHOULD map response-level `metadata` from `list-tools-response` and `call-response` to HTTP response headers with an `X-ACT-Meta-` prefix.
