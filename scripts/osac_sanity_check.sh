#!/usr/bin/env bash
# OSAC two-cluster sanity check (hub + virt). Run on a host with `oc` and kubeconfigs, e.g. edge-04.
# Usage:
#   export KUBECONFIG=/home/obochan/hub-kubeconfig
#   export OSAC_VM_KUBECONFIG=/home/obochan/virt-kubeconfig
#   export OSAC_NAMESPACE=osac-e2e-ci   # optional, default below
#   bash scripts/osac_sanity_check.sh
#
# Exit 0 if all CRITICAL checks pass; 1 otherwise.
# WARN lines are advisory (fix before long pytest / treat as reinstall signal if many fail).

set -u

NS="${OSAC_NAMESPACE:-osac-e2e-ci}"
HUB_KC="${KUBECONFIG:-}"
VIRT_KC="${OSAC_VM_KUBECONFIG:-}"

CRIT_FAIL=0
WARN_FAIL=0

die() { echo "CRITICAL: $*" >&2; CRIT_FAIL=$((CRIT_FAIL + 1)); }
warn() { echo "WARN: $*" >&2; WARN_FAIL=$((WARN_FAIL + 1)); }
ok() { echo "OK  $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { die "missing command: $1"; return 1; }
}

oc_hub() { oc --kubeconfig="$HUB_KC" "$@"; }
oc_virt() { oc --kubeconfig="$VIRT_KC" "$@"; }

echo "=== OSAC sanity check ==="
echo "Namespace: $NS"
echo

need_cmd oc || true
if [[ -z "$HUB_KC" || ! -f "$HUB_KC" ]]; then
  die "KUBECONFIG must point to an existing hub kubeconfig file (got: ${HUB_KC:-empty})"
fi
if [[ -z "$VIRT_KC" || ! -f "$VIRT_KC" ]]; then
  die "OSAC_VM_KUBECONFIG must point to an existing virt kubeconfig file (got: ${VIRT_KC:-empty})"
fi

echo "--- Hub: API identity ---"
if oc_hub whoami &>/dev/null; then
  ok "hub whoami: $(oc_hub whoami) server=$(oc_hub whoami --show-server)"
else
  die "hub: oc whoami failed"
fi

echo "--- Virt: API identity ---"
if oc_virt whoami &>/dev/null; then
  ok "virt whoami: $(oc_virt whoami) server=$(oc_virt whoami --show-server)"
else
  die "virt: oc whoami failed"
fi

echo "--- Hub: namespace and core workloads ---"
if oc_hub get ns "$NS" &>/dev/null; then
  ok "hub namespace $NS exists"
else
  die "hub: namespace $NS missing"
fi

if oc_hub get crd computeinstances.osac.openshift.io &>/dev/null; then
  ok "hub CRD computeinstances.osac.openshift.io present"
else
  die "hub: ComputeInstance CRD missing (install / repair osac-operator or CRDs)"
fi

# Install uses Service fulfillment-api (ClusterIP); workloads are separate Deployments (no deploy/fulfillment-api).
for deploy in fulfillment-controller fulfillment-grpc-server osac-operator-controller-manager; do
  if oc_hub -n "$NS" get deploy "$deploy" &>/dev/null; then
    ready=$(oc_hub -n "$NS" get deploy "$deploy" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || echo "?/?")
    if [[ "$ready" == "1/1" ]] || [[ "$ready" == */1 ]]; then
      ok "hub deploy/$deploy ready=$ready"
    else
      warn "hub deploy/$deploy not fully ready: $ready (oc -n $NS describe deploy/$deploy)"
    fi
  else
    warn "hub deploy/$deploy not found (is OSAC installed in $NS?)"
  fi
done
if oc_hub -n "$NS" get svc fulfillment-api &>/dev/null; then
  ok "hub svc/fulfillment-api exists (in-cluster gRPC/HTTP for controller and routes)"
else
  warn "hub svc/fulfillment-api not found"
fi

echo "--- Hub: fulfillment-controller RBAC (controller SA) ---"
if oc_hub auth can-i list computeinstances.osac.openshift.io -n "$NS" \
  --as="system:serviceaccount:${NS}:controller" 2>/dev/null | grep -q yes; then
  ok "SA ${NS}:controller can list computeinstances"
else
  die "SA ${NS}:controller cannot list computeinstances (add Role/RoleBinding for fulfillment controller)"
fi

echo "--- Hub: fulfillment-controller pod / args drift ---"
img=$(oc_hub -n "$NS" get deploy fulfillment-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [[ -n "$img" ]]; then
  ok "fulfillment-controller image: $img"
  if oc_hub -n "$NS" get deploy fulfillment-controller -o yaml 2>/dev/null | grep -q 'token-file'; then
    if [[ "$img" == *:main* ]] && [[ "$img" != *@sha256:* ]]; then
      warn "Deployment uses --token-file with floating :main image; pin @sha256:… or switch to OAuth flags + fulfillment-controller-credentials (see upstream deployment.yaml)."
    fi
  fi
else
  warn "could not read fulfillment-controller image"
fi

crash=$(oc_hub -n "$NS" get pods -l app=fulfillment-service,component=controller \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null || true)
if echo "$crash" | grep -qi CrashLoop; then
  warn "fulfillment-controller pod in CrashLoopBackOff — oc logs deploy/fulfillment-controller -c controller"
fi

echo "--- Hub: recent controller errors ---"
if oc_hub -n "$NS" logs deploy/fulfillment-controller -c controller --since=10m 2>/dev/null | grep -iE 'reconciliation failed|no matches for kind .ComputeInstance|unknown flag' | tail -5 | grep .; then
  warn "Recent fulfillment-controller errors (see lines above). Often: wrong Hub kubeconfig in fulfillment DB (virt vs hub) or CRD/API mismatch."
else
  ok "no recent Reconciliation failed / ComputeInstance / unknown-flag lines in last 10m logs"
fi

echo "--- Virt: CNV / nodes ---"
if oc_virt get nodes &>/dev/null; then
  ok "virt: $(oc_virt get nodes --no-headers 2>/dev/null | wc -l) node(s)"
else
  die "virt: cannot list nodes"
fi

if oc_virt get csv -A 2>/dev/null | grep -qi kubevirt; then
  ok "virt: KubeVirt-related CSV present"
else
  warn "virt: no obvious KubeVirt CSV in oc get csv -A (CNV may still be OK under another name)"
fi

echo "--- CLI for pytest ---"
if command -v osac >/dev/null 2>&1; then
  ok "osac on PATH: $(command -v osac)"
elif command -v fulfillment-cli >/dev/null 2>&1; then
  warn "fulfillment-cli on PATH but tests default to OSAC_CLI_PATH=osac — export OSAC_CLI_PATH=$(command -v fulfillment-cli)"
else
  warn "neither osac nor fulfillment-cli on PATH (pytest session may fail at login)"
fi

echo
echo "=== Summary ==="
echo "Critical failures: $CRIT_FAIL"
echo "Warnings:          $WARN_FAIL"
if [[ "$CRIT_FAIL" -gt 0 ]]; then
  echo
  echo "Reinstall / repair: fix critical items first. If the hub is inconsistent, re-apply osac-installer"
  echo "overlay for this env (e.g. vmaas-ci) or follow your lab reinstall doc; then re-run this script."
  exit 1
fi
if [[ "$WARN_FAIL" -gt 0 ]]; then
  echo
  echo "All critical checks passed; address warnings before a long pytest run."
  exit 0
fi
echo "All checks passed."
exit 0
