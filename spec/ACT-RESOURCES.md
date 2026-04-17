# ACT Resources (Informative / RFC)

**Status:** Informative. Not normative in `act:core@0.3.0`. No production components implement `resource-provider`. This document is retained to solicit community feedback; future versions may stabilize, restructure, or remove it. Implementations MAY experiment with it but MUST NOT rely on its stability.

The `resource-provider` interface is a design sketch for component-provided resources — icons, dynamic skills, schemas, remote data — addressable by URI. It mirrors MCP's resource model.

---

## 1. WIT Interface

Defined in `wit/act-resources.wit`, part of the `act:core@0.3.0` package:

```wit
interface resource-types {
  use types.{localized-string, metadata};

  /// Describes a resource available from the component.
  record resource-info {
    /// Resource URI. Well-known: "std:icon".
    uri: string,
    /// Expected MIME type of the resource.
    mime-type: option<string>,
    description: localized-string,
    metadata: metadata,
  }

  /// Response from get-resource.
  record resource-response {
    /// Actual MIME type (may differ from resource-info listing).
    mime-type: option<string>,
    metadata: metadata,
    body: stream<u8>,
  }
}

interface resource-provider {
  use resource-types.{resource-info, resource-response};
  use types.{metadata};

  /// Returns the list of resources available from this component.
  list-resources: async func(metadata: metadata) -> list<resource-info>;

  /// Returns a resource by URI.
  /// Returns a resource-response with mime-type, metadata, and a byte stream.
  get-resource: async func(metadata: metadata, uri: string) -> resource-response;
}
```

## 2. Lifecycle Sketch

If a component exports `resource-provider`:

1. The host calls `list-resources(metadata)` to discover available resources.
2. The host calls `get-resource(metadata, uri)` to retrieve a specific resource.
3. The host reads the byte stream from `resource-response.body`.
4. The host uses `resource-response.mime-type` (or falls back to `resource-info.mime-type`) to determine the content type.

## 3. Well-Known Resource URIs (Proposed)

| URI | Description |
|-----|-------------|
| `std:icon` | Component icon. Expected MIME type: `image/png` or `image/svg+xml`. |

Custom URIs use their own namespace (e.g. `acme:invoice/2026/Q1`).

## 4. MCP Adapter Mapping (Proposed)

An MCP↔ACT adapter MAY expose component resources as MCP resources.

**Resource discovery — `resources/list`:**

The adapter calls `list-resources(metadata)` and maps each `resource-info` to an MCP resource:

| ACT `resource-info` | MCP `Resource` |
|---|---|
| `uri` | `uri` |
| `description` | `name` (resolved to single language) |
| `mime-type` | `mimeType` |

**Resource retrieval — `resources/read`:**

The adapter calls `get-resource(metadata, uri)`, reads the byte stream, and returns the content as MCP resource content.

## 5. Relationship to `act:skill`

The `act:skill` WASM custom section (see ACT-AGENTSKILLS.md) carries static component-level skill documentation. The `resource-provider` interface is a more general mechanism that could also carry skills dynamically (`get-resource("std:skill")`), fetch schemas, or serve binary assets. The two mechanisms are complementary: static embedded content vs. dynamic component-produced content.

## 6. Open Questions

- Is `resource-provider` justified as a top-level interface, or should resources be modeled as a standard tool pattern (e.g. a tool named `get-resource` with well-known arguments)?
- How should resource caching interact with capabilities and metadata?
- Should URIs be opaque to the host or MUST they be parseable?

Feedback welcome — open an issue on the `act-spec` repository.