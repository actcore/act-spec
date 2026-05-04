---
title: ACT Authentication
version: 0.4.0
status: normative
requires: [act:core@0.4.0, act:tools@0.1.0, act:sessions@0.1.0]
---

# ACT Authentication

This document specifies how authentication is handled in ACT. It covers two independent layers:

1. **Component-to-external auth** — credentials a component uses to authenticate with external services (databases, APIs). Normative; primary subject of this document.
2. **Client-to-host auth** — how a client (agent, CLI, browser) authenticates to the ACT host. Normative for HTTP transports; informative for stdio.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in RFC 2119.

---

## 1. Component-to-External Authentication

Credentials a component uses to authenticate with the external service it wraps (Postgres password, Anthropic API key, GitHub bearer token, …) are delivered via session args. This is the **single normative mechanism** for component-to-external auth in ACT.

### 1.1 Sessions as the Auth Boundary

A component requiring authentication exports `act:sessions/session-provider@0.1.0` (see `ACT-SESSIONS.md`) and accepts credentials in `open-session.args`:

```
open-session(
  args = [
    ("std:bearer-token", cbor("sk-ant-...")),
    ("anthropic:org-id", cbor("org_42"))
  ],
  metadata = []
)
→ session { id: "...", metadata: [] }
```

The component validates credentials at open time, stores them associated with the session, and uses them for subsequent capability calls referencing that session via `std:session-id` metadata.

Components that perform no external authentication (pure functions: crypto, encoding, random, time, …) SHOULD NOT export `session-provider`.

A "session-of-1" pattern is a component with a single fixed credential and no other state, where the agent (or host operator) provides the credential once and all subsequent calls reuse it. Such components SHOULD still export `session-provider` (one open at startup, all calls share the resulting session-id). Hosts MAY pre-open this session on the agent's behalf when the credential is known from operator configuration. SDKs SHOULD provide ergonomic helpers (e.g. an `@requires_auth` decorator) to reduce boilerplate.

### 1.2 Well-Known Credential Keys

Defined in `ACT-CONSTANTS.md` Section 7:

| Key | Type | Use |
|---|---|---|
| `std:bearer-token` | string | OAuth/OIDC bearer or generic bearer-style token |
| `std:api-key` | string | API key (component decides which header to use upstream) |
| `std:username` | string | Basic auth |
| `std:password` | string | Basic auth |

Component-specific credential fields use vendor prefixes (`pg:sslcert`, `acme:tenant-id`, `anthropic:org-id`).

A component MAY accept multiple alternative schemes by using JSON Schema `oneOf` in its args-schema:

```json
{
  "type": "object",
  "properties": {
    "std:bearer-token": {"type": "string"},
    "std:api-key": {"type": "string"}
  },
  "oneOf": [
    {"required": ["std:bearer-token"]},
    {"required": ["std:api-key"]}
  ]
}
```

The host SHOULD honor whichever credential the agent or operator provides.

### 1.3 OAuth Flow Discovery

A component that supports an OAuth flow advertises it through JSON Schema annotations on the credential property in its args-schema:

```json
{
  "type": "object",
  "properties": {
    "std:bearer-token": {
      "type": "string",
      "description": "Anthropic API access token",
      "x-act-authorization-server": "https://auth.example.com",
      "x-act-scopes": ["messages.write", "messages.read"]
    }
  },
  "required": ["std:bearer-token"]
}
```

Recognized JSON Schema annotations:

| Annotation | Type | Purpose |
|---|---|---|
| `x-act-authorization-server` | string (URL) | Authorization server discovery URL (RFC 8414 `.well-known/oauth-authorization-server` is appended by the host if missing) |
| `x-act-scopes` | array of string | OAuth scopes to request |

Annotations on credential properties other than `std:bearer-token` are unspecified at this version.

### 1.4 Host-Driven OAuth

A host MAY automate the OAuth flow on behalf of the agent. When the agent initiates `open_session` (Section 6.1 of `ACT-SESSIONS.md`) without providing the `std:bearer-token`, and the args-schema annotates that property with `x-act-authorization-server`, a conformant host SHOULD:

1. Discover authorization server metadata (RFC 8414).
2. Register a client (RFC 7591 dynamic client registration) if the authorization server supports it, else use client credentials configured by the host operator (config file, env, secret store).
3. Drive the authorization code flow with PKCE (RFC 6749, RFC 7636) — typically by directing the user (in interactive contexts) or returning a `WWW-Authenticate` challenge (in HTTP transport contexts; RFC 9728).
4. Acquire access and refresh tokens.
5. Inject the access token as `("std:bearer-token", cbor(<token>))` in the `open-session.args`.

The component MUST NOT perform the OAuth flow itself. It receives a ready-to-use bearer token.

### 1.5 Token Refresh

Access tokens expire. The host is responsible for refresh:

1. The host stores refresh tokens (where issued) outside the component.
2. When an access token approaches expiration or a session call returns a token-expired error, the host:
   a. Acquires a new access token (via refresh_token grant or re-running the authorization code flow as needed).
   b. Opens a **new** session with the refreshed token via `open-session`.
   c. Updates its session-id mapping so the agent's view of the session-id (Section 3.2 of `ACT-SESSIONS.md`) now points to the new internal session.
   d. Closes the **old** session via `close-session` only after the mapping is updated, to avoid a window where calls reach a closed session.

Token rotation therefore relies on host-side NAT mapping; without NAT, the agent would see the session-id change. Components MUST NOT manage refresh tokens themselves.

### 1.6 Credentials in Per-Call Metadata (Discouraged)

Earlier ACT designs delivered credentials per call via `call-tool.metadata`. This pattern is no longer normative.

- Components that export `session-provider` MUST NOT require credentials in `call-tool.metadata`. Credentials belong in `open-session.args`.
- Components that do **not** export `session-provider` MAY accept credentials in `call-tool.metadata`, but SHOULD instead export `session-provider` and follow the session-of-1 pattern (Section 1.1) for any new design. Existing components in the per-call style remain valid; this section does not retroactively invalidate them.

---

## 2. Client-to-Host Authentication

Authenticating the client to the ACT host (rather than the component to its upstream) is a transport concern. ACT does not define new authentication primitives at this layer; it specifies how the host MAY map transport-level auth into component-visible metadata when the client identity is meaningful to the component.

### 2.1 ACT-HTTP

The host uses standard HTTP authentication mechanisms:

- `Authorization: Bearer <token>` for bearer auth.
- `Authorization: Basic <base64>` for basic auth.
- mTLS for service-to-service.
- Custom headers (e.g. `X-Api-Key`) per deployment policy.

The host validates client credentials before invoking any component. Failure responses follow standard HTTP semantics:

- `401 Unauthorized` with `WWW-Authenticate` header indicating accepted schemes.
- `403 Forbidden` if authenticated but not authorized.

### 2.2 ACT-HTTP with OAuth 2.1 (MCP-Compatible)

Hosts that participate in OAuth 2.1 ecosystems (MCP HTTP transport spec, broadly) SHOULD:

- Return `401 Unauthorized` with a `WWW-Authenticate: Bearer` header carrying authorization server hints (RFC 9728) when the client lacks valid credentials.
- Validate bearer tokens via authorization server introspection or signature verification.
- Map authenticated client identity to internal authorization decisions (which components, which sessions).

### 2.3 MCP stdio

For MCP stdio transport, the host process is co-located with the client (typically launched as a subprocess by the client). No additional client-to-host authentication mechanism is required at this layer; the OS process boundary provides isolation.

### 2.4 Forwarding Client Credentials to Components

By default, client-to-host credentials are NOT forwarded to components. The host validates the client, then opens sessions and invokes calls using component-specific credentials managed at the host (Section 1.4) or provided by the agent in session args.

A host MAY forward an authenticated client's bearer token to a component as `std:bearer-token` in `open-session.args` if the component is explicitly configured to consume the same token (e.g. a component that proxies the same OAuth realm as the host). This is a deployment-level decision and outside the protocol's normative scope.

---

## 3. Identity Context (`std:on-behalf-of`)

**Status: reserved for future expansion.**

The `std:on-behalf-of` metadata key is reserved for carrying user-identity context independently of authentication. In multi-tenant agent scenarios, the agent acts on behalf of a human user who is distinct from the agent's own service identity. Components performing audit logging, row-level security, or rate limiting may benefit from knowing this identity.

Normative semantics for `std:on-behalf-of` are deferred to a future minor version. Hosts and components MAY use the key with application-defined semantics; ACT v0.4 does not constrain its content beyond reserving the key.

When standardized, `std:on-behalf-of` is expected to:

- Carry a CBOR map with at minimum a `sub` (subject) field, plus optional standard claims (`email`, `name`, `iss`, `aud`).
- Support both per-session placement (in `open-session.args`) and per-call placement (in `call-tool.metadata`).
- Optionally integrate with OAuth Token Exchange (RFC 8693) for verifiable delegation; the exchange is host-side, the component sees only the resulting bound token plus parsed identity.

Components and hosts that wish to anticipate this convention SHOULD use the key only with a subject identifier and SHOULD NOT depend on cross-implementation interoperability of additional fields until the key is normatively specified.

---

## 4. Transport Mapping

The following table summarizes how authentication flows across transport boundaries.

| Transport | Client-to-host | Component-to-external |
|---|---|---|
| ACT-HTTP | `Authorization` / custom headers (Section 2.1, 2.2) | Agent supplies credentials in `POST /sessions` body (`open-session.args`); host MAY inject from operator config or via host-driven OAuth (Section 1.4) |
| MCP HTTP (streamable) | `Authorization: Bearer` per MCP 2025-06-18 | Same as ACT-HTTP |
| MCP stdio | Process boundary (Section 2.3) | Host config / env / agent-supplied args |
| CLI | OS user (process boundary) | `act session open --args '{"std:bearer-token":"..."}'` or profile in `~/.config/act/config.toml` |

For all transports, the path component-side is the same: credentials enter `open-session.args` and live for the lifetime of the session.

---

## 5. Security Considerations

### 5.1 Confidentiality

Credentials in `open-session.args` MUST be transmitted over confidential channels:

- HTTP transports MUST use TLS in production.
- Stdio transports rely on OS-level isolation; multi-user systems SHOULD additionally restrict process visibility.
- Local files (act CLI profiles, env files) containing credentials SHOULD have restricted permissions (chmod 600 or equivalent).

### 5.2 Logging

Hosts MUST NOT log values of credential keys (Section 1.2). Logs MAY record key presence (e.g. "session opened with std:bearer-token") but not values.

### 5.3 Storage

Hosts that persist credentials (cached OAuth tokens, profile entries) SHOULD encrypt them at rest. Hosts SHOULD prefer short-lived access tokens with refresh, rotating credentials periodically.

### 5.4 Component Isolation

The WASM sandbox prevents components from accessing each other's session args. The host MUST NOT pass one component's session args to another component. The host MUST validate args against the schema returned by `get-open-session-args-schema` before invoking `open-session`.

### 5.5 Session-Id as Bearer Token

A session-id implicitly carries authority over the session — any caller able to present a valid session-id can invoke capabilities against it. Hosts MUST treat session-ids as confidential and MAY rewrite them at the host boundary (NAT, see `ACT-SESSIONS.md` Section 3.2).

### 5.6 Refresh Token Storage

Refresh tokens (if used) MUST remain on the host and MUST NOT be passed to components. Long-lived refresh tokens require stronger storage protection than access tokens.

---

## 6. Examples

### 6.1 Anthropic API Client

`act:component` declares `wasi:http` capability (for `api.anthropic.com`). Component exports `tool-provider` and `session-provider`.

`get-open-session-args-schema(metadata=[])`:

```json
{
  "type": "object",
  "properties": {
    "std:bearer-token": {
      "type": "string",
      "description": "Anthropic API key",
      "x-act-authorization-server": "https://auth.anthropic.com",
      "x-act-scopes": ["messages.write"]
    },
    "anthropic:org-id": {"type": "string"}
  },
  "required": ["std:bearer-token"]
}
```

Agent flow:

```
open_session({
  "std:bearer-token": "sk-ant-...",
  "anthropic:org-id": "org_42"
})
→ session { id: "anth_1", ... }

call-tool(
  name = "create-message",
  arguments = cbor({"model": "claude-opus-4-7", "messages": [...]}),
  metadata = [("std:session-id", "anth_1")]
)
```

### 6.2 Postgres with Basic Auth

```
open_session({
  "std:url": "postgres://alex@db.example.com/myapp",
  "std:password": "s3cret"
})
→ session { id: "pg_1", ... }

call-tool(
  name = "query",
  arguments = cbor({"sql": "SELECT * FROM docs"}),
  metadata = [("std:session-id", "pg_1")]
)
```

### 6.3 Host-Driven OAuth (interactive)

Component declares `x-act-authorization-server` for `std:bearer-token`. Agent calls `open_session` without providing the token. Host:

1. Discovers https://auth.example.com/.well-known/oauth-authorization-server.
2. Registers a client.
3. Opens a browser to the authorization endpoint with PKCE.
4. User completes consent.
5. Host receives access + refresh tokens.
6. Host injects access token into `open-session.args` and proceeds.
7. Host stores refresh token. On expiration, host opens a new session with the refreshed token, updates its NAT mapping so the agent's session-id now points at the new internal session, and only then closes the old session — avoiding a window where calls reach a closed session.

### 6.4 OpenAPI-Bridge with Per-Spec Sessions

```
agent: get-open-session-args-schema(metadata=[])
→ schema requires std:openapi-spec-url, optional std:base-url, std:bearer-token

agent: open_session({
  "std:openapi-spec-url": "https://api.example.com/openapi.json",
  "std:bearer-token": "..."
})
→ session { id: "spec_1", ... }
   Bridge fetches spec, generates tool catalog scoped to this session.

agent: list-tools(metadata=[("std:session-id", "spec_1")])
→ tools derived from the spec — different session, different tools.
```
