---
title: ACT Sessions
version: 0.4.0
status: normative
requires: [act:core@0.4.0, act:sessions@0.1.0]
---

# ACT Sessions

This document specifies `act:sessions@0.1.0` — the optional WIT package providing component-side stateful sessions for ACT components.

A session is a component-side state container with an explicit lifecycle. Sessions exist for components that maintain stateful resources tied to logical units of work — database connections, MCP/OpenAPI client sessions, REPL processes, SSH connections, browser tabs, and similar. Stateless components (pure functions, simple API forwarders) do not export session-provider.

`act:sessions@0.1.0` is **independent and opt-in**. A component MAY export `act:sessions/session-provider` together with `act:tools/tool-provider`, alone, or alongside other capability interfaces. Hosts MUST detect the export and adapt their lifecycle accordingly.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in RFC 2119.

---

## 1. Package and Interface

### 1.1 Package

```wit
package act:sessions@0.1.0;
```

### 1.2 Interface

```wit
interface session-provider {
  use act:core/types@0.4.0.{metadata, error};

  record session {
    id: string,
    metadata: metadata,
  }

  get-open-session-args-schema: async func(metadata: metadata)
    -> result<string, error>;
  open-session: async func(args: metadata, metadata: metadata)
    -> result<session, error>;
  close-session: func(session-id: string);
}
```

### 1.3 World Export

A component that exports session-provider declares it in its world:

```wit
world act-world {
  export act:tools/tool-provider@0.1.0;
  export act:sessions/session-provider@0.1.0;
}
```

A component MAY export `session-provider` without `tool-provider` (e.g., a future component that exposes only resources tied to sessions).

---

## 2. Session Lifecycle

### 2.1 Discovery

Before opening a session, the agent or host SHOULD call `get-open-session-args-schema(metadata)` to retrieve the JSON Schema describing valid `args`. The returned string is a JSON Schema document of `type: "object"`.

The host MUST validate `args` to `open-session` against this schema. If validation fails, the host MUST return an `error` with kind `std:invalid-args` without calling `open-session`.

For initial discovery (no parent session), `metadata` is empty. For nested-session discovery (bridge components), `metadata` includes `std:session-id` of the parent session — see Section 5.

### 2.2 Open

`open-session(args, metadata)` creates a new session and returns its identifier.

1. The host validates `args` against the schema from `get-open-session-args-schema(metadata)` (Section 2.1).
2. The host invokes `open-session(args, metadata)`.
3. The component allocates state, performs any required external connections, and returns either:
   - `result::ok(session)` with a freshly allocated session-id, or
   - `result::err(error)` indicating failure (auth rejected, capacity exhausted, network unreachable, etc.). Common error kinds: `std:invalid-args`, `std:capability-denied`, `std:internal`.
4. On success, the host MUST track the returned session-id for the lifetime of the session and pass it in `std:session-id` metadata for subsequent capability calls (Section 3).

The component chooses the format of session-id (UUID, counter, opaque blob). The host treats it as opaque.

### 2.3 Use

Subsequent capability calls reference an open session by including `std:session-id` in their metadata:

- `call-tool` — `metadata` carries `std:session-id` for session-bound tool calls.
- `event-provider.subscribe` (if exported) — `metadata` carries `std:session-id` for session-scoped event streams.
- `resource-provider.get-resource` and `list-resources` (if exported) — `metadata` carries `std:session-id` for session-scoped resources.
- Future capability interfaces accepting metadata — same convention.

For components that export both `tool-provider` and `session-provider`, `list-tools(metadata)` MAY return different tool sets depending on `std:session-id` in metadata. This is the expected behavior for bridge components (a session may correspond to a remote that exposes a particular tool catalog).

If a tool-call references a session-id the component does not recognize (closed, never existed, NAT mismatch), the component MUST return an `error` with kind `std:session-not-found`.

### 2.4 Close

`close-session(session-id)` is a polite shutdown signal.

- Synchronous, returns no value, errors are not signalled.
- The component MAY perform asynchronous cleanup internally (spawn-and-forget) but MUST NOT block the host.
- Host MUST call `close-session` for every session it opened, before component deinit.
- Components MUST tolerate sessions disappearing without `close-session` (host crash, transport drop) — `close-session` is advisory.

If the host calls `close-session` with an unknown session-id, the component MUST behave as a no-op.

### 2.5 Component Deinit

Component deinitialization is when the host drops the WASM instance — for example on graceful shutdown, idle eviction, or after an unrecoverable error. Before this point:

1. The host MUST call `close-session` for every still-open session it tracked for that instance.
2. The order of `close-session` calls is unspecified but SHOULD be reverse open-order.
3. After all `close-session` calls, the host proceeds with deinit (drops the WASM instance, releases host-side resources).

If the host crashes or exits without performing deinit (panic, OOM, kill -9), components MUST tolerate the loss — `close-session` is advisory, not a guarantee (Section 2.4).

---

## 3. Session-Id Propagation

### 3.1 Metadata Key

The well-known metadata key `std:session-id` carries the session identifier in subsequent capability calls. Its CBOR-encoded value is a string matching the `id` field of the `session` returned by `open-session`.

Registered in `ACT-CONSTANTS.md` Section 5.

### 3.2 NAT-Style Rewriting

Hosts and intermediaries (bridges, toolservers, harnesses) MAY rewrite `session-id` values when forwarding between agents and components.

A component generates session-ids in its own namespace. A bridge or toolserver between the agent and the component MAY perform a 1-to-1 mapping, presenting the agent with rewritten ids while preserving the component's internal ids when forwarding capability calls back to it.

Components MUST NOT rely on session-ids being unchanged outside their boundary. Implementations MAY use this to:

- Hide internal identifier formats (security).
- Multiplex one component instance across multiple agent namespaces.
- Swap underlying component instances while preserving the agent-visible id (toolserver-managed migration).

The agent MUST treat session-ids as opaque strings.

---

## 4. Authentication

Session args is the canonical place for component-to-external credentials in ACT. Well-known credential keys (`std:bearer-token`, `std:api-key`, `std:username`, `std:password`) and OAuth flow advertisement (`x-act-authorization-server`, `x-act-scopes` JSON Schema annotations) are normatively specified in `ACT-AUTH.md`.

---

## 5. Bridges and Nested Sessions

A bridge component (e.g. `act-http-bridge`, `mcp-bridge`, `openapi-bridge`) maintains its own connection-level session AND forwards downstream sessions of the system it bridges to.

### 5.1 Two-Tier Schema Discovery

For top-level discovery (`metadata = []`), the bridge returns its own connection args-schema (URL + credentials). Once a connection session is open, the agent calls `get-open-session-args-schema(metadata=[("std:session-id", parent)])` to discover the schema for opening a child session through that parent. The bridge MAY perform I/O against the upstream to fetch the upstream's schema.

### 5.2 Nested Open

`open-session(args, metadata)` with `metadata` containing `std:session-id` opens a child session. The bridge validates `args` against the child schema (from Section 5.1), proxies the open to the upstream (using its connection from the parent session), and returns a new session whose id MAY be a NAT-mapped representation of the upstream's session-id.

### 5.3 Capability Forwarding

For `call-tool` (and other capability calls) the agent uses the child session-id. The bridge resolves child → parent → upstream connection, rewrites session-id back to the upstream's representation if needed, and forwards the call.

### 5.4 Bridge Close

Closing a parent session cascades: the bridge MUST `close-session` on the upstream for every child session opened through the parent, before tearing down the parent connection.

### 5.5 Example: act-http-bridge

```
agent → bridge:
  get-open-session-args-schema(metadata=[])
  → bridge returns its own connection args-schema (std:url, std:bearer-token)

agent → bridge:
  open-session(
    args=[("std:url", "https://remote.example.com"),
          ("std:bearer-token", "...")],
    metadata=[]
  )
  → session A (bridge connection)

agent → bridge:
  get-open-session-args-schema(metadata=[("std:session-id", A)])
  → bridge fetches remote args-schema via A, returns it

agent → bridge:
  open-session(
    args=<remote args>,
    metadata=[("std:session-id", A)]
  )
  → bridge proxies remote.open-session(args)
  → session B (NAT'd remote session)

agent → bridge:
  call-tool(
    name="remote_tool",
    arguments=...,
    metadata=[("std:session-id", B)]
  )
  → bridge resolves B → routes via A → calls upstream remote_tool

agent → bridge:
  close-session(B)
  → bridge calls remote.close-session(remote_id_for_B)

agent → bridge:
  close-session(A)
  → bridge tears down its connection to remote (any still-open children
    are cascaded-closed first)
```

---

## 6. Transport Adapter Behavior

Session lifecycle is exposed to agents via transport adapters. Adapters synthesize session-ops as virtual tools or endpoints.

### 6.1 MCP

The adapter synthesizes two virtual tools in `tools/list` for components exporting session-provider:

| Name | Description | inputSchema | Tool metadata |
|---|---|---|---|
| `open_session` | Open a new session | from `get-open-session-args-schema` | `_meta.std:session-op` = `"open"` |
| `close_session` | Close an open session | `{type: "object", properties: {session_id: {type: "string"}}, required: ["session_id"]}` | `_meta.std:session-op` = `"close"` |

The names `open_session` and `close_session` are reserved (see `ACT-CONSTANTS.md`); components MUST NOT define tools with these exact names.

`tools/call open_session` invokes `open-session`; the result is returned as a single content part containing the CBOR-encoded `session` record.

`tools/call close_session` invokes `close-session` and returns an empty content list.

For other capability calls, the agent passes `std:session-id` via `_meta` of the MCP request; the adapter forwards it as `("std:session-id", cbor(<id>))` in the call's metadata.

### 6.2 ACT-HTTP

Sessions are exposed as REST endpoints, following the `POST`/`QUERY` duality used elsewhere in ACT-HTTP:

| Method | Path | Description |
|---|---|---|
| `POST` | `/sessions/open-args-schema` | Returns args-schema; metadata in body |
| `QUERY` | `/sessions/open-args-schema` | Same as `POST`; safe and cacheable |
| `POST` | `/sessions` | Open session; body = `{args, metadata}`; `201 Created` with session record |
| `DELETE` | `/sessions/{id}` | Close session; `204 No Content` |

Subsequent capability calls reference the session via `std:session-id` in request body metadata or `X-Act-Session-Id` header.

### 6.3 CLI

```
act session open-args-schema <component> [--metadata '{...}']
act session open <component> --args '{...}' [--metadata '{...}']
act session close <component> <session-id>
```

`act session open` prints the session record (id + metadata) as JSON to stdout. The session-id can be reused in subsequent `act call` invocations via `--metadata '{"std:session-id":"..."}'`.

---

## 7. Conformance

### 7.1 Conformant Component

A component that exports `act:sessions/session-provider@0.1.0`:

- MUST implement all three functions: `get-open-session-args-schema`, `open-session`, `close-session`.
- MUST return a valid JSON Schema string of `type: "object"` from `get-open-session-args-schema` for any valid `metadata` input. The schema MUST describe all keys the component honors in `args`.
- SHOULD re-validate `args` against its own schema in `open-session` as defense-in-depth (the host is normatively required to pre-validate per Section 2.1).
- MUST allocate a session-id unique within the component instance for each successful `open-session`. Globally unique values (e.g. UUIDs) are RECOMMENDED.
- MUST recognize session-ids it issued and accept them in subsequent capability calls' metadata.
- MUST return `error` with kind `std:session-not-found` for capability calls referencing unknown session-ids.
- `close-session` MUST return promptly without performing blocking I/O. Background cleanup MAY be performed via spawn-and-forget.
- MUST tolerate sessions disappearing without `close-session` (host crash, transport drop).

### 7.2 Conformant Host

A host that supports `act:sessions/session-provider@0.1.0`:

- MUST detect the `session-provider` export and surface session lifecycle to clients (Section 6).
- MUST validate `args` against `get-open-session-args-schema(metadata)` before calling `open-session`.
- MUST track open session-ids for each component instance.
- MUST call `close-session` for every still-open session before deinitializing the component instance.
- MUST propagate `std:session-id` metadata from agent capability calls to the component.
- MAY rewrite session-ids for security or multiplexing (Section 3.2). When rewriting, the host MUST maintain a 1-to-1 mapping between external and internal ids for the lifetime of the session.

---

## 8. Security Considerations

### 8.1 Session-Id Confidentiality

Session-ids are bearer tokens within the component-host boundary: a holder of a valid session-id can invoke capabilities against that session. Hosts MUST NOT expose a session-id to any party other than the agent that opened it. NAT-style rewriting (Section 3.2) is RECOMMENDED for hosts serving multiple agents to prevent cross-agent session-id leakage.

### 8.2 Session Resource Limits

Components SHOULD enforce limits on the number of concurrent sessions per host instance, returning `error` with an appropriate vendor-namespaced kind (e.g. `acme:capacity-exceeded`) when capacity is exhausted. Hosts SHOULD configure per-component session quotas.

### 8.3 Auth in Session Args

Credentials passed via `open-session.args` (per `ACT-AUTH.md`) MUST be transmitted over confidential channels (TLS for HTTP transport, OS-level isolation for stdio). See `ACT-AUTH.md` Section 5 for full guidance.

### 8.4 Cleanup Guarantees

`close-session` is best-effort. Components handling expensive resources (long-lived TCP connections, subprocesses, file locks) SHOULD implement secondary cleanup mechanisms (idle timeout, connection-level keepalive failure detection) to avoid resource leaks when hosts crash mid-flight.

---

## Appendix A: Worked Example — postgres-client

A stateful Postgres client component.

**`act.toml`:**

```toml
[std]
name = "postgres-client"
version = "0.1.0"
description = "PostgreSQL client"

[std.capabilities."wasi:sockets"]
allow = [{ host = "*" }]
```

**World export:**

```wit
world act-world {
  export act:tools/tool-provider@0.1.0;
  export act:sessions/session-provider@0.1.0;
}
```

**Args-schema (returned by `get-open-session-args-schema(metadata=[])`):**

```json
{
  "type": "object",
  "properties": {
    "std:url": {
      "type": "string",
      "format": "uri",
      "description": "libpq connection string"
    },
    "std:host":     {"type": "string"},
    "std:port":     {"type": "integer", "default": 5432},
    "std:database": {"type": "string"},
    "std:username": {"type": "string"},
    "std:password": {"type": "string"},
    "pg:sslmode":   {"type": "string", "enum": ["disable", "prefer", "require", "verify-ca", "verify-full"]},
    "pg:sslcert":   {"type": "string", "description": "Client cert PEM"},
    "pg:sslkey":    {"type": "string", "description": "Client key PEM"}
  },
  "oneOf": [
    {"required": ["std:url"]},
    {"required": ["std:host", "std:database", "std:username"]}
  ]
}
```

**Open + use:**

```
open-session(
  args=[("std:url", cbor("postgres://alex@db.example.com/myapp")),
        ("std:password", cbor("s3cret"))],
  metadata=[("std:traceparent", cbor("00-..."))]
)
→ session { id: "sid_pg_42", metadata: [] }

call-tool(
  name="query",
  arguments=cbor({"sql": "SELECT * FROM docs WHERE id = $1", "params": [42]}),
  metadata=[("std:session-id", cbor("sid_pg_42"))]
)
→ tool-result with rows

close-session("sid_pg_42")
→ component drops Connection, removes from session map
```

---

## Appendix B: Migration Notes

### B.1 Anchor-Stream Pattern (Deprecated)

Pre-`act:sessions` ACT components achieved session-like behavior via the *anchor-stream pattern*: a tool whose `tool-result` is `streaming` and whose stream lifetime equals the session lifetime; the component drops session state via Rust's `Drop` when the host releases the stream. This pattern is documented in `components/AGENTS.md` (current at time of writing) and should be considered superseded by `session-provider`.

Components currently using anchor-stream SHOULD migrate to `session-provider` for new development; the anchor-stream pattern remains observable behavior but is no longer recommended.

### B.2 Single-Tenant API Clients

A previously-considered alternative was static `[std.auth.<scheme>]` declaration in `act:component` for stateless components with per-call auth. This approach was rejected; auth is unified through session args. Trivial API clients (one credential, no other state) become "session-of-1" components — open one session at startup, all calls use it. SDKs SHOULD provide ergonomic helpers (e.g. `@requires_auth(BearerToken)` decorator) to reduce boilerplate.
