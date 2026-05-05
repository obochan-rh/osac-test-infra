#!/usr/bin/env bash
# MGMT-23147 — E2E-style demo: osac create → wait for hub ComputeInstance → print conditions / events → optional delete.
# Mirrors tests/vmaas/test_compute_instance_creation.py at a high level (CLI → CR → phase Running).
#
# Intended lab: edge-04 (OSAC VMaaS e2e). Typical: OSAC_NAMESPACE=osac-e2e-ci, hub kubeconfig for edge-04.
# Other clusters: override OSAC_NAMESPACE / OSAC_FULFILLMENT_ADDRESS as needed.
#
# Prerequisites:
#   - oc (logged-in user or --as system:admin as in e2e token flow)
#   - osac CLI on PATH (or OSAC_CLI_PATH)
#   - Hub kubeconfig: KUBECONFIG or OSAC_HUB_KUBECONFIG
#
# Usage (edge-04 example):
#   export KUBECONFIG=/path/to/edge-04-hub.kubeconfig
#   export OSAC_NAMESPACE=osac-e2e-ci
#   # optional: export OSAC_FULFILLMENT_ADDRESS="fulfillment-api-osac-e2e-ci.apps...:443"
#   bash scripts/mgmt23147_demo_e2e.sh
#
#   bash scripts/mgmt23147_demo_e2e.sh --keep   # leave instance; print UUID and NAME
#   bash scripts/mgmt23147_demo_e2e.sh --scenario-config-gap   # after Running, poll until ConfigurationApplied=True
#
# Environment (defaults match tests/conftest.py and tests/vmaas/conftest.py):
#   OSAC_NAMESPACE          (default: osac-devel)
#   OSAC_VM_TEMPLATE        (default: osac.templates.ocp_virt_vm)
#   OSAC_SERVICE_ACCOUNT    (default: admin)
#   OSAC_CLI_PATH           (default: osac)
#   OSAC_FULFILLMENT_ADDRESS (optional; default: derived from ingress + namespace)
#   OSAC_HUB_KUBECONFIG     (optional; overrides KUBECONFIG for oc + token script)
#   WAIT_CR_RETRIES / WAIT_CR_DELAY       (default 30 / 2s)  wait for CR to exist
#   WAIT_RUNNING_RETRIES / WAIT_RUNNING_DELAY (default 90 / 10s) wait for phase Running
#   CONFIG_GAP_MAX_SECONDS   (default 120) max wait for ConfigurationApplied when using --scenario-config-gap

set -euo pipefail

KEEP=0
CONFIG_GAP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --scenario-config-gap) CONFIG_GAP=1 ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (use --help)" >&2
      exit 1
      ;;
  esac
  shift
done

NS="${OSAC_NAMESPACE:-osac-devel}"
TEMPLATE="${OSAC_VM_TEMPLATE:-osac.templates.ocp_virt_vm}"
SA="${OSAC_SERVICE_ACCOUNT:-admin}"
OSAC_BIN="${OSAC_CLI_PATH:-osac}"
HUB_KC="${OSAC_HUB_KUBECONFIG:-${KUBECONFIG:-}}"
WAIT_CR_RETRIES="${WAIT_CR_RETRIES:-30}"
WAIT_CR_DELAY="${WAIT_CR_DELAY:-2}"
WAIT_RUNNING_RETRIES="${WAIT_RUNNING_RETRIES:-90}"
WAIT_RUNNING_DELAY="${WAIT_RUNNING_DELAY:-10}"

oc_hub() {
  if [[ -n "$HUB_KC" ]]; then
    command oc --kubeconfig="$HUB_KC" "$@"
  else
    command oc "$@"
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

fulfillment_https() {
  if [[ -n "${OSAC_FULFILLMENT_ADDRESS:-}" ]]; then
    local host="${OSAC_FULFILLMENT_ADDRESS%%:*}"
    echo "https://${host}"
    return
  fi
  local domain
  domain="$(oc_hub get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')" \
    || die "could not read cluster ingress domain; set OSAC_FULFILLMENT_ADDRESS"
  echo "https://fulfillment-api-${NS}.${domain}"
}

token_script() {
  if [[ -n "$HUB_KC" ]]; then
    printf 'KUBECONFIG=%q oc create token -n %q %q --duration 1h --as system:admin' "$HUB_KC" "$NS" "$SA"
  else
    printf 'oc create token -n %q %q --duration 1h --as system:admin' "$NS" "$SA"
  fi
}

parse_uuid() {
  # Same idea as tests/osac_cli.py: first single-quoted token in CLI output
  local line
  line="$(echo "$1" | grep -E "'[^']+'" | head -1 || true)"
  if [[ -z "$line" ]]; then
    echo ""
    return
  fi
  sed -n "s/.*'\([^']*\)'.*/\1/p" <<<"$line" | head -1
}

print_conditions() {
  local name="$1"
  echo
  echo "=== conditions (TYPE / STATUS / REASON / MESSAGE) ==="
  local json tmp
  json="$(oc_hub get computeinstance "$name" -n "$NS" -o json 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    echo "(could not read ComputeInstance)"
    echo
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    tmp="$(mktemp)"
    printf '%s' "$json" >"$tmp"
    python3 <<PY || true
import json

order = "Provisioned ConfigurationApplied Ready RestartRequired RestartInProgress".split()
with open("$tmp", encoding="utf-8") as f:
    data = json.load(f)
conds = data.get("status", {}).get("conditions") or []

def key(c):
    t = c.get("type", "")
    try:
        return (0, order.index(t), t)
    except ValueError:
        return (1, t, t)

print(f"{'TYPE':<30} {'STATUS':<12} {'REASON':<28} MESSAGE")
for c in sorted(conds, key=key):
    print(
        f"{c.get('type', ''):<30} {c.get('status', ''):<12} {c.get('reason', ''):<28} {c.get('message', '')}"
    )
PY
    rm -f "$tmp"
  elif command -v column >/dev/null 2>&1; then
    {
      printf '%s\t%s\t%s\t%s\n' TYPE STATUS REASON MESSAGE
      oc_hub get computeinstance "$name" -n "$NS" -o jsonpath='
{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' 2>/dev/null || true
    } | column -t -s $'\t'
  else
    printf '%s\t%s\t%s\t%s\n' TYPE STATUS REASON MESSAGE
    oc_hub get computeinstance "$name" -n "$NS" -o jsonpath='
{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' 2>/dev/null || true
  fi
  echo
}

print_events() {
  local name="$1"
  echo "=== recent events (ComputeInstance) ==="
  oc_hub get events -n "$NS" \
    --field-selector "involvedObject.kind=ComputeInstance,involvedObject.name=${name}" \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true
  echo
}

# Demo scenario 3: phase can be Running while ConfigurationApplied is still False (MGMT-23147 narrative).
watch_config_gap() {
  local name="$1"
  local max="${CONFIG_GAP_MAX_SECONDS:-120}"
  local interval=2
  local elapsed=0
  echo "--- scenario 3: phase vs ConfigurationApplied (poll every ${interval}s, max ${max}s) ---"
  echo "(Expect: phase=Running can appear while ConfigurationApplied is still False / Applying configuration.)"
  echo
  while [[ "$elapsed" -lt "$max" ]]; do
    phase="$(oc_hub get computeinstance "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    ca_s="$(oc_hub get computeinstance "$name" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="ConfigurationApplied")].status}' 2>/dev/null || true)"
    ca_r="$(oc_hub get computeinstance "$name" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="ConfigurationApplied")].reason}' 2>/dev/null || true)"
    ca_m="$(oc_hub get computeinstance "$name" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="ConfigurationApplied")].message}' 2>/dev/null || true)"
    echo "  t=${elapsed}s  phase=${phase:-<empty>}  ConfigurationApplied: status=${ca_s:-?} reason=${ca_r:-?} message=${ca_m:-?}"
    if [[ "$ca_s" == "True" ]]; then
      echo "  ConfigurationApplied is True — config caught up with phase."
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "  (timeout) ConfigurationApplied still not True after ${max}s — show final table below." >&2
  return 0
}

need_cmd oc
need_cmd "$OSAC_BIN"
[[ -n "$HUB_KC" ]] || die "Set KUBECONFIG or OSAC_HUB_KUBECONFIG to the hub kubeconfig file"
[[ -f "$HUB_KC" ]] || die "Hub kubeconfig not a file: $HUB_KC"

ADDR="$(fulfillment_https)"
TS="$(token_script)"

echo "=== MGMT-23147 demo E2E ==="
echo "Namespace: $NS"
echo "Template:  $TEMPLATE"
echo "Fulfillment: $ADDR"
echo

echo "--- osac login ---"
"$OSAC_BIN" login --address "$ADDR" --insecure --token-script "$TS"

echo "--- osac create computeinstance ---"
CREATE_OUT="$("$OSAC_BIN" create computeinstance \
  --template "$TEMPLATE" \
  --cores 2 \
  --memory-gib 4 \
  --boot-disk-size 20 \
  --image quay.io/containerdisks/fedora:latest \
  --image-source-type registry \
  --run-strategy Always 2>&1)" || true

echo "$CREATE_OUT"
UUID="$(parse_uuid "$CREATE_OUT")"
[[ -n "$UUID" ]] || die "Could not parse UUID from osac output (expected a quoted id)"

echo
echo "UUID=$UUID"

echo "--- wait for ComputeInstance CR (label osac.openshift.io/computeinstance-uuid) ---"
NAME=""
for ((i = 1; i <= WAIT_CR_RETRIES; i++)); do
  NAME="$(oc_hub get computeinstance -n "$NS" \
    -l "osac.openshift.io/computeinstance-uuid=$UUID" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$NAME" ]]; then
    echo "NAME=$NAME (after ${i} attempt(s))"
    break
  fi
  sleep "$WAIT_CR_DELAY"
done
[[ -n "$NAME" ]] || die "Timed out waiting for ComputeInstance CR"

echo "--- wait for status.phase == Running (timeout: $((WAIT_RUNNING_RETRIES * WAIT_RUNNING_DELAY))s) ---"
phase=""
for ((i = 0; i < WAIT_RUNNING_RETRIES; i++)); do
  phase="$(oc_hub get computeinstance "$NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "  [$i] phase=${phase:-<empty>}"
  if [[ "$phase" == "Running" ]]; then
    break
  fi
  sleep "$WAIT_RUNNING_DELAY"
done

if [[ "$phase" == "Running" && "$CONFIG_GAP" -eq 1 ]]; then
  watch_config_gap "$NAME"
  echo
fi

print_conditions "$NAME"
if [[ "$phase" != "Running" ]]; then
  echo "WARN: phase is not Running (got: ${phase:-empty}) — still showing status for demo" >&2
  print_events "$NAME"
  [[ "$KEEP" -eq 1 ]] || {
    echo "--- cleanup: osac delete ---"
    "$OSAC_BIN" delete computeinstance "$UUID" || true
  }
  exit 1
fi

print_events "$NAME"

echo "=== summary ==="
oc_hub get computeinstance "$NAME" -n "$NS" -o wide
echo "UUID=$UUID NAME=$NAME NS=$NS"

if [[ "$KEEP" -eq 1 ]]; then
  echo "Kept instance (--keep). Delete later: osac delete computeinstance '$UUID'"
else
  echo "--- cleanup: osac delete ---"
  "$OSAC_BIN" delete computeinstance "$UUID"
  echo "Delete submitted; wait for CR to disappear if needed: oc get computeinstance '$NAME' -n '$NS'"
fi

echo "Done."
