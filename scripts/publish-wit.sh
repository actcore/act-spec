#!/usr/bin/env bash
# Publish all act:* WIT packages to actcore.dev in dependency order, skipping
# any <pkg>@<version> already present on the registry. Driven by
# .github/workflows/publish-wit.yml on a `wit-v*` tag.
#
#   PUBLISH=0 scripts/publish-wit.sh   # build-only rehearsal (no probe, no publish)
#   scripts/publish-wit.sh             # build + publish (needs ghcr.io login)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WIT="$ROOT/wit"
CFG="$ROOT/wkg-registry.toml"
# Make the `act` namespace registry available to EVERY wkg call (build + publish).
# `wkg wit build` resolves the package's namespace against this even with deps
# staged locally; without it a clean env (CI) fails: "no registry configured for
# namespace act".
export WKG_CONFIG_FILE="$CFG"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PUBLISH="${PUBLISH:-1}"

# package dir -> its act:* dependency dirs (transitive; all must be staged)
declare -A DEPS=(
  [act-core]=""
  [act-tools]="act-core"
  [act-sessions]="act-core"
  [act-events]="act-core"
  [act-resources]="act-core"
  [act-tools-sync]="act-core act-tools"
  [act-sessions-sync]="act-core act-sessions"
)
# dependency order: every dir appears AFTER the dirs it depends on
ORDER=(act-core act-tools act-sessions act-events act-resources act-tools-sync act-sessions-sync)

pkg_id() { grep -m1 -ohE '^package [a-z0-9:_-]+@[0-9.]+' "$WIT/$1"/*.wit | sed 's/^package //'; }
oci_ref() { local id="$1" ns name ver; ns="${id%%:*}"; id="${id#*:}"; name="${id%@*}"; ver="${id#*@}"; echo "ghcr.io/actcore/$ns/$name:$ver"; }

for pkg in "${ORDER[@]}"; do
  if [ ! -d "$WIT/$pkg" ]; then echo "skip  $pkg (no dir yet)"; continue; fi
  id="$(pkg_id "$pkg")"; ref="$(oci_ref "$id")"
  if [ "$PUBLISH" = "1" ] && wkg oci pull "$ref" -o "$WORK/probe.wasm" >/dev/null 2>&1; then
    echo "skip  $id (already on registry)"; continue
  fi
  stage="$WORK/$pkg"; mkdir -p "$stage/deps"
  cp "$WIT/$pkg"/*.wit "$stage/"
  for dep in ${DEPS[$pkg]}; do mkdir -p "$stage/deps/$dep"; cp "$WIT/$dep"/*.wit "$stage/deps/$dep/"; done
  echo "build $id"
  wkg wit build -d "$stage" -o "$WORK/$pkg.wasm"
  if [ "$PUBLISH" = "1" ]; then
    echo "publish $id -> $ref"
    wkg publish "$WORK/$pkg.wasm"
  fi
done
echo "all done"
