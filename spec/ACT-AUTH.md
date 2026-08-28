---
title: ACT Authentication
version: 0.4.0
status: normative
requires: [act:core@0.4.0, act:tools@0.2.0, act:sessions@0.2.0, act:credentials@0.1.0]
---

# ACT Authentication

This document specifies how authentication is handled in ACT. It covers two independent layers:

1. **Component-to-external auth** — credentials a component uses to authenticate with external services (databases, APIs). Normative; primary subject of this document.
2. **Client-to-host auth** — how a client (agent, CLI, browser) authenticates to the ACT host. Normative for HTTP transports; informative for stdio.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in RFC 2119.

---

## 1. Component-to-External Authentication

Credentials a component uses to authenticate with the external service it wraps (Postgres password, Anthropic API key, GitHub bearer token, …) reach it by one of two mechanisms.

1. **The host credential store — `act:credentials@0.1.0`** (Section 1.1). The component imports `act:credentials/store`, declares the `act:credentials` capability, and calls `get-secret` for a key in its own profile. The operator provisions out of band (`act secret set`); the agent learns which credentials exist but never their values. **This is the preferred mechanism for new components**, and the only one under which a credential does not pass through the agent's context.

2. **Session args** (Sections 1.2–1.8). Still normative and still valid — it is the right mechanism when the agent or operator legitimately holds a value already, and every existing component uses it. Its cost is structural: an argument is visible to whoever composed the call.

A component MAY support both, preferring the store and falling back to arguments.

> **Revision pending.** Sections 1.4–1.6 (OAuth discovery, host-driven OAuth, token
> refresh) still describe session args as the sole path. They are being rewritten
> around the credential store. `act login` has since landed for prompted fields, so
> what the rewrite now waits on is the OAuth flow itself — discovery, PKCE and
> refresh against a stored `std:oauth2` field. Where Section 1.1 and those sections
> disagree, Section 1.1 is current.

### 1.1 The Host Credential Store

This section specifies `act:credentials@0.1.0` — the host-provided store a
component imports to obtain secrets **without those secrets passing through the
agent**. Field types and field names are registered in `ACT-CONSTANTS.md` §8;
`ACT-SESSIONS.md` §2.4 and §4 cover the session interactions from the session
side.

> **Scope.** This describes what the reference host implements today. `act login`,
> the `[[std.credentials]]` manifest table and the OAuth **acquisition** flow are
> implemented and specified here (§1.1.8, §1.1.2). Still unimplemented and
> deliberately unspecified: **silent refresh** — a stored token is not renewed, so
> an expired one is re-acquired by running `act login` again — in-band acquisition
> during a tool call (§1.1.8), and a credential selector in virtual `open_session`.

#### 1.1.1 Direction of call

Every other ACT package runs host-to-component: the component exports an
interface and the host calls in. This one runs the other way. The component
imports `act:credentials/store` and calls out; the host answers from a store the
component can neither read nor enumerate directly.

The import is opt-in in both directions. A component that needs no credentials
never gains the import and cannot call it.

#### 1.1.2 Declaring the capability

A component that uses the store MUST declare the capability class in its
component metadata:

```toml
[std.capabilities."act:credentials"]
```

The class takes no parameters; it is declared as a bare table. An **undeclared
class MUST be denied**, and no grant may widen it. Declaring is what makes
granting meaningful — it is not a formality the host can infer.

#### 1.1.3 Profiles

A component addresses credentials by operator-chosen key **within its own
profile**. The profile namespace is the component reference the operator used
when storing the credential.

A component MUST NOT be able to name, enumerate, or fetch a credential outside
its own profile. This is a structural boundary rather than a policy setting:
policy can be misconfigured, a namespace cannot.

#### 1.1.4 Sessions

**A live session is required.** `get-secret` takes a session id. The host MUST
refuse with `invalid-session` when the id does not name a live session.

**A credential cannot be fetched inside `open-session`.** The host marks a
session live **only after `open-session` returns**, and the session id is chosen
by the component. A `get-secret` issued from within `open-session` therefore
names an id the host has never seen and MUST be refused.

This is settled behaviour, not a race to work around. Components that need a
credential in order to validate their connection MUST do so **lazily, on first
use**, and SHOULD cache the result for the session's lifetime. A component that
would otherwise fail fast at open time trades that for a first-call failure, and
its error mapping SHOULD carry the difference.

**Closing ends service.** After `close-session`, the host MUST stop serving
credentials for that session id; subsequent requests MUST be refused with
`invalid-session`.

**A store consumer therefore exports `session-provider`.** Session ids exist only
because `open-session` returned one, so a component that exports no session
provider has no id that can ever be live and `get-secret` refuses every request it
makes. This follows from the rule above rather than adding to it, and it is stated
because it is otherwise discovered at runtime: a pure-function component told by
§1.2 not to export `session-provider` cannot use the credential store, and must
take its credential another way or grow a session. `list-secrets` is the exception
in both directions — it takes an optional session and acquires nothing.

**Listing outside a session.** `list-secrets` takes an **optional** session.
When present it MUST name a live session — it is checked, not used to narrow the
result. **There is no per-session compartment:** the listing covers the
component's whole profile either way. Listing acquires nothing, so a component
MAY inspect its profile before any session exists, and it is deliberately
unaudited — it hands over no material, and recording it would bury the issue
records that matter.

#### 1.1.5 What the agent may see

Names, descriptions, and expiry. **Never values.** This holds identically on every
agent-facing surface.

The agent learns *which* credentials exist, so that it can name one; it never
learns *what* they are.

#### 1.1.6 Fields

Field **types** and field **names** are registered in `ACT-CONSTANTS.md` §8. A
credential is a set of named fields; each field's type binds its encoding and how
it is acquired. Two types exist: `std:string` and `std:oauth2`.

There are no credential **shapes** and no registered field **names** (§8.2). Meaning
lives in the names, and they are chosen by whoever stores the credential: `acme:username`
beside `acme:password` is a password credential, and a `std:oauth2`-typed field beside a
vendor's own string is an OAuth credential with a tenant id. A component MUST read the
fields it knows by name and fail cleanly otherwise; it MUST NOT infer semantics from
which fields happen to be present, or from how many.

A field name MUST NOT be in the `std:` namespace, and a host MUST refuse one wherever it
can be minted — a declaration, an operator's definitions, a provisioning argument. Note
that `std:username` and `std:password` in §1.3 are *session-argument* keys and are
unrelated: inside a stored credential those names are refused like any other `std:` one.

Consequently **retrieval MUST NOT be filtered by shape.** A value provisioned as one
type is still served to a component expecting another — it is the same bytes either
way. The alternative, refusing a key whose stored form differs, was rejected: it
turns an operator's provisioning choice into a runtime failure the component cannot
explain and the operator cannot see.

The `secret-kind` member carried by `act:credentials@0.1.0` predates this model and
names nothing under it. A host MUST populate it with `std:fields` for credentials it
writes, MUST pass through whatever a store already holds, and a component MUST NOT
branch on it.

Field values cross as dCBOR — the same encoding tool arguments and metadata use.

#### 1.1.7 Errors

| Variant | Meaning |
|---------|---------|
| `not-found` | No such key in the compartment this component can see. |
| `denied` | Policy refused the request — undeclared class, denied grant, or a human answering no. |
| `invalid-session` | The `session` argument does not name a live session (§1.1.4). |
| `unavailable(string)` | The store could not answer: backend unavailable, decryption failure, host misconfiguration. |

`denied` MUST NOT vary with whether the key exists. The decision is taken before
the store is consulted, so a denied component learns nothing about its profile's
contents; were `denied` and `not-found` distinguishable under a denying policy,
the pair would be a probing channel.

The string carried by `unavailable` is a diagnostic for logs. It is not for the
agent to act on and MUST NOT carry credential material — including material a
backend error quotes back. A store whose serialisation error names the offending
value MUST have that detail replaced with a host-authored constant before it
crosses to the component; the detail belongs in the host's log.

Where a component fails because a credential it needs is absent, the
agent-facing error kind is `std:credential-required` (`ACT-CONSTANTS.md` §9).

#### 1.1.8 Provisioning

**Provisioning is the operator's act, not the agent's.** A credential enters a
profile because a human ran a command — which is what disposes of MCP's
requirement that a server prove the user who finished a flow is the user who
started it (§5 of the design): here the user typed it themselves.

```
act login       <component-ref> [--key K] [--force] [--field NAME …]
                                            # prompts per declared field
```

`act login` provisions from the component's own declaration (§1.1.2), so the
operator need not know what it wants. A component that declares no fields — a
bridge, whose credential set is open by nature — takes `--field NAME` instead.
An existing credential is never replaced without `--force`.

`=TYPE` states what a name cannot (§1.1.6): field names carry no type, and
`std:string` is assumed, so a value that is an OAuth map rather than a string is
named `--field acme:token=std:oauth2`. A declaration states the type per field and
its user never writes this.

A declared `std:oauth2` field is **acquired by the flow**, never prompted for.
The host derives every address it contacts from the field's `resource`
identifier — RFC 9728 for the resource, then RFC 8414 or OpenID Connect for the
authorization server — registers this installation with RFC 7591 dynamic client
registration (one registration per issuer, never shared), and runs the
authorization-code flow with PKCE S256 and RFC 8707 `resource`. The callback
arrives on a loopback listener bound to `127.0.0.1` on an ephemeral port at a
fixed `/callback` path, which validates `Host` and refuses anything else.

Two checks run **before the code is transmitted to any token endpoint**: `state`
must match the authorization request, and `iss` must satisfy RFC 9207 — present
and matching where the server advertises support, and never contradicting where
it does not. A host MUST apply both in that position; applying them after the
exchange defends nothing, because the code has already been presented.

An access token is stored in the field, with `std:expires-at` and `std:scopes`
per `ACT-CONSTANTS.md` §8.3. **A refresh token MUST NOT be stored in the field**
— it belongs in the record's host-only compartment, so a component receives the
means to authenticate and never the means to mint a new credential.

**Silent refresh is not implemented.** An expired token is re-acquired by
running `act login --force` rather than renewed in place; §1.6 describes the
intended behaviour and is not what the reference host does today.

A field whose declaration names no `resource` cannot be acquired: there is
nothing to derive from, and the host refuses before opening a browser. Such a
credential is provisioned with `act secret set --field NAME=std:oauth2
--fields-stdin` from a token obtained by hand.

```
act secret set  <component-ref> [--key K] --field NAME[=TYPE] [--field …]
                                [--description D]
                                [--fields-stdin | --from-command '<cmd>']
act secret list [<component-ref>]
act secret rm   <component-ref> --key K
```

The component reference is the profile namespace (§1.1.3).

There is deliberately **no `act secret get`**. No command prints a stored value;
the type `list` serialises has no field that could hold one.

**This does not mean a credential is never obtained during a tool call.** Two
things are easy to conflate here, and an earlier draft of this section conflated
them:

- **Retrieval** inside a tool call is not an exception, it is the only case there
  is. `get-secret` requires a live session, and a session is live only after
  `open-session` returns (§1.1.4) — so every credential a component reads, it
  reads mid-call.
- **Acquisition** inside a tool call is a *host* behaviour and is permitted where
  the host can reach a human: URL-mode elicitation to a loopback page, awaiting
  the page submission rather than the elicitation reply. Where it cannot — a
  client without `elicitation.url`, or a headless run — the call fails with a
  command the user can run out of band. The component's view is identical in
  every branch: a secret, or `not-found`.

What in-band acquisition costs is the anti-phishing property above: the
initiator is then the component rather than a human who typed a command. What
gates it is not settled — see the design's §5.7 and §14.

#### 1.1.9 Store (informative)

The reference host ships a single backend: a file store at a platform default
location, overridable with `--credentials-backend file:<path>`.

**Its records are plaintext on disk, protected by filesystem permissions alone —
nothing encrypts them.** The file is created with owner-only permissions, set as
the file is created rather than tightened afterwards. This is stated plainly
rather than softened: an operator told that permissions are the only protection
needs to know which file to restrict, and which file to keep out of backups and
snapshots.

#### 1.1.10 Limits

- **Retention is not enforceable.** Once material is in guest memory the host
  cannot withdraw it, and a component that stashes a value and reuses it in
  another session cannot be stopped. What bounds the exposure is the component's
  **capability ceiling** — where it is permitted to send anything at all — not
  the credential store. The two are load-bearing together; neither suffices
  alone.
- **Session binding is observational for the common case.** The host records the
  request against a session and bounds its lifetime (§1.1.4), but where a
  component derives the key itself the host has no basis to decide which keys
  that session was entitled to.

### 1.2 Sessions as the Auth Boundary

A component requiring authentication exports `act:sessions/session-provider@0.2.0` (see `ACT-SESSIONS.md`) and accepts credentials in `open-session.args`:

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

### 1.3 Well-Known Credential Keys

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

### 1.4 OAuth Flow Discovery

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

### 1.5 Host-Driven OAuth

A host MAY automate the OAuth flow on behalf of the agent. When the agent initiates `open_session` (Section 6.1 of `ACT-SESSIONS.md`) without providing the `std:bearer-token`, and the args-schema annotates that property with `x-act-authorization-server`, a conformant host SHOULD:

1. Discover authorization server metadata (RFC 8414).
2. Register a client (RFC 7591 dynamic client registration) if the authorization server supports it, else use client credentials configured by the host operator (config file, env, secret store).
3. Drive the authorization code flow with PKCE (RFC 6749, RFC 7636) — typically by directing the user (in interactive contexts) or returning a `WWW-Authenticate` challenge (in HTTP transport contexts; RFC 9728).
4. Acquire access and refresh tokens.
5. Inject the access token as `("std:bearer-token", cbor(<token>))` in the `open-session.args`.

The component MUST NOT perform the OAuth flow itself. It receives a ready-to-use bearer token.

### 1.6 Token Refresh

Access tokens expire. The host is responsible for refresh:

1. The host stores refresh tokens (where issued) outside the component.
2. When an access token approaches expiration or a session call returns a token-expired error, the host:
   a. Acquires a new access token (via refresh_token grant or re-running the authorization code flow as needed).
   b. Opens a **new** session with the refreshed token via `open-session`.
   c. Updates its session-id mapping so the agent's view of the session-id (Section 3.2 of `ACT-SESSIONS.md`) now points to the new internal session.
   d. Closes the **old** session via `close-session` only after the mapping is updated, to avoid a window where calls reach a closed session.

Token rotation therefore relies on host-side NAT mapping; without NAT, the agent would see the session-id change. Components MUST NOT manage refresh tokens themselves.

### 1.7 Credentials in Per-Call Metadata (Discouraged)

Earlier ACT designs delivered credentials per call via `call-tool.metadata`. This pattern is no longer normative.

- Components that export `session-provider` MUST NOT require credentials in `call-tool.metadata`. Credentials belong in `open-session.args`.
- Components that do **not** export `session-provider` MAY accept credentials in `call-tool.metadata`, but SHOULD instead export `session-provider` and follow the session-of-1 pattern (Section 1.2) for any new design. Existing components in the per-call style remain valid; this section does not retroactively invalidate them.

### 1.8 Operator Env-Var Transport for Session-of-1

> **Not implemented.** The reference host does not read `ACT_SESSION_ARGS`; the
> variable appears nowhere in `act-cli`. Setting it has no effect, and the example
> below will not pin a session. The credential store (Section 1.1) is the supported
> way to keep a credential out of the command line. This subsection is retained
> pending the decision on whether an environment transport should exist at all.

Operators configuring a single-component host process (`act run --mcp <ref>` spawned by an MCP client, `act call <ref> <tool>` in shell/CI) MAY supply session args via the `ACT_SESSION_ARGS` environment variable. The host reads the variable at startup, parses it as a JSON object, validates it against the component's `get-open-session-args-schema` response, and performs the session-of-1 auto-pin defined in Section 1.2.

This is operator-facing transport convenience for the one-process-one-component shape. It is **not** an agent-facing channel; the agent never sees the env var. The session-id resulting from auto-pin is injected by the host into every forwarded `call-tool.metadata` under `std:session-id`, transparently to the agent.

```bash
export ACT_SESSION_ARGS='{"std:bearer-token":"sk-ant-..."}'
act run ghcr.io/example/anthropic:0.1.0 --mcp
```

```jsonc
// .mcp.json (Claude Desktop, Cursor, VS Code, …)
{
  "mcpServers": {
    "anthropic": {
      "command": "act",
      "args": ["run", "ghcr.io/example/anthropic:0.1.0", "--mcp"],
      "env": {
        "ACT_SESSION_ARGS": "{\"std:bearer-token\":\"sk-ant-...\"}"
      }
    }
  }
}
```

Precedence:

1. `--session-args '<json>'` CLI flag (when present).
2. `ACT_SESSION_ARGS` env var (when present).
3. None (the host does not auto-pin; agent-visible virtual `open_session`/`close_session` remain available per `ACT-MCP.md` §4.1).

Validation is fail-fast: if `ACT_SESSION_ARGS` is malformed JSON, fails schema validation, or `open-session` returns an error, the host exits non-zero with the diagnostic on stderr **before** exposing any tools to the agent.

If `ACT_SESSION_ARGS` is set but the component does NOT export `session-provider`, the host MUST fail at startup (refusing the silent-discard semantic that would let a misconfigured deployment look healthy).

Multi-component broker hosts (`acts --mcp` from `act-toolserver`) are out of scope for `ACT_SESSION_ARGS`. Brokers expose multiple components behind a single MCP front-end and store per-component credentials in their own configuration plane; `ACT_SESSION_ARGS` would have no defined target component there. Broker-scoped env vars are the broker's own design space.

---

## 2. Client-to-Host Authentication

Authenticating the client to the ACT host (rather than the component to its upstream) is a transport concern. ACT does not define new authentication primitives at this layer; it specifies how the host MAY map transport-level auth into component-visible metadata when the client identity is meaningful to the component.

### 2.1 ACT-HTTP

> **Withdrawn.** This section describes the ACT-HTTP binding, withdrawn on
> 2026-08-13 and no longer implemented by the reference host. Retained as
> design record; see [ACT-HTTP.md](ACT-HTTP.md). Not normative.

The host uses standard HTTP authentication mechanisms:

- `Authorization: Bearer <token>` for bearer auth.
- `Authorization: Basic <base64>` for basic auth.
- mTLS for service-to-service.
- Custom headers (e.g. `X-Api-Key`) per deployment policy.

The host validates client credentials before invoking any component. Failure responses follow standard HTTP semantics:

- `401 Unauthorized` with `WWW-Authenticate` header indicating accepted schemes.
- `403 Forbidden` if authenticated but not authorized.

### 2.2 HTTP Transports with OAuth 2.1

Retitled: this applied to ACT-HTTP (§2.1, withdrawn) and applies unchanged to MCP
over Streamable HTTP, which is the reference host's only HTTP transport
(`act run --mcp --http`).

Hosts that participate in OAuth 2.1 ecosystems (MCP HTTP transport spec, broadly) SHOULD:

- Return `401 Unauthorized` with a `WWW-Authenticate: Bearer` header carrying authorization server hints (RFC 9728) when the client lacks valid credentials.
- Validate bearer tokens via authorization server introspection or signature verification.
- Map authenticated client identity to internal authorization decisions (which components, which sessions).

### 2.3 MCP stdio

For MCP stdio transport, the host process is co-located with the client (typically launched as a subprocess by the client). No additional client-to-host authentication mechanism is required at this layer; the OS process boundary provides isolation.

### 2.4 Forwarding Client Credentials to Components

By default, client-to-host credentials are NOT forwarded to components. The host validates the client, then opens sessions and invokes calls using component-specific credentials managed at the host (the credential store, Section 1.1; or host-driven OAuth, Section 1.5) or provided by the agent in session args.

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
| MCP HTTP (streamable) | `Authorization: Bearer` per MCP 2025-06-18 | Agent supplies credentials in the virtual `open_session` call (`open-session.args`); host MAY inject from operator config or via host-driven OAuth (Section 1.5) |
| MCP stdio | Process boundary (Section 2.3) | Host config / agent-supplied args |
| CLI | OS user (process boundary) | `act run`/`act call --session-args '{"std:bearer-token":"…"}'`, or a profile in `~/.config/act/config.toml` |
| ~~ACT-HTTP~~ | *withdrawn 2026-08-13 (Section 2.1)* | *was: `POST /sessions` body* |

The table describes the **session-args** mechanism, where the path component-side is the same for every transport: credentials enter `open-session.args` and live for the lifetime of the session.

The credential store (Section 1.1) is transport-independent by construction, and is the row this table cannot have: nothing crosses the transport at all. The component calls `get-secret` from inside the guest, and the value reaches it without appearing in a request body, a header, an argument, or an agent's context on any of these transports.

---

## 5. Security Considerations

### 5.1 Confidentiality

Credentials in `open-session.args` MUST be transmitted over confidential channels:

- HTTP transports MUST use TLS in production.
- Stdio transports rely on OS-level isolation; multi-user systems SHOULD additionally restrict process visibility.
- Local files (act CLI profiles, env files) containing credentials SHOULD have restricted permissions (chmod 600 or equivalent).

### 5.2 Logging

Hosts MUST NOT log values of credential keys (Section 1.3), nor values served by the credential store (Section 1.1). Logs MAY record key presence (e.g. "session opened with std:bearer-token") but not values.

### 5.3 Storage

Hosts that persist credentials (cached OAuth tokens, profile entries) SHOULD encrypt them at rest. Hosts SHOULD prefer short-lived access tokens with refresh, rotating credentials periodically.

**The reference host does not meet the first SHOULD**, and Section 1.1.9 says so rather than implying otherwise: its file store is plaintext, protected by owner-only filesystem permissions alone. An operator deploying it must treat the store file as secret material — restricted, and kept out of backups and snapshots. Encryption at rest is deferred, not delivered.

### 5.4 Component Isolation

The WASM sandbox prevents components from accessing each other's session args. The host MUST NOT pass one component's session args to another component. The host MUST validate args against the schema returned by `get-open-session-args-schema` before invoking `open-session`.

**The reference host now meets it.** It validates `open-session` args against the schema and tool arguments against `tool-definition.parameters-schema`, before the guest is reached, and rejects with `std:invalid-args` shaped exactly like the error the guest would have produced. An earlier revision of this section recorded the opposite — the host published the schema and never checked against it — and the divergence was closed by moving the implementation rather than the requirement.

Two limits worth stating, because they are what "validates" does and does not mean here. A schema the host cannot compile disables checking **for that tool**, with a warning: the alternative turns a component's packaging mistake into a total outage for arguments that may be perfectly fine, and the check exists to protect that component. And a schema is guest-authored text, so a `$ref` in it is never resolved over the network — an external reference fails to compile, which disables checking rather than becoming an outbound request the component never declared `wasi:http` for.

A component MUST still validate its own arguments; the SDKs do. This layer is the first of two, not the only one.

The credential store has the same isolation as a **structural** property rather than a rule the host must remember to apply: a component addresses keys only within its own profile (Section 1.1.3), and there is no argument it can pass — no key, no session id, no kind — that names another component's compartment. Policy can be misconfigured; a namespace cannot.

### 5.5 Session-Id as Bearer Token

A session-id implicitly carries authority over the session — any caller able to present a valid session-id can invoke capabilities against it. Hosts MUST treat session-ids as confidential and MAY rewrite them at the host boundary (NAT, see `ACT-SESSIONS.md` Section 3.2).

### 5.6 Refresh Token Storage

Refresh tokens (if used) MUST remain on the host and MUST NOT be passed to components. Long-lived refresh tokens require stronger storage protection than access tokens.

---

## 6. Examples

### 6.1 GitHub Client via the Credential Store

The preferred arrangement for a new component: the value never enters an argument,
a session, or the agent's context.

`act.toml` declares the class as a bare table, alongside the network reach the
component actually needs:

```toml
[std.capabilities."act:credentials"]

[std.capabilities."wasi:http"]
allow = [{ host = "api.github.com" }]
```

The operator provisions once, out of band. Nothing here passes through the agent:

```bash
act secret set ghcr.io/example/github:0.1.0 \
    --key api --field example:pat --description "GitHub PAT, repo scope" \
    --fields-stdin
```

The component fetches lazily, on first use — **not** inside `open-session`, which
would name a session the host has not yet marked live (§1.1.4):

```rust
// inside the tool call, not inside open-session
let secret = store::get_secret(session_id, &SecretRequest {
    key: "api".into(),
    kind: None,                       // names nothing under this model (§1.1.6)
    resource: Some("api.github.com".into()),
    scopes: vec![],
    hint: Some("list the caller's repositories".into()),
})?;
let pat = secret.field("example:pat").and_then(|v| v.as_str())?;
```

What the agent sees is the whole difference. It can enumerate:

```
list_secrets() → [ { key: "api", kind: "std:fields",
                     description: "GitHub PAT, repo scope" } ]
```

…and it can name `"api"` in a tool call. It cannot read the token, and no host
surface will show it one: not the tool result, not the audit trail, not an error.
A store that fails to decode reports `unavailable` with a host-authored string,
never the offending value (§1.1.7).

If the credential is absent, the component fails with `std:credential-required`
and the host tells the operator which command would fix it — again without
describing the material.

### 6.2 Anthropic API Client

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

### 6.3 Postgres with Basic Auth

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

### 6.4 Host-Driven OAuth (interactive)

Component declares `x-act-authorization-server` for `std:bearer-token`. Agent calls `open_session` without providing the token. Host:

1. Discovers https://auth.example.com/.well-known/oauth-authorization-server.
2. Registers a client.
3. Opens a browser to the authorization endpoint with PKCE.
4. User completes consent.
5. Host receives access + refresh tokens.
6. Host injects access token into `open-session.args` and proceeds.
7. Host stores refresh token. On expiration, host opens a new session with the refreshed token, updates its NAT mapping so the agent's session-id now points at the new internal session, and only then closes the old session — avoiding a window where calls reach a closed session.

### 6.5 OpenAPI-Bridge with Per-Spec Sessions

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
