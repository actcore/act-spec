# ACT–MCP Mapping Guide (Informative)

**Version 0.3.0**

This document describes how ACT components can be exposed as MCP-compatible servers. It is an **informative guide** for implementors of MCP↔ACT adapters, not a normative specification. Implementations MAY deviate from these recommendations where appropriate.

For the normative ACT specifications, see `ACT-SPEC.md` and `ACT-HTTP.md`.

---

## 1. Overview

An MCP↔ACT adapter translates between the Model Context Protocol and ACT component calls. The adapter loads an ACT component and exposes it as an MCP server, mapping MCP `tools/*` requests to ACT `tool-provider` calls. Event and resource mappings (for the informative `event-provider` / `resource-provider` interfaces) are documented alongside those interfaces in `ACT-EVENTS.md` and `ACT-RESOURCES.md`.

### 1.1 Server Identity

The MCP `initialize` response should include:

```json
{
  "protocolVersion": "2025-11-25",
  "serverInfo": {
    "name": "<name from WASM metadata>",
    "version": "<version from WASM metadata>"
  },
  "capabilities": {
    "tools": {}
  }
}
```

### 1.2 Metadata Resolution

For MCP stdio, metadata is typically fixed for the lifetime of the process. The adapter obtains metadata from:

1. Command-line arguments or a configuration file provided at server startup.
2. Extensions in the MCP `initialize` request params (if the client provides them).

The adapter caches the resolved metadata and passes it to every `list-tools` and `call-tool` invocation.

For components that do not require metadata (`get-metadata-schema([])` returns `none`), the adapter passes empty metadata.

---

## 2. Tool Mapping

### 2.1 Tool Discovery — `tools/list`

When the MCP client calls `tools/list`, the adapter calls `list-tools(metadata)` and translates each `tool-definition` to an MCP tool object.

**Recommended mapping:**

| ACT `tool-definition` | MCP `Tool` |
|---|---|
| `name` | `name` |
| `description` | `description` (resolved to single language) |
| `parameters-schema` | `inputSchema` (passed through as JSON Schema) |
| `metadata` key `std:read-only` | `annotations.readOnlyHint` |
| `metadata` key `std:idempotent` | `annotations.idempotentHint` |
| `metadata` key `std:destructive` | `annotations.destructiveHint` |

The `parameters-schema` is already a JSON Schema object with `type: "object"`, `properties`, and `required`. The adapter passes it through as the MCP `inputSchema`, resolving any localized descriptions to the client's preferred language.

ACT metadata keys with no MCP equivalent (`std:usage-hints`, `std:anti-usage-hints`, `std:examples`, `std:tags`, `std:timeout-ms`) are not included in the MCP response. The adapter MAY append `std:usage-hints` and `std:anti-usage-hints` values to the `description` string as additional paragraphs.

### 2.2 Tool Invocation — `tools/call`

When the MCP client calls `tools/call`:

1. The adapter constructs a `tool-call`:
   - `name` — from `params.name`
   - `arguments` — `params.arguments` converted from JSON to dCBOR bytes
   - `metadata` — the cached metadata (merged with any per-request metadata from MCP extensions)
2. The adapter calls `call-tool(call)`.
3. The adapter receives a `tool-result` and dispatches on the variant (`immediate` or `streaming`). In both cases, it reads `tool-event`s in order. For MCP transports that do not support partial results (e.g. stdio), the adapter MUST buffer `streaming` events into a single accumulated MCP response before returning. The adapter SHOULD bound the buffer size to protect against unbounded upstream streams; see ACT-SPEC §4.3.2 for conversion guidance. See §2.3 for progress notifications as a partial-streaming workaround.

**Result mapping (success):**

The adapter collects all `tool-event::content(part)` events and maps them to the MCP response.

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
| `application/cbor` | `{ "type": "text", "text": "<data decoded from CBOR, serialized as JSON>" }` |
| `application/json` | `{ "type": "text", "text": "<data as UTF-8>" }` |
| absent or other | `{ "type": "text", "text": "<data as base64>" }` (fallback) |

**Result mapping (error):**

If the event sequence contains a `tool-event::error(tool-error)`, the adapter returns an MCP error response with `isError: true`. Any content-parts received before the error are included in the response, followed by the error content.

```json
{
  "content": [{ "type": "text", "text": "<error.message>" }],
  "isError": true
}
```

**Recommended error kind to MCP error code mapping:**

| ACT `tool-error.kind` | MCP JSON-RPC error code |
|---|---|
| `std:not-found` | `-32601` (Method not found) |
| `std:invalid-args` | `-32602` (Invalid params) |
| `std:timeout` | `-32001` (Server error) |
| `std:capability-denied` | `-32001` (Server error) |
| `std:internal` | `-32603` (Internal error) |

The adapter should prefer MCP tool result with `isError: true` for tool-level errors and JSON-RPC error responses only for protocol-level failures.

### 2.3 Streaming via Progress Notifications

MCP does not natively support streaming tool results. When the client provides a `progressToken` in the tool call, the adapter MAY send intermediate content as `notifications/progress`:

```json
{
  "method": "notifications/progress",
  "params": {
    "progressToken": "<from request>",
    "progress": "<parts_sent>",
    "total": null
  }
}
```

The adapter MAY include partial content in progress notification extensions. The final MCP result contains the complete accumulated content.

### 2.4 Cancellation

When the MCP client sends `notifications/cancelled` for an in-flight `tools/call`:

1. If `call-tool` has not yet returned, the adapter triggers runtime-level cancellation (epoch/fuel) on the component instance. If `call-tool` has returned `streaming`, the adapter drops the stream handle. See ACT-SPEC §4.4.
2. The adapter returns an MCP error response with code `-32800` (Request cancelled).

