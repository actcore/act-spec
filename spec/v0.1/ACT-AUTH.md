# ACT Authentication Best Practices

**Version 0.1.3 (Draft)**

A guide to authentication patterns in ACT. This document covers two levels of authentication: transport-level (client→host) and config-level (component→external service).

---

## 1. Two Levels of Authentication

| | Transport-level auth | Config-level auth |
|---|---|---|
| **Purpose** | Client authenticates to the ACT host | Component authenticates to external APIs |
| **Where** | HTTP headers, transport mechanism | `config` parameter (dCBOR) |
| **Who validates** | Host | External service |
| **Example** | `Authorization: Bearer <token>` header | `"std:bearer-token": "<token>"` in config |

These two levels are independent. A request may have transport-level auth (proving the client's identity to the host) and config-level auth (providing credentials for the component to call an external API).

---

## 2. Transport-Level Authentication

Transport-level auth protects access to the ACT host itself. The host validates the client's identity before allowing tool calls.

### 2.1 HTTP Transport

Standard HTTP authentication mechanisms apply:

- **Bearer token:** `Authorization: Bearer <token>` header
- **API key:** Custom header (e.g. `X-API-Key: <key>`)
- **mTLS:** Client certificate authentication

The host validates credentials and MAY enforce per-client access policies (e.g. which components or tools the client can access).

### 2.2 MCP Transport

For MCP stdio, the host process is trusted — no additional auth is needed.

### 2.3 OIDC for Component Access

When using OIDC for transport-level auth:

1. The client performs the OIDC flow (discovery, authorization, token exchange).
2. The client sends the access token in the `Authorization` header.
3. The host validates the token against the OIDC provider.
4. The host MAY map token claims to access policies.

The OIDC flow is outside ACT's scope. See OpenID Connect Core 1.0.

---

## 3. Config-Level Authentication

Config-level auth provides credentials for the component to authenticate with external services. Credentials are passed as fields in the `config` parameter.

### 3.1 Well-Known Config Keys

Components SHOULD use these well-known keys in their config schema:

| Key | Type | Description |
|-----|------|-------------|
| `std:api-key` | string | API key for the external service |
| `std:bearer-token` | string | OAuth2/OIDC access token |
| `std:username` | string | Username for basic auth |
| `std:password` | string | Password for basic auth |

### 3.2 Config Schema Example

A component that requires an API key:

```json
{
  "type": "object",
  "properties": {
    "std:api-key": {
      "type": "string",
      "description": "API key for the weather service"
    }
  },
  "required": ["std:api-key"]
}
```

A component that accepts either API key or bearer token:

```json
{
  "type": "object",
  "properties": {
    "std:api-key": { "type": "string" },
    "std:bearer-token": { "type": "string" }
  },
  "oneOf": [
    { "required": ["std:api-key"] },
    { "required": ["std:bearer-token"] }
  ]
}
```

---

## 4. Host-Level Auth Policies

The host manages credentials on behalf of components. This section describes recommended patterns (not protocol requirements).

### 4.1 Credential Sources

Hosts SHOULD support multiple credential sources:

- **Environment variables** — `ACT_WEATHER_API_KEY=...`
- **Config files** — per-component config in YAML/JSON
- **Secret stores** — HashiCorp Vault, AWS Secrets Manager, etc.

### 4.2 Per-Component Config Mapping

The host maps external credential sources to component config:

```yaml
# Example host config (not part of ACT spec)
components:
  weather-tools:
    config:
      std:api-key: ${WEATHER_API_KEY}
  github-tools:
    config:
      std:bearer-token: ${GITHUB_TOKEN}
```

### 4.3 Host-Managed OIDC

When a component needs an OIDC token for an external service:

1. The host is configured with OIDC provider details (issuer, client ID, client secret).
2. The host performs the OIDC flow (client credentials or authorization code).
3. The host caches the access token and handles refresh.
4. The host passes the fresh token as `std:bearer-token` in config on every call.

The component receives a ready-to-use token — it does not participate in the OIDC flow.

---

## 5. Security Considerations

### 5.1 Config Transport

- **HTTPS required** — config contains credentials; all HTTP transport MUST use TLS in production.
- **Request body preferred** — config in `POST`/`QUERY` request body is safer than headers (not logged by default, not cached by proxies).
- **`X-ACT-Config` header** — when using the GET fallback, the header value is base64-encoded JSON. Proxies and CDNs MAY log headers; deployments SHOULD ensure headers with credentials are not logged.

### 5.2 Metadata

- **Never store secrets in metadata.** Metadata is not encrypted and may be logged, cached, or forwarded by hosts and transport adapters.
- Credentials belong in `config`, not in `tool-call.metadata`.

### 5.3 Storage

- Hosts SHOULD encrypt credentials at rest.
- Hosts SHOULD use short-lived tokens where possible.
- Hosts SHOULD rotate credentials periodically.

### 5.4 Component Isolation

- WASM sandbox prevents components from accessing each other's config.
- The host MUST NOT pass one component's config to another component.
- The host SHOULD validate config schema before passing to the component.

---

## 6. Examples

### 6.1 API Key Authentication

```
POST /tools/get_weather
Content-Type: application/json

{
  "id": "call-1",
  "arguments": { "city": "London" },
  "config": { "std:api-key": "wk_abc123" }
}
```

### 6.2 Bearer Token Authentication

```
POST /tools/list_repos
Content-Type: application/json

{
  "id": "call-2",
  "arguments": { "org": "acme" },
  "config": { "std:bearer-token": "ghp_xxxxxxxxxxxx" }
}
```

### 6.3 Basic Authentication

```
POST /tools/query_db
Content-Type: application/json

{
  "id": "call-3",
  "arguments": { "sql": "SELECT 1" },
  "config": {
    "std:username": "readonly",
    "std:password": "s3cret"
  }
}
```

### 6.4 Transport + Config Auth Combined

Client authenticates to host (transport-level) AND provides credentials for external service (config-level):

```
POST /tools/get_weather
Authorization: Bearer eyJhbGciOi...
Content-Type: application/json

{
  "id": "call-4",
  "arguments": { "city": "London" },
  "config": { "std:api-key": "wk_abc123" }
}
```
