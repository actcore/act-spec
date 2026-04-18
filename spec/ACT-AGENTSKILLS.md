---
title: ACT Agent Skills Embedding
version: 0.3.0
status: normative
requires: [act:core@0.3.0]
---

# ACT Agent Skills Embedding

This document specifies how an [Agent Skills](https://agentskills.io) package is embedded inside an ACT WebAssembly component. It enables AI agents to discover component usage instructions without instantiating or executing the component.

For the normative ACT specification, see `ACT-SPEC.md`. For the Agent Skills format, see the [Agent Skills Specification](https://agentskills.io/specification).

---

## 1. Overview

An ACT component MAY embed an Agent Skills package in a WASM custom section named `act:skill`. When present, hosts, registries, and tooling can extract usage instructions, scripts, and reference material directly from the `.wasm` binary.

### 1.1 Design Goals

- **No code execution** — the skill is read from a custom section, not from an exported function. No instantiation, no WASI linking, no sandbox needed.
- **Standard tooling** — extraction requires only `wasm-tools` and `tar`, no custom parsers.
- **Agent Skills compatibility** — the embedded content is a valid Agent Skills package, usable by any platform that supports the standard (~30 platforms as of March 2026).

### 1.2 Static Skills Only in v0.3.0

The `act:skill` custom section carries a full Agent Skills package statically in the component binary. It does not require instantiation. A future mechanism for dynamic skills (generated per-instance or fetched from remote sources) may be added via the informative `resource-provider` interface (see `ACT-RESOURCES.md`), but is not part of the normative v0.3.0 surface.

---

## 2. Custom Section Format

### 2.1 Section Name

The custom section MUST be named `act:skill`.

### 2.2 Section Content

The section content is an **uncompressed POSIX tar archive** (IEEE Std 1003.1) containing the Agent Skills directory tree.

The tar archive MUST contain the following file at minimum:

```
SKILL.md
```

The archive MAY contain additional files and directories as defined by the Agent Skills specification.

### 2.3 Tar Format Requirements

- The archive MUST be uncompressed. WASM custom sections benefit from wasm-opt and transport-level compression (HTTP gzip/brotli), making archive-level compression redundant.
- The archive MUST use POSIX tar format (ustar or pax). GNU extensions are NOT RECOMMENDED.
- File paths within the archive MUST be relative (no leading `/`).
- File paths MUST NOT contain `..` segments.
- File modes, ownership, and timestamps are informational and SHOULD NOT be relied upon by consumers.

### 2.4 SKILL.md Requirements

The `SKILL.md` file MUST conform to the [Agent Skills Specification](https://agentskills.io/specification). The `name` field SHOULD match the component's `std.name` from the `act:component` section.

### 2.5 ACT Marker

The `SKILL.md` frontmatter SHOULD include an `act` key in `metadata`. Its presence identifies the skill as originating from an ACT component. The value is an object that MAY contain additional properties in future versions.

```yaml
metadata:
  act: {}
```

Agents that recognize the `act` metadata key know this skill is backed by an ACT component. How the agent invokes the component is implementation-defined: via `act call` CLI, an embedded ACT runtime, or any other ACT-compatible host. Agents without ACT awareness ignore unrecognized metadata keys per the Agent Skills specification.

---

## 3. Producing

### 3.1 SDK Macro

The Rust SDK provides a compile-time macro:

```rust
act_sdk::embed_skill!("skill/");
```

This reads the `skill/` directory at compile time, creates a tar archive in memory, and emits it as an `act:skill` custom section via `#[link_section]`.

### 3.2 Manual Embedding

Authors without the SDK can embed the skill using standard tools:

```bash
# Create tar archive from skill directory
tar cf skill.tar -C skill/ .

# Embed as custom section
wasm-tools metadata add --section act:skill=@skill.tar component.wasm -o component.wasm
```

### 3.3 Source Layout

The skill directory SHOULD be checked into source control alongside the component source:

```
my-component/
├── src/
│   └── lib.rs
├── skill/
│   ├── SKILL.md
│   └── references/
│       └── api.md
├── Cargo.toml
└── wit/
```

---

## 4. Consuming

### 4.1 CLI Extraction

```bash
# Extract to directory
act skill <component> --output ./my-skill/

# Extract from OCI reference
act skill ghcr.io/actpkg/sqlite:latest --output ./sqlite-skill/
```

### 4.2 Manual Extraction

```bash
wasm-tools metadata show --section act:skill component.wasm | tar xf - -C ./my-skill/
```

### 4.3 Host Behavior

When a host loads a component with an `act:skill` section:

1. The host MAY extract the skill and register it with the agent platform (e.g., write to `~/.agents/skills/`).
2. The host MAY serve the skill content via the MCP `resources/read` endpoint or ACT-HTTP.
3. The host MUST NOT execute scripts from the skill directory without explicit user consent.

### 4.4 Registry Behavior

Registries (OCI, warg, or custom) MAY extract and index the `act:skill` section to enable skill-aware search and discovery. The `SKILL.md` frontmatter (`name`, `description`) provides structured metadata for indexing.

---

## 5. Security Considerations

- The `act:skill` section is **passive data** — reading it does not execute any code.
- Scripts in the `scripts/` directory MUST NOT be executed automatically. They are reference material for agents, which decide whether and how to execute them.
- Tar extraction MUST validate paths: reject entries with absolute paths or `..` segments to prevent path traversal.
- Hosts SHOULD limit extracted file sizes to prevent denial-of-service from oversized archives.

---

## 6. Registration

The `act:skill` custom section is registered in `ACT-CONSTANTS.md` Section 12 (WASM Custom Sections):

| Section name | Format | Description |
|-------------|--------|-------------|
| `act:component` | CBOR map | Component metadata. |
| `act:skill` | Uncompressed tar | Agent Skills package (SKILL.md + optional files). |