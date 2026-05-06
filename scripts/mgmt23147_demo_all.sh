#!/usr/bin/env bash
# Run MGMT-23147 demo scenarios sequentially (no --poll-early).
#
# Prerequisite: same env as mgmt23147_demo_e2e.sh, e.g. on edge-04:
#   export KUBECONFIG=/home/obochan/hub-kubeconfig
#   oc config use-context osac-e2e-ci/api-osac-hub-redhat-com:6443/system:admin
#   export OSAC_NAMESPACE=osac-e2e-ci
#   export OSAC_HUB_KUBECONFIG=/home/obochan/hub-kubeconfig
#
# Usage:
#   bash scripts/mgmt23147_demo_all.sh              # non-interactive
#   bash scripts/mgmt23147_demo_all.sh --step       # pause like the single demo script
#   DEMO_BETWEEN_RUNS_SEC=10 bash scripts/mgmt23147_demo_all.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$ROOT/scripts/mgmt23147_demo_e2e.sh"
BETWEEN="${DEMO_BETWEEN_RUNS_SEC:-5}"

STEP=()
if [[ "${1:-}" == "--step" ]]; then
  STEP=(--step)
  shift
fi
if [[ $# -gt 0 ]]; then
  echo "Unknown args: $* (only --step is supported)" >&2
  exit 1
fi

[[ -x "$DEMO" ]] || [[ -f "$DEMO" ]] || {
  echo "ERROR: missing $DEMO" >&2
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || {
  echo "ERROR: missing command: $1" >&2
  exit 1
}; }

need_cmd bash
need_cmd oc
need_cmd osac

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 required for --delete-during-provision (scenario 3/3)" >&2
  exit 1
fi

run_one() {
  local title="$1"
  shift
  echo
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║  $title"
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  bash "$DEMO" "${STEP[@]}" "$@"
  echo
  echo "(pause ${BETWEEN}s before next scenario — set DEMO_BETWEEN_RUNS_SEC=0 to skip)"
  sleep "$BETWEEN"
}

echo "=== mgmt23147_demo_all — sequential runs (no --poll-early) ==="
echo "Demo script: $DEMO"
echo "Extra flags: ${STEP[*]:-(none)}"
echo

# 1) Happy path: create → Running → conditions/events → delete (+ post-delete event tail).
run_one "1/3 — Happy path (default)" 

# 2) After Running, watch ConfigurationApplied until True (or timeout).
run_one "2/3 — Scenario: --scenario-config-gap" --scenario-config-gap

# 3) Delete while provision in flight (needs python3 in mgmt23147_demo_e2e.sh).
run_one "3/3 — Scenario: --delete-during-provision" --delete-during-provision

echo "=== All demo runs finished. ==="
