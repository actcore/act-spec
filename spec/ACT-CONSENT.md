---
title: ACT Consent
version: 0.1.0
status: normative
requires: [act:core@0.4.0, act:consent@0.1.0]
---

# ACT Consent

This document specifies `act:consent@0.1.0` — the optional WIT package through which a component asks its host to authorize a **semantic** action.

ACT enforces physical capability classes by interception. The host sits on the `wasi:filesystem`, `wasi:http` and `wasi:sockets` boundaries and decides every crossing, so a component cannot reach a file or a host the operator did not permit. Semantic actions have no such boundary. `DROP DATABASE analytics` reaches Postgres over a socket the operator already granted; a script injection reaches a browser over an already-granted HTTP session. The host sees permitted bytes on a permitted channel.

`act:consent` closes that gap by inverting the initiative: the component names the class of action it is about to take, and the host applies that class's policy — the same grants, the same modes, the same audit trail as any physical class.

`act:consent@0.1.0` is **independent and opt-in**. A component that never asks need not import it. Like `act:credentials@0.1.0`, and unlike the rest of the ecosystem, the **host implements** the interface and the **component imports** it.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", "REQUIRED", and "MAY" in this document are to be interpreted as described in RFC 2119.

---

## 1. Threat Model

The two mechanisms defend against two different adversaries, and neither substitutes for the other.

| Mechanism | Adversary | How it holds |
|---|---|---|
| Physical capabilities | A **rogue component** — an artifact that does something other than what it claims | Host interception. The component cannot reach what it was not granted, whatever its code does. |
| Consent | A **rogue agent** — a mistaken or prompt-injected model driving a component that behaves exactly as documented | The component surfaces the action; the operator's policy, and where configured a human, decides. |

Consent therefore rests on the component's cooperation: a host cannot verify that a component asked before acting. This is not a weakness to be engineered away, it is the division of labour. The capability ceiling bounds what a component can reach at all; consent governs how an agent may direct it within that reach. A component that surfaces every external action — implicitly through its physical capabilities, explicitly through consent — gives the operator one complete control surface.

A conformant component MUST NOT treat consent as advisory (Section 6).

---

## 2. Package and Interface

### 2.1 Package

```wit
package act:consent@0.1.0;
```

### 2.2 Interface

```wit
interface types {
  use act:core/types@0.4.0.{cbor};

  enum decision { allow, deny }

  record consent-request {
    class: string,
    key: string,
    summary: string,
    args: cbor,
  }
}

interface consent-authority {
  use types.{consent-request, decision};
  use act:core/types@0.4.0.{metadata};

  request: async func(req: consent-request, meta: metadata) -> decision;
}
```

The `types` interface is function-free and async-free so SDK helpers and sync-shim adapters MAY `use act:consent/types` without taking on the async signature.

### 2.3 World Import

A component that asks for semantic authorization imports the interface:

```wit
world my-component {
  import act:consent/consent-authority@0.1.0;
  export act:tools/tool-provider@0.2.0;
}
```

---

## 3. Declaration and the Ceiling

### 3.1 The Manifest Is the Ceiling

A semantic class MUST be declared in the component's `act:component` capabilities:

```toml
[std.capabilities."db:drop"]
description = "Destructive operations (DROP, TRUNCATE)."
```

A class absent from the manifest MUST be refused. The host MUST NOT consult the operator about it, and no grant MAY widen it. This is the same rule `act:credentials` already states, and it is what makes a signed artifact's manifest a complete and inspectable list of the semantic actions it can ever ask for — readable before the artifact is ever run.

A bare declaration (a `description` and no constraints) declares the class and constrains no dimension: the class itself is the ceiling.

### 3.2 Declared Constraints

A declaration MAY narrow its own ceiling:

```toml
[std.capabilities."db:drop"]
description = "Destructive operations (DROP, TRUNCATE)."

[[std.capabilities."db:drop".allow]]
key = "test_*"
```

Constraints are matched as glob patterns against dimensions of the request. The dimension named `key` resolves from `consent-request.key`; every other dimension resolves from `args`. A constraint naming several dimensions matches only when **all** of them match.

### 3.3 Wildcards Are Not Permitted in Declarations

A declaration MUST name a concrete class. `[std.capabilities."db:*"]` is not a valid semantic declaration: it would mean "may ask for anything under `db:`", which defeats the property Section 3.1 exists to provide and leaves a reader unable to tell what the artifact can do.

Wildcards remain valid in operator **grants** and in host policy configuration, where they narrow rather than widen.

---

## 4. Decision Procedure

A host that receives `request` MUST decide as follows, in this order:

1. **Undeclared → `deny`.** If `class` is absent from the component's declared capabilities, or is empty, return `deny`. The operator MUST NOT be consulted, and this step MUST run before any other.
2. **Grant deny → `deny`.** If a `deny` constraint in the effective grant matches the request, return `deny`. Matching on this step is deliberately asymmetric with steps 3 and 4: a dimension the operation does not carry counts as **matching** a `deny` constraint, where on the allow and declared sides it counts as not matching. See §8.6 — a prohibition the component can slip by omitting a field is not a prohibition.
3. **Declared ceiling → `deny` when unmatched.** If the declaration carries constraints and none matches the request, return `deny`. This step runs **before** the grant mode is considered, so no mode can authorize an action the artifact did not declare it could take.
4. **Grant mode.**
   - `deny` → `deny`.
   - `open` → `allow`. `open` means the grant imposes no further constraint; it never means the declaration is ignored.
   - `allowlist` → `allow` if an `allow` constraint matches, otherwise `deny`.
   - `ask` → consult a human (Section 5) when the grant names no `allow` constraints or names one the request matches; otherwise `deny`. An `ask` grant that carries an allowlist still narrows: a request outside it is refused rather than prompted, so a single approval cannot authorize what the operator's own allowlist excluded.

The effective ceiling is therefore `declaration ∩ grant`, exactly as for the physical classes.

---

## 5. Consulting a Human

Under `ask`, the host consults a human over whatever channel its deployment provides — a terminal prompt, an MCP elicitation to the client, a GUI dialog.

- The host MUST attribute the question to the component by the reference the operator themselves supplied, never by a name the component chose.
- The host MUST neutralize **both `summary` and `key`** before display: strip control and bidirectional-override characters, and bound their length. `summary` is additionally rendered as the component's own words rather than as the host's question. Either field, left raw, can paint a second forged prompt line and collect approval for a question the host never asked — and either, left unbounded, can flood a terminal or an elicitation message until the real question scrolls away. A host MAY neutralize them inline or at its rendering boundary, but it MUST NOT display either field without doing so.
- The host SHOULD remember a decision for the pair `(class, key)` for at least the component run, so that a component cannot re-ask the same question to wear a human down.
- Where no channel exists — CI, a headless run, a client without elicitation — `ask` MUST degrade to `deny`. Silence is never consent.

A prompt raised during an in-flight tool call MUST be deliverable: the mechanism is not usable if it can only ask between calls.

---

## 6. Component Behavior

- A component MUST NOT perform the action it asked about after receiving `deny`.
- A component SHOULD return a tool error carrying `std:capability-denied` (see `ACT-CONSTANTS.md` Section 9) so the agent learns the action was refused rather than that it failed.
- A component SHOULD ask immediately before acting, not at session open. A decision taken far from the action it authorizes is a decision about a different thing.
- A component MAY apply its own restrictions in addition — a caller-supplied session mode, for instance, expressing least privilege from the agent's side. These compose: the component's own restriction narrows, consent authorizes, and neither replaces the other.
- A component MUST NOT vary its requests to discover the operator's policy. All refusals return `deny` precisely so that probing yields nothing.

---

## 7. Conformance

### 7.1 Conformant Component

A component that imports `act:consent/consent-authority@0.1.0`:

- MUST declare every class it will ever pass as `class` in its `act:component` capabilities.
- MUST call `request` before performing the action, and MUST NOT perform it on `deny`.
- MUST pass a `key` that identifies the subject the action affects, and SHOULD keep that key's shape stable within a class.
- MUST pass through the `metadata` of the call it is serving, so the host can anchor the decision to a session.
- SHOULD keep `summary` to one line describing the concrete action, not the class.

### 7.2 Conformant Host

A host that implements `act:consent/consent-authority@0.1.0`:

- MUST implement the decision procedure of Section 4 in that order.
- MUST refuse an undeclared class without consulting a human.
- MUST resolve a ceiling for every declared semantic class at instantiation, so that an operator can see each class and its effective mode before the component is invoked.
- MUST record every request and its outcome in the audit trail, including the class, the key, the decision, and the mode that produced it. This binds what an operator can **read at a host's default verbosity**, not only what its structured records carry. A semantic decision is not a high-frequency event like a file read: hosts MUST NOT summarize them into a count that drops the key, because which subject was authorized is the substance of the decision.
- MUST NOT record `summary` or `args` in a form that could be mistaken for host-authored text.
- MUST degrade `ask` to `deny` where it has no channel to a human.

---

## 8. Security Considerations

### 8.1 `key` and `summary` Are Untrusted

Both are chosen by the component. The host derives neither. What the interface guarantees is narrower and still load-bearing: there is exactly **one** key, and it is simultaneously what is shown to a human, what is recorded, and what policy matches — so the operation approved cannot differ from the operation authorized, and a second `key` placed inside `args` cannot shadow it. Hosts MUST resolve the `key` dimension from `consent-request.key` and never from `args`.

### 8.2 Key Shape and Pattern Anchoring

Because `key` is component-chosen and matched by glob, an unanchored operator pattern can match more than it appears to. Glob implementations commonly do not treat `/`, `?` or `#` as separators, so a grant of `{ "key": "*.example.com" }` against a URL-shaped key also matches `https://evil.test/?x=a.example.com`.

A class SHOULD therefore fix the shape of its key — an origin rather than a full URL, a bare identifier rather than a path — and operator patterns over component-chosen keys SHOULD be anchored rather than leading with `*`. Under `allowlist` no human inspects the key at all, so the guarantee in Section 8.1 does not by itself bound this case.

A second shape of the same problem: a key may match an operator's pattern while
naming a different subject than the action touches, because nothing checks the
key against what the component actually does. A key of
`test_scratch/../production` matches an anchored `test_*` and reads, to a human
skimming a prompt, as a scratch database. The host cannot detect this — it never
sees the action — so the defence is again the class fixing its key's shape:
reject or normalize a key that is not the plain identifier the class promised.

### 8.3 Consent Is Not a Sandbox

Consent binds a cooperating component. It provides no protection against an artifact that never calls `request`. Operators MUST NOT relax a component's physical capability grants on the grounds that it declares semantic classes; the ceiling and consent bound different adversaries (Section 1).

### 8.4 Refusals Are Indistinguishable

Every refusal returns `deny`. A host MUST NOT distinguish "undeclared", "denied by grant", "refused by a human" and "no channel available" in the value returned to the component, so that a component cannot map the operator's policy by probing. The distinction belongs in the audit trail, which the operator reads and the component cannot.

### 8.5 Prompt Fatigue

A component that asks repeatedly can exhaust a human into approving. The remembered `(class, key)` decision of Section 5 bounds this for repeats; hosts SHOULD additionally bound the rate of distinct prompts, and components SHOULD choose keys at the granularity a human would want to decide at rather than one per operation.

Note what "for at least the component run" means for a host serving several agent
sessions from one component instance: an approval given in one session authorizes
the identical `(class, key)` in another, because the component run is the wider
scope. That is this specification's floor, not its ceiling. A multi-tenant host
SHOULD narrow the remembered scope to the session that gave the approval, and
MUST NOT treat the floor as sufficient merely because it is conformant.

### 8.6 Deny Constraints Bind a Party That Chooses the Evidence

Constraint dimensions are not equally trustworthy, and the difference decides how
matching must fail.

Exactly one dimension is host-resolved: `key`, taken from `consent-request.key`,
which the host reads, shows, records and matches as one value (§8.1). Every other
dimension resolves from `args` — a CBOR map the component composes freely. It may
omit any field, including one an operator wrote a constraint against.

On the **allow** and **declared** sides that is harmless: a constraint that fails
to match withholds a permission, so an omission costs the component the very
permission it wanted. On the **deny** side the same rule inverts. A prohibition
that fails to match does not fire, so a component escapes an operator's `deny`
over an `args` dimension by not sending it.

Hosts MUST therefore treat a dimension absent from the operation as **matching**
a `deny` constraint. A `deny` over `table` refuses every request carrying no
`table` — including the whole class, if the component never sends one. That is
the intended consequence: it is loud, an operator sees it immediately, and it
cannot be reached by a component withholding evidence. The alternative fails
silently and in the component's favour.

Operators writing a bound they intend to be tight SHOULD prefer `key`, which is
the one dimension a component cannot omit.

*(The `args` field's own documentation in `act:consent@0.1.0`'s WIT says only
that nothing in `args` can widen what `key` and the declared ceiling permit —
true, but silent on narrowing. That text is published and immutable; this section
is where the qualification lives.)*


---

## Appendix A: Worked Example — a Postgres component

**`act.toml`:**

```toml
[std.capabilities."wasi:sockets"]
description = "Connect to the configured Postgres server."

[[std.capabilities."wasi:sockets".allow]]
host = "db.internal.example.com"
ports = [5432]

[std.capabilities."db:read"]
description = "Read data (SELECT, EXPLAIN, SHOW, schema introspection)."

[std.capabilities."db:write"]
description = "Modify rows (INSERT, UPDATE, DELETE, MERGE, COPY ... FROM)."

[std.capabilities."db:ddl"]
description = "Change schema (CREATE, ALTER, GRANT, REVOKE, ...)."

[std.capabilities."db:drop"]
description = "Destructive operations (DROP, TRUNCATE)."
```

The socket grant lets the component reach exactly one database server and nothing else — that bound holds no matter what the component's code does. The four `db:` classes describe what an agent may then direct it to do there.

**In the component**, before executing a statement it has classified as destructive:

```rust
let decision = consent::request(
    &ConsentRequest {
        class: "db:drop".into(),
        key: database.clone(),                       // "analytics"
        summary: format!("Drop database \"{database}\""),
        args: cbor!({ "statement_kind": "DROP DATABASE" }),
    },
    meta,
).await;

if decision == Decision::Deny {
    return Err(tool_error("std:capability-denied", "dropping databases was not authorized"));
}
```

**Operator control**, without touching the artifact:

```bash
# Refuse the class outright; everything else the component declares still works.
act call ./postgres.wasm query --deny db:drop --args '{"sql": "..."}'

# Or permit it only on scratch databases.
act run ./postgres.wasm --mcp \
  --grant '{"db:drop":{"mode":"allowlist","allow":[{"key":"test_*"}]}}'
```

Under the default `ask` mode with no grant, the operator is asked once per database and the answer is remembered for the run. In CI, where nothing can be asked, the drop is refused.
