---
title: ACT–MCP Mapping Guide
version: 0.4.0
status: informative
---

# ACT–MCP Mapping Guide

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

For components that do not require metadata, the adapter passes empty metadata.

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
   - `arguments` — `params.arguments` (with `_meta` removed per §3.2) converted from JSON to dCBOR bytes
   - `metadata` — the cached metadata, merged with per-request metadata from two sources: (a) the `_meta` object property in `params.arguments` (the *argument metadata channel*; see §3.2), and (b) the transport-level `_meta` field on the MCP request (the *transport metadata channel*; see §3.1). Precedence rules in §3.3.
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

If the event sequence contains a `tool-event::error(error)`, the adapter returns an MCP error response with `isError: true`. Any content-parts received before the error are included in the response, followed by the error content.

```json
{
  "content": [{ "type": "text", "text": "<error.message>" }],
  "isError": true
}
```

**Recommended error kind to MCP error code mapping:**

| ACT `error.kind` | MCP JSON-RPC error code |
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

---

## 3. Metadata Propagation

ACT calls carry a `metadata` parameter (`list<tuple<string, string>>` in WIT) used for cross-cutting concerns like `std:session-id`, `std:traceparent`, `std:locale`. Over MCP, an adapter has two channels for moving this metadata between the agent and the component, and MUST handle both.

### 3.1 Transport Metadata Channel

MCP's `tools/call` request envelope carries a `_meta` field at the params level. The adapter SHOULD read this field and merge its entries into the WIT `metadata` parameter of `call-tool`.

In current deployment, LLM-driven MCP clients (agent harnesses such as Claude Code, Claude Desktop, Cursor) treat the transport `_meta` field as client-as-system territory and do not expose it to the model. The model therefore cannot use this channel to attach `std:session-id` or other agent-controlled keys. The argument metadata channel (§3.2) exists to fill this gap.

### 3.2 Argument Metadata Channel

The adapter extends the published `inputSchema` of a tool with an optional `_meta` object property whose values carry well-known `std:*` keys. The agent supplies metadata by including `_meta` in the JSON arguments of `tools/call`.

Recommended injected schema fragment:

```json
{
  "_meta": {
    "type": "object",
    "description": "ACT metadata. Include {\"std:session-id\": \"<id from open_session>\"} for session-bound tools. Other recognized keys: std:traceparent, std:locale.",
    "additionalProperties": true
  }
}
```

The injection MUST be performed even when the component-declared schema sets `additionalProperties: false`; the adapter rewrites the schema so that `_meta` is admitted as a known property while the original restriction on other keys is preserved.

On `tools/call`, the adapter:

1. Removes `_meta` from `params.arguments` before validating the remaining arguments against the component's original (non-injected) schema.
2. Flattens the removed `_meta` object into entries of the WIT `metadata` parameter of `call-tool` (one tuple per key-value pair).
3. Merges with metadata from the transport channel (§3.1) per §3.3.

Adapters MUST inject `_meta` into tools of any component exporting `act:sessions/session-provider`. Adapters MAY inject `_meta` for all tools regardless of session-provider export; the cost is one optional property in the schema, and it lets agents pass keys like `std:traceparent` end-to-end uniformly.

### 3.3 Precedence and Merge

When both transport `_meta` (§3.1) and argument `_meta` (§3.2) carry the same key, **transport `_meta` takes precedence**: it represents the MCP client acting as a system, whereas argument `_meta` represents the LLM agent. For keys present in only one source, that source supplies the value. The merged result, combined with adapter-cached metadata (§1.2), forms the `metadata` parameter passed to `call-tool`.

---

## 4. Session-Provider Adaptation

When the loaded component exports `act:sessions/session-provider@0.1.0`, the adapter additionally synthesizes session lifecycle operations as virtual tools.

### 4.1 Synthesized Tools

| Name | Description | inputSchema | Tool metadata |
|---|---|---|---|
| `open_session` | Open a new session | from `get-open-session-args-schema` | `_meta.std:session-op` = `"open"` |
| `close_session` | Close an open session | `{type: "object", properties: {session_id: {type: "string"}}, required: ["session_id"]}` | `_meta.std:session-op` = `"close"` |

The names `open_session` and `close_session` are reserved (see `ACT-CONSTANTS.md` §3.1); components MUST NOT define tools with these names.

`tools/call open_session` invokes `open-session`; the result is returned as a single content part containing the CBOR-encoded `session` record. The agent extracts `session.id` from the response and reuses it in subsequent calls (§4.2).

`tools/call close_session` invokes `close-session(session_id)` and returns an empty content list. The `session_id` is a positional argument here because it is the *object* of the close operation, not contextual metadata.

### 4.2 Session-Id Propagation

For non-synthesized tools of a session-provider component, the agent supplies `std:session-id` through the argument metadata channel (§3.2):

```json
{
  "name": "query",
  "arguments": {
    "sql": "SELECT 1",
    "_meta": {"std:session-id": "sid_pg_42"}
  }
}
```

The adapter extracts `_meta.std:session-id`, includes it in the WIT `metadata` of `call-tool`, and the component routes the call to the matching session.

