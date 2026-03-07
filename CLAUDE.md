# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ACT (Agent Component Tools)** is a self-documenting RPC protocol over WebAssembly Component Model (wasip3), optimized for agentic systems. It provides a universal component standard usable by both AI agents (via MCP-compatible interface) and application developers (via binary protocol).

The project is in early design/specification phase. The full design conversation is in `Claude-Универсальный стандарт компонентов через wasip3 и MCP.md`.

## Architecture

### Core Concept

WASI components (.wasm) export a `tool-provider` interface with stateful sessions. A host runtime (wasmtime) loads components, manages sessions, and exposes tools through multiple transport layers.

```
WIT specification (source of truth)
    |
    v
Component Host (Rust lib, wasmtime embedding)
    |
    +-- CLI tool (invoke tools from command line)
    +-- Unified Server (MCP over stdio/SSE + CBOR/JSON RPC over HTTP)
```

### Key Design Decisions

- **WIT as sole IDL** — JSON Schema is derived from WIT, never hand-written
- **Stateful sessions** — `resource session` with constructor/close, long-running instances that persist between calls
- **Streaming results** — `call-tool` returns `stream<stream-event>` (always a stream, even for atomic results)
- **Two-level errors** — `result::err` for early errors before stream opens, `stream-event::error` for mid-stream failures
- **Localized strings** — `list<tuple<string, string>>` (BCP 47 tag -> text) for all agent-facing text
- **Extensibility** — every record has `extensions: list<tuple<string, string>>` for experimental fields; breaking changes via WIT package versioning
- **Capabilities** — open URI registry (e.g. `wasi:sockets/tcp`), auto-detected by host from wasm imports, not hardcoded
- **MCP compatibility** — MCP is one transport adapter, not the architectural foundation
- **Cancellation** — host drops stream handle, wasmtime cancels the future automatically
- **Arguments** — JSON string validated by host against JSON Schema from `parameter-meta` before passing to component

### Planned Repository Structure

```
crates/
  wit/           # WIT specification (tool-provider.wit)
  host/          # Component Host library (wasmtime embedding, tokio event loop)
  cli/           # CLI utility
  server/        # Unified MCP + RPC server
sdk/
  rust/          # Guest SDK (proc macros for #[tool] attribute)
  python/        # Guest SDK via componentize-py
examples/
  hello-tool/    # Example component
```

### WIT Package

Package name: `act:core@0.1.0` (tentative, `myorg:tool-platform` in design docs)

Key interfaces:
- `types` — all shared types (localized-string, tool-definition, tool-call, content-part, stream-event, etc.)
- `component-metadata` — exports `get-info()` returning component-level info (name, version, capabilities)
- `tool-provider` — exports `resource session` with `list-tools`, `call-tool` (async, streaming), `close`

### Technology Stack

- **Rust** for all host-side code
- **wasmtime** as wasm runtime (with experimental `component-model-async` for wasip3 async/stream/future)
- **tokio** for async runtime in host
- wasip3 is experimental — expect API changes

## Language

The design document is in Russian. Code, comments, WIT definitions, and technical documentation should be in English.