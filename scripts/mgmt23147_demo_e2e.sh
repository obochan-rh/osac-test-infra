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
#   bash scripts/mgmt23147_demo_e2e.sh --preview                # print planned commands + illustrative YAML; exit (no API changes)
#   bash scripts/mgmt23147_demo_e2e.sh --step                  # interactive pauses: login, create, wait CR, describe+events, poll-early, Running wait, config-gap, summaries, delete
#   DEMO_STEP=1 bash scripts/mgmt23147_demo_e2e.sh             # same as --step
#   bash scripts/mgmt23147_demo_e2e.sh --poll-early             # after CR exists, poll conditions+events for POLL_EARLY_SECONDS (default 90) before waiting for Running
#   POLL_EARLY_SECONDS=120 POLL_EARLY_INTERVAL=5 .../mgmt23147_demo_e2e.sh --poll-early
#   bash scripts/mgmt23147_demo_e2e.sh --delete-during-provision   # cancel: wait for provision job in-flight, then delete (no Running wait); needs python3
#
# Environment (defaults match tests/conftest.py and tests/vmaas/conftest.py):
#   OSAC_NAMESPACE          (default: osac-devel)
#   OSAC_VM_TEMPLATE        (default: osac.templates.ocp_virt_vm)
#   OSAC_SERVICE_ACCOUNT    (default: admin)
#   OSAC_CLI_PATH           (default: osac)
#   OSAC_FULFILLMENT_ADDRESS (optional; default: derived from ingress + namespace)
#   OSAC_HUB_KUBECONFIG     (optional; overrides KUBECONFIG for oc + token script)
#   OSAC_OC_EXTRA_ARGS      (optional; extra flags for every hub "oc" invocation, e.g. --as system:admin on MOC)
#   WAIT_CR_RETRIES / WAIT_CR_DELAY       (default 30 / 2s)  wait for CR to exist
#   WAIT_RUNNING_RETRIES / WAIT_RUNNING_DELAY (default 90 / 10s) wait for phase Running
#   CONFIG_GAP_MAX_SECONDS   (default 120) max wait for ConfigurationApplied when using --scenario-config-gap
#   DEMO_NO_PLAN=1           skip printing the opening command/YAML plan (not recommended for live demos)
#   POLL_EARLY_SECONDS       (default 90) wall-clock window for --poll-early
#   POLL_EARLY_INTERVAL      (default 10) seconds between polls for --poll-early
#   DELETE_WAIT_RETRIES / DELETE_WAIT_DELAY  (default 60 / 5) wait for CR gone after delete-during-provision
#   DEMO_PAUSE_BEFORE_DESCRIBE_SEC   (default 5) sleep before oc describe (narrate vs plan YAML)
#   DEMO_PAUSE_AFTER_DESCRIBE_SEC    (default 4) sleep after describe + events before next step (0 to disable)
#   bash .../mgmt23147_demo_e2e.sh --no-describe   # skip oc describe + events block

set -euo pipefail

KEEP=0
CONFIG_GAP=0
PREVIEW_ONLY=0
DEMO_STEP="${DEMO_STEP:-0}"
POLL_EARLY=0
DELETE_DURING=0
SKIP_DESCRIBE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --scenario-config-gap) CONFIG_GAP=1 ;;
    --preview) PREVIEW_ONLY=1 ;;
    --step) DEMO_STEP=1 ;;
    --poll-early) POLL_EARLY=1 ;;
    --delete-during-provision) DELETE_DURING=1 ;;
    --no-describe) SKIP_DESCRIBE=1 ;;
    -h|--help)
      sed -n '1,90p' "$0"
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
POLL_EARLY_SECONDS="${POLL_EARLY_SECONDS:-90}"
POLL_EARLY_INTERVAL="${POLL_EARLY_INTERVAL:-10}"
DELETE_WAIT_RETRIES="${DELETE_WAIT_RETRIES:-60}"
DELETE_WAIT_DELAY="${DELETE_WAIT_DELAY:-5}"
DEMO_PAUSE_BEFORE_DESCRIBE_SEC="${DEMO_PAUSE_BEFORE_DESCRIBE_SEC:-5}"
DEMO_PAUSE_AFTER_DESCRIBE_SEC="${DEMO_PAUSE_AFTER_DESCRIBE_SEC:-4}"

oc_hub() {
  local -a oc_extra=()
  if [[ -n "${OSAC_OC_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    oc_extra=( ${OSAC_OC_EXTRA_ARGS} )
  fi
  if [[ -n "$HUB_KC" ]]; then
    command oc --kubeconfig="$HUB_KC" "${oc_extra[@]}" "$@"
  else
    command oc "${oc_extra[@]}" "$@"
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

demo_pause() {
  [[ "$DEMO_STEP" != "1" ]] && return 0
  local msg="${1:-next step}"
  read -r -p ">>> [demo pause: ${msg}] Press Enter to run the command above... " _ || true
  echo
}

# Print commands and illustrative YAML before any mutating osac calls (for slides / live demos).
show_demo_plan() {
  local ts
  ts="$(token_script)"
  echo
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║  DEMO PLAN — commands (nothing runs below until you see 'Executing now')    ║"
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  echo
  echo "──────── 1) Login (fulfillment; token via --token-script) ────────"
  printf '%s login --address %q --insecure --token-script %q\n' "$OSAC_BIN" "$ADDR" "$ts"
  echo
  echo "──────── 2) Create ComputeInstance (API; template + flags below) ────────"
  printf '%s create computeinstance \\\n' "$OSAC_BIN"
  printf '  --template %q \\\n' "$TEMPLATE"
  printf '  --cores 2 \\\n'
  printf '  --memory-gib 4 \\\n'
  printf '  --boot-disk-size 20 \\\n'
  printf '  --image %q \\\n' "quay.io/containerdisks/fedora:latest"
  printf '  --image-source-type registry \\\n'
  printf '  --run-strategy Always\n'
  echo
  echo "──────── 3) Inspect (this script only reads hub with oc; no YAML apply) ────────"
  echo "oc get computeinstance -n \"$NS\" -l 'osac.openshift.io/computeinstance-uuid=<UUID>' ..."
  echo "oc get computeinstance <name> -n \"$NS\" -o jsonpath='{.status.phase}' ..."
  echo
  echo "──────── 4) Cleanup (unless --keep) ────────"
  echo "$OSAC_BIN delete computeinstance '<UUID-from-create>'"
  echo "wait for CR to disappear, then print final ComputeInstance event tail"
  echo
  echo "──────── Illustrative hub YAML (real spec/status filled by fulfillment/operator) ────────"
  cat <<YAML
# Not applied from disk — created on hub after step 2.
apiVersion: osac.openshift.io/v1alpha1
kind: ComputeInstance
metadata:
  namespace: ${NS}
  labels:
    osac.openshift.io/computeinstance-uuid: "<uuid printed by osac create>"
  # name: assigned by controller / fulfillment (e.g. vm-xxxxx)
spec:
  # Template: ${TEMPLATE}
  # Plus cores, memory, boot disk, image, runStrategy from CLI (see command block above).
status:
  # Populated by osac-operator (phase, conditions with reason/message, jobs, ...)
  # MGMT-23147: status.conditions[].reason / .message + guarded Events
YAML
  echo
  if [[ "$POLL_EARLY" -eq 1 ]]; then
    echo "──────── Optional: --poll-early (scenario 2) ────────"
    echo "After CR exists: poll conditions + events every ${POLL_EARLY_INTERVAL}s for ${POLL_EARLY_SECONDS}s, then wait for Running."
  fi
  if [[ "$DELETE_DURING" -eq 1 ]]; then
    echo "──────── Optional: --delete-during-provision (scenario 5) ────────"
    echo "After provision job is Running/Pending/Unknown: osac delete; wait CR gone. (Skips Running wait; ignores --poll-early / --scenario-config-gap.)"
  fi
  echo "──────── After CR exists (default) ────────"
  echo "oc describe computeinstance <name>; oc get events ... (pauses DEMO_PAUSE_BEFORE_DESCRIBE_SEC / DEMO_PAUSE_AFTER_DESCRIBE_SEC). Skip with --no-describe."
  echo
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

wait_for_computeinstance_gone() {
  local name="$1"
  local i
  echo "--- wait for ComputeInstance CR to disappear (up to $((DELETE_WAIT_RETRIES * DELETE_WAIT_DELAY))s) ---"
  for ((i = 0; i < DELETE_WAIT_RETRIES; i++)); do
    if ! oc_hub get computeinstance "$name" -n "$NS" &>/dev/null; then
      echo "CR deleted (after ${i} wait(s))"
      return 0
    fi
    sleep "$DELETE_WAIT_DELAY"
  done
  echo "WARN: CR still present after delete wait — check manually" >&2
  return 1
}

print_post_delete_events() {
  local name="$1"
  echo "=== recent events after delete (ComputeInstance) ==="
  oc_hub get events -n "$NS" \
    --field-selector "involvedObject.kind=ComputeInstance,involvedObject.name=${name}" \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
  echo
}

# After CR exists: describe (spec + status + embedded events) + table events (REASON / MESSAGE).
show_describe_and_events() {
  local name="$1"
  local pre="${DEMO_PAUSE_BEFORE_DESCRIBE_SEC:-5}"
  local post="${DEMO_PAUSE_AFTER_DESCRIBE_SEC:-4}"
  echo
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║  Hub CR — oc describe + events (pause so audience maps plan → live object)  ║"
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  demo_pause "before oc describe + events block"
  if [[ "$pre" != "0" ]]; then
    echo "(pause ${pre}s — relate opening YAML/plan to this ComputeInstance on-cluster)"
    sleep "$pre"
  fi
  echo "=== oc describe computeinstance/$name -n $NS ==="
  oc_hub describe computeinstance "$name" -n "$NS" || true
  echo
  echo "=== oc get events (wide if supported) — ComputeInstance $name — Type / Reason / Message ==="
  if oc_hub get events -n "$NS" \
    --field-selector "involvedObject.kind=ComputeInstance,involvedObject.name=${name}" \
    --sort-by='.lastTimestamp' -o wide 2>/dev/null | tail -30; then
    :
  else
    oc_hub get events -n "$NS" \
      --field-selector "involvedObject.kind=ComputeInstance,involvedObject.name=${name}" \
      --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
  fi
  echo
  if [[ "$post" != "0" ]]; then
    echo "(pause ${post}s before next script step)"
    sleep "$post"
  fi
  demo_pause "continue after describe & events"
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

# Latest job field from status.jobs (matches tests/k8s_client.py). Requires python3.
get_latest_job_field() {
  local name="$1" job_type="$2" field="$3"
  oc_hub get computeinstance "$name" -n "$NS" -o json 2>/dev/null \
    | JOB_TYPE="$job_type" JOB_FIELD="$field" python3 -c '
import json, os, sys
typ, field = os.environ["JOB_TYPE"], os.environ["JOB_FIELD"]
data = json.load(sys.stdin)
jobs = [j for j in data.get("status", {}).get("jobs", []) if j.get("type") == typ]
if not jobs:
    print("")
else:
    j = sorted(jobs, key=lambda x: str(x.get("timestamp", "")), reverse=True)[0]
    v = j.get(field, "")
    print(v if v is not None else "")
' || echo ""
}

# Scenario 2: poll conditions + events during early provisioning (before / while Waiting for Running).
poll_early_period() {
  local name="$1"
  local start now deadline
  start="$(date +%s)"
  deadline=$((start + POLL_EARLY_SECONDS))
  echo
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║  Scenario 2 — early provisioning (${POLL_EARLY_SECONDS}s, every ${POLL_EARLY_INTERVAL}s)   ║"
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  while true; do
    now="$(date +%s)"
    if [[ "$now" -ge "$deadline" ]]; then
      break
    fi
    echo "=== $(date -Is)  (t=$((now - start))s / ${POLL_EARLY_SECONDS}s) ==="
    oc_hub get computeinstance "$name" -n "$NS" -o jsonpath='phase={.status.phase}{"  jobs="}{range .status.jobs[*]}{.type}{":"}{.state}{" "}{end}{"\n"}' 2>/dev/null || true
    print_conditions "$name"
    echo "--- last events ---"
    oc_hub get events -n "$NS" \
      --field-selector "involvedObject.kind=ComputeInstance,involvedObject.name=${name}" \
      --sort-by='.lastTimestamp' 2>/dev/null | tail -6 || true
    echo
    sleep "$POLL_EARLY_INTERVAL"
  done
  echo "(end scenario 2 poll — continuing to wait for Running if applicable)"
  echo
  demo_pause "after scenario 2 (--poll-early) — next: wait for Running"
}

# Scenario 5: delete while provision job is non-terminal (mirrors test_compute_instance_delete_during_provision).
run_delete_during_provision() {
  local name="$1"
  need_cmd python3
  echo
  echo "╔══════════════════════════════════════════════════════════════════════════════╗"
  echo "║  Scenario 5 — delete during provision                                         ║"
  echo "╚══════════════════════════════════════════════════════════════════════════════╝"
  echo "--- wait for provision job id (same as e2e: up to 30 × 2s) ---"
  local i prov_id prov_state deprov_id
  prov_id=""
  for ((i = 1; i <= 30; i++)); do
    prov_id="$(get_latest_job_field "$name" "provision" "jobID")"
    if [[ -n "$prov_id" ]]; then
      echo "provision jobID=$prov_id (attempt $i)"
      break
    fi
    sleep 2
  done
  [[ -n "$prov_id" ]] || die "No provision job id — cannot demo delete-during-provision"

  prov_state="$(get_latest_job_field "$name" "provision" "state")"
  deprov_id="$(get_latest_job_field "$name" "deprovision" "jobID")"
  echo "provision state=$prov_state deprovision jobID=${deprov_id:-<empty>}"
  case "$prov_state" in
    Running|Pending|Unknown) ;;
    *) die "Expected provision in progress (Running|Pending|Unknown), got: $prov_state" ;;
  esac
  [[ -z "$deprov_id" ]] || die "Deprovision job should not exist before delete (got jobID=$deprov_id)"

  print_conditions "$name"
  echo "--- osac delete (during provision) ---"
  printf '%s delete computeinstance %q\n' "$OSAC_BIN" "$UUID"
  demo_pause "osac delete during provision"
  "$OSAC_BIN" delete computeinstance "$UUID"

  echo "--- wait for CR to disappear (up to $((DELETE_WAIT_RETRIES * DELETE_WAIT_DELAY))s) ---"
  for ((i = 0; i < DELETE_WAIT_RETRIES; i++)); do
    if ! oc_hub get computeinstance "$name" -n "$NS" &>/dev/null; then
      echo "CR deleted (after ${i} wait(s))"
      break
    fi
    sleep "$DELETE_WAIT_DELAY"
  done
  if oc_hub get computeinstance "$name" -n "$NS" &>/dev/null; then
    echo "WARN: CR still present after wait — check manually" >&2
  fi
  echo "--- recent events (may still list past involvedObject) ---"
  oc_hub get events -n "$NS" \
    --field-selector "involvedObject.kind=ComputeInstance,involvedObject.name=${name}" \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
  echo
  echo "Scenario 5 done (virt orphan check is manual: VM label osac.openshift.io/computeinstance=$name)."
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
echo "Hub kubeconfig: $HUB_KC"
echo

if [[ "$PREVIEW_ONLY" -eq 1 ]] || [[ "${DEMO_NO_PLAN:-0}" != "1" ]]; then
  show_demo_plan
fi
if [[ "$PREVIEW_ONLY" -eq 1 ]]; then
  echo "(--preview) Stopping before any login/create/delete."
  exit 0
fi

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║  EXECUTION — mutating commands follow                                        ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"

demo_pause "start execution (after plan) — next: osac login"
echo
echo "──────── Executing now: osac login ────────"
printf '%s login --address %q --insecure --token-script %q\n' "$OSAC_BIN" "$ADDR" "$TS"
demo_pause "osac login"
"$OSAC_BIN" login --address "$ADDR" --insecure --token-script "$TS"
demo_pause "after osac login — next: create computeinstance"

echo
echo "──────── Executing now: osac create computeinstance ────────"
printf '%s create computeinstance \\\n  --template %q \\\n  --cores 2 --memory-gib 4 --boot-disk-size 20 \\\n  --image %q --image-source-type registry --run-strategy Always\n' \
  "$OSAC_BIN" "$TEMPLATE" "quay.io/containerdisks/fedora:latest"
demo_pause "osac create computeinstance"
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
demo_pause "after create — UUID known; next: wait for ComputeInstance CR on hub"

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

demo_pause "CR on hub — NAME=$NAME; next: describe + events (and optional narrate sleep)"

if [[ "$SKIP_DESCRIBE" -ne 1 ]]; then
  show_describe_and_events "$NAME"
else
  echo "(skipping oc describe + events block — --no-describe)"
fi

if [[ "$DELETE_DURING" -eq 1 ]]; then
  if [[ "$POLL_EARLY" -eq 1 ]]; then
    echo "NOTE: --delete-during-provision ignores --poll-early" >&2
    POLL_EARLY=0
  fi
  if [[ "$CONFIG_GAP" -eq 1 ]]; then
    echo "NOTE: --delete-during-provision ignores --scenario-config-gap" >&2
    CONFIG_GAP=0
  fi
  if [[ "$KEEP" -eq 1 ]]; then
    echo "NOTE: --delete-during-provision supersedes --keep (instance is deleted)" >&2
  fi
  run_delete_during_provision "$NAME"
  echo "Done."
  exit 0
fi

if [[ "$POLL_EARLY" -eq 1 ]]; then
  demo_pause "before scenario 2 (--poll-early) — early conditions + events window"
  poll_early_period "$NAME"
fi

demo_pause "before wait for status.phase Running (poll loop)"
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
  demo_pause "before scenario 3 (--scenario-config-gap) — ConfigurationApplied vs phase"
  watch_config_gap "$NAME"
  echo
fi

demo_pause "before final conditions table"
print_conditions "$NAME"
if [[ "$phase" != "Running" ]]; then
  echo "WARN: phase is not Running (got: ${phase:-empty}) — still showing status for demo" >&2
  demo_pause "non-Running — before events tail"
  print_events "$NAME"
  [[ "$KEEP" -eq 1 ]] || {
    echo "--- cleanup: osac delete ---"
    printf '%s delete computeinstance %q\n' "$OSAC_BIN" "$UUID"
    demo_pause "osac delete (cleanup after non-Running)"
    "$OSAC_BIN" delete computeinstance "$UUID" || true
    wait_for_computeinstance_gone "$NAME" || true
    print_post_delete_events "$NAME"
  }
  exit 1
fi

demo_pause "before final events tail"
print_events "$NAME"

demo_pause "before summary (oc get -o wide)"
echo "=== summary ==="
oc_hub get computeinstance "$NAME" -n "$NS" -o wide
echo "UUID=$UUID NAME=$NAME NS=$NS"

if [[ "$KEEP" -eq 1 ]]; then
  echo "Kept instance (--keep). Delete later:"
  printf '%s delete computeinstance %q\n' "$OSAC_BIN" "$UUID"
else
  echo "--- cleanup: osac delete ---"
  printf '%s delete computeinstance %q\n' "$OSAC_BIN" "$UUID"
  demo_pause "osac delete (cleanup)"
  "$OSAC_BIN" delete computeinstance "$UUID"
  wait_for_computeinstance_gone "$NAME" || true
  print_post_delete_events "$NAME"
fi

echo "Done."
