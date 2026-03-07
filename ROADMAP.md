# ACT Roadmap

## Host Features

- **OpenAPI spec generation** — Auto-generate `GET /openapi.json` from ACT component metadata (`list-tools`, `parameter-meta`, `get-config-schema`). Any ACT component automatically gets a documented REST API with Swagger UI support.

## Bridge Components

- **OpenAPI bridge** — Fetches an OpenAPI spec, exposes each operation as an ACT tool.
- **MCP client bridge** — Connects to a remote MCP server, exposes its tools as ACT tools.
- **ACP client bridge** — Delegates tasks to remote agents via Agent Communication Protocol.
- **UCP client bridge** — Universal Commerce Protocol integration.
- **HTTP fetch** — Simple HTTP request tool.
- **Filesystem access** — File read/write/list tools.