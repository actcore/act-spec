---
title: ACT Events
version: 0.3.0
status: informative-rfc
---

# ACT Events

**Status:** Informative / RFC. Not normative in `act:core@0.3.0`. No production components implement `event-provider`. This document is retained to solicit community feedback; future versions may stabilize, restructure, or remove it. Implementations MAY experiment with it but MUST NOT rely on its stability.

The `event-provider` interface is a design sketch for push-style event notifications from components to hosts — e.g. "tool list changed", "new data available", "session state updated". The current sketch mirrors subscription semantics common in MCP and similar protocols.

---

## 1. WIT Interface

Defined in `wit/act-events.wit`, part of the `act:core@0.3.0` package:

```wit
interface event-types {
  use types.{localized-string, metadata};

  /// Describes a type of event the component can emit.
  record event-type-info {
    /// Event kind identifier. Well-known: "std:tools:changed",
    /// "std:resources:changed", "std:events:changed".
    /// Custom kinds use namespace prefix (e.g. "acme:order_updated").
    kind: string,
    description: localized-string,
    metadata: metadata,
  }

  /// A single event emitted by the component.
  record event {
    /// Event kind, matching one of the kinds from get-event-types.
    kind: string,
    /// Optional dCBOR-encoded payload.
    data: option<list<u8>>,
    metadata: metadata,
  }
}

interface event-provider {
  use event-types.{event-type-info, event};
  use types.{metadata};

  /// Returns the list of event types this component can emit.
  /// The host calls this at load time and MAY cache the result.
  get-event-types: func() -> list<event-type-info>;

  /// Opens a stream of events. The host reads events as they arrive.
  /// The stream stays open until the component closes it or the host drops the handle.
  subscribe: async func(metadata: metadata) -> stream<event>;
}
```

## 2. Lifecycle Sketch

If a component exports `event-provider`:

1. The host calls `get-event-types()` at load time to discover available event kinds.
2. The host calls `subscribe(metadata)` to open an event stream.
3. The host reads `event` values from the stream. Each event has a `kind` (matching a declared event kind), optional `data` (dCBOR payload), and `metadata`.
4. The stream stays open until the component closes it or the host drops the handle.
5. If the host drops the handle, the component SHOULD release resources promptly.

`metadata` follows the same pattern as `list-tools` and `call-tool` — bridge components may need credentials for external event sources.

## 3. Well-Known Event Kinds (Proposed)

| Kind | Description |
|------|-------------|
| `std:tools:changed` | Tool list has changed. Clients SHOULD re-fetch via `list-tools`. |
| `std:resources:changed` | Resource list has changed. Clients SHOULD re-fetch via `list-resources`. |
| `std:events:changed` | Event type list has changed. Clients SHOULD re-fetch via `get-event-types`. |

Custom kinds use their own namespace prefix (e.g. `acme:order_updated`).

## 4. MCP Adapter Mapping (Proposed)

An MCP↔ACT adapter MAY map component events to MCP notifications:

| ACT event kind | MCP notification |
|---|---|
| `std:tools:changed` | `notifications/tools/list_changed` |
| `std:resources:changed` | `notifications/resources/list_changed` |
| Custom kinds | Adapter-defined (MAY use MCP notification extensions) |

The adapter calls `subscribe(metadata)` when the MCP session starts and reads events from the stream. For each event, the adapter sends the corresponding MCP notification to the client. When the session ends, the adapter drops the event stream handle.

## 5. Open Questions

- Should `subscribe` be exposed as a separate interface or folded into `tool-provider` with a dedicated tool convention?
- How should hosts multiplex events from multiple concurrent subscribers? Is per-session state required?
- Is there a simpler shape (e.g. poll-based) that better fits the stateless ACT protocol model?

Feedback welcome — open an issue on the `act-spec` repository.