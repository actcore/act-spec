# ACT Authentication Best Practices

**Version 0.2.0 (Draft)**

A guide to authentication patterns in ACT. This document covers two levels of authentication: transport-level (client→host) and metadata-level (component→external service).

---

## 1. Two Levels of Authentication

| | Transport-level auth | Metadata-level auth |
|---|---|---|
| **Purpose** | Client authenticates to the ACT host | Component authenticates to external APIs |
| **Where** | HTTP headers, transport mechanism | `metadata` parameter (key-value pairs) |
| **Who validates** | Host | External service |
| **Example** | `Authorization: Bearer <token>` header | `"std:api-key": "<key>"` in metadata |

These two levels are independent. A request may have transport-level auth (proving the client's identity to the host) and metadata-level auth (providing credentials for the component to call an external API).

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

## 3. Metadata-Level Authentication

Metadata-level auth provides credentials for the component to authenticate with external services. Credentials are passed as keys in the `metadata` parameter.

### 3.1 Well-Known Metadata Keys for Auth

Components SHOULD use these well-known keys in their metadata schema:

| Key | Type | Description |
|-----|------|-------------|
| `std:api-key` | string | API key for the external service |
| `std:bearer-token` | string | OAuth2/OIDC access token |
| `std:username` | string | Username for basic auth |
| `std:password` | string | Password for basic auth |

### 3.2 Metadata Schema Example

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
- **Config files** — per-component metadata in YAML/JSON
- **Secret stores** — HashiCorp Vault, AWS Secrets Manager, etc.

### 4.2 Per-Component Metadata Mapping

The host maps external credential sources to component metadata:

```yaml
# Example host config (not part of ACT spec)
components:
  weather-tools:
    metadata:
      std:api-key: ${WEATHER_API_KEY}
  github-tools:
    metadata:
      std:bearer-token: ${GITHUB_TOKEN}
```

### 4.3 Host-Managed OIDC

When a component needs an OIDC token for an external service:

1. The host is configured with OIDC provider details (issuer, client ID, client secret).
2. The host performs the OIDC flow (client credentials or authorization code).
3. The host caches the access token and handles refresh.
4. The host passes the fresh token as `std:bearer-token` in metadata on every call.

The component receives a ready-to-use token — it does not participate in the OIDC flow.

---

## 5. Security Considerations

### 5.1 Metadata Transport

- **HTTPS required** — metadata may contain credentials; all HTTP transport MUST use TLS in production.
- **Request body preferred** — metadata in `POST`/`QUERY` request body is safer than headers (not logged by default, not cached by proxies).

### 5.2 Sensitive Keys

- Hosts SHOULD treat metadata keys listed in Section 3.1 as sensitive and avoid logging their values.
- Hosts SHOULD NOT forward auth-related metadata keys to external consumers or include them in error responses.

### 5.3 Storage

- Hosts SHOULD encrypt credentials at rest.
- Hosts SHOULD use short-lived tokens where possible.
- Hosts SHOULD rotate credentials periodically.

### 5.4 Component Isolation

- WASM sandbox prevents components from accessing each other's metadata.
- The host MUST NOT pass one component's metadata to another component.
- The host SHOULD validate metadata schema before passing to the component.

---

## 6. Examples

### 6.1 API Key Authentication

```
POST /tools/get_weather
Content-Type: application/json

{
  "id": "call-1",
  "arguments": { "city": "London" },
  "metadata": { "std:api-key": "wk_abc123" }
}
```

### 6.2 Bearer Token Authentication

```
POST /tools/list_repos
Content-Type: application/json

{
  "id": "call-2",
  "arguments": { "org": "acme" },
  "metadata": { "std:bearer-token": "ghp_xxxxxxxxxxxx" }
}
```

### 6.3 Basic Authentication

```
POST /tools/query_db
Content-Type: application/json

{
  "id": "call-3",
  "arguments": { "sql": "SELECT 1" },
  "metadata": {
    "std:username": "readonly",
    "std:password": "s3cret"
  }
}
```

### 6.4 Transport + Metadata Auth Combined

Client authenticates to host (transport-level) AND provides credentials for external service (metadata-level):

```
POST /tools/get_weather
Authorization: Bearer eyJhbGciOi...
Content-Type: application/json

{
  "id": "call-4",
  "arguments": { "city": "London" },
  "metadata": { "std:api-key": "wk_abc123" }
}
```
