# VMaaS e2e — per-test event sequences

> If you keep a duplicate under personal lab docs, edit **this** file first and re-copy so the repo stays canonical.

Use this when designing **unit tests** (mock boundaries) or **contract tests** against fulfillment / operator behavior.  
**Hub** = `KUBECONFIG`; **virt** = `OSAC_VM_KUBECONFIG`; namespace = `OSAC_NAMESPACE` (default `osac-devel`).

## Session setup (all tests in `tests/vmaas/`)

**Description:** Before any test function runs, pytest builds shared **session-scoped** fixtures. These resolve the fulfillment endpoint, mint Kubernetes credentials for **gRPC** and **`osac login`**, and construct kubectl wrappers for the **hub** (management cluster, where `ComputeInstance` and fulfillment run) and **virt** (workload cluster, where KubeVirt VMs/VMIs usually live). Networking tests also load the default **NetworkClass** name from the environment.

| Step | Actor | Event |
|------|--------|--------|
| S1 | pytest | Load `tests/conftest.py` + `tests/vmaas/conftest.py` |
| S2 | `cluster_domain` | `kubectl get ingress.config.openshift.io cluster` (hub) |
| S3 | `fulfillment_address` | Resolve host:port (`OSAC_FULFILLMENT_ADDRESS` or derived) |
| S4 | `grpc` | `oc create token` SA → `GRPCClient` |
| S5 | `cli` | `osac login --address … --token-script …` (session) |
| S6 | `k8s_hub_client` | `K8sClient(namespace)` — hub kubectl |
| S7 | `k8s_virt_client` | `K8sClient(namespace, kubeconfig=OSAC_VM_KUBECONFIG)` — virt kubectl |
| S8 | `vm_template` | From `OSAC_VM_TEMPLATE` (default `osac.templates.ocp_virt_vm`) |
| S9 | `network_class` | From `OSAC_NETWORK_CLASS` (default `cudn_net`) |

Compute-instance tests use **S1–S8**; networking tests use **S1–S7, S9** (no `cli` unless test requests it).

---

## Poll / wait primitives (from `tests/helpers.py`)

**Description:** Most e2e tests do not sleep blindly; they **poll** hub or virt state until a predicate holds or a time budget is exhausted. The helpers below wrap `poll_until` with domain-specific predicates (CR presence, job state, phase, etc.). Typical budgets are shown; slow clusters or capacity limits may require tuning.

| Helper | Poll condition | Typical budget |
|--------|----------------|----------------|
| `wait_for_cr` | Hub: `ComputeInstance` name for UUID | 30×2s |
| `wait_for_provision` | Latest `provision` job `state == Succeeded` | 120×5s |
| `wait_for_running` | `ComputeInstance.status.phase == Running` | 90×10s |
| `wait_for_deletion` | CR absent | 60×5s |
| `wait_for_restart` | `lastRestartedAt` updated vs initial and ≥ restart_ts | 30×10s |
| `wait_for_virtual_network_cr` | VN CR name for UUID | 30×2s |
| `wait_for_virtual_network_ready` | VN phase `Ready` | 60×5s |
| `wait_for_virtual_network_deletion` | VN CR gone | 60×5s |
| `wait_for_subnet_cr` | Subnet CR name for UUID | 30×2s |
| `wait_for_subnet_ready` | Subnet phase `Ready` | 60×5s |
| `wait_for_subnet_deletion` | Subnet CR gone | 60×5s |

---

## `test_compute_instance_creation.py`

### `test_compute_instance_lifecycle`

**Description:** **Primary VMaaS happy-path.** Creates a compute instance through **`osac`** (fulfillment public API), confirms it appears in the **gRPC** catalog, waits on the **hub** until the `ComputeInstance` CR exists, **provision** finishes (`Succeeded`), and **phase** is **Running**. Then checks on the **virt** cluster that a **VMI** exists for that instance (by label). Finally deletes via **`osac`**, waits for the **hub** CR to disappear, and asserts the UUID is gone from **gRPC**. Validates the full loop: **CLI → fulfillment → operator/AAP → KubeVirt → delete → cleanup**.

| # | Surface | Event |
|---|---------|--------|
| 1 | CLI | `osac create computeinstance` → UUID |
| 2 | gRPC | `uuid ∈ ListComputeInstances` |
| 3 | Hub K8s | Wait CR name for UUID (`wait_for_cr`) |
| 4 | Hub K8s | Wait provision job `Succeeded` (`wait_for_provision`) |
| 5 | Hub K8s | Wait phase `Running` (`wait_for_running`) |
| 6 | Hub K8s | Read `status.virtualMachineReference.namespace` |
| 7 | Virt K8s | VMI creation timestamp non-empty for CI name + label |
| 8 | CLI | `osac delete computeinstance` |
| 9 | Hub K8s | Wait CR deleted (`wait_for_deletion`) |
| 10 | gRPC | `uuid ∉ ListComputeInstances` |

**Unit-test seams:** mock `OsacCLI`, `GRPCClient`, `K8sClient` methods above; assert ordering and calls.

---

## `test_compute_instance_delete_during_provision.py`

### `test_compute_instance_delete_during_provision`

**Description:** **Cancellation while provisioning.** Starts a normal create, waits until a **provision** job ID exists and the job is still in a non-terminal state (`Running`, `Pending`, or `Unknown`), and confirms **no deprovision** job has started yet. Issues **`osac delete`** mid-flight, then waits for provision to **terminate**, deprovision to finish **without** `Failed`, and the deprovision job ID to remain **stable** (no accidental second deprovision). After the **hub** CR is gone and **gRPC** no longer lists the UUID, scans **all namespaces** on **virt** for `VirtualMachine` objects labeled with that instance name and asserts **none** remain—**no orphaned VMs** after an aborted provision.

| # | Surface | Event |
|---|---------|--------|
| 1 | CLI | `osac create computeinstance` → UUID |
| 2 | Hub K8s | Wait CR (`wait_for_cr`) |
| 3 | Hub K8s | Wait provision **job id** non-empty |
| 4 | Hub K8s | Assert provision state ∈ `Running`, `Pending`, `Unknown` |
| 5 | Hub K8s | Assert no deprovision job id yet |
| 6 | CLI | `osac delete computeinstance` |
| 7 | Hub K8s | Wait provision state terminal (`Canceled` / `Failed` / `Succeeded`) or empty |
| 8 | Hub K8s | Wait deprovision terminal or CR gone; assert not `Failed` |
| 9 | Hub K8s | Assert deprovision job id stable (no duplicate) |
| 10 | Hub K8s | Wait CR deleted |
| 11 | gRPC | UUID not in list |
| 12 | Virt K8s | Count VMs by label `osac.openshift.io/computeinstance=<name>` == 0 |

---

## `test_compute_instance_restart.py`

### `test_compute_instance_restart`

**Description:** **Restart via public gRPC** on an already **Running** instance (create path uses **CLI**; restart uses **`grpc.update_restart`** with a fresh UTC timestamp). Asserts **`status.lastRestartedAt`** moves forward and is **≥** the requested timestamp, that the **VMI** on **virt** gets a **new** `creationTimestamp` (pod/VMI recreated), and that **`RestartFailed`** is absent or **False**. Deletes the instance at the end. Validates that the restart contract is honored end-to-end across hub status and virt workload.

| # | Surface | Event |
|---|---------|--------|
| 1 | CLI | Create → UUID |
| 2 | Hub K8s | Wait CR |
| 3 | Hub K8s | Wait phase `Running` (skips explicit `wait_for_provision`) |
| 4 | Hub K8s | Read VM namespace |
| 5 | Virt K8s | Read initial VMI creation timestamp |
| 6 | Hub K8s | Read initial `status.lastRestartedAt` |
| 7 | gRPC | `Update` restart with new UTC timestamp |
| 8 | Hub K8s | `wait_for_restart` |
| 9 | Hub K8s | Assert `lastRestartedAt` non-empty, changed, ≥ requested ts |
| 10 | Virt K8s | Poll until VMI creation timestamp ≠ original |
| 11 | Virt K8s | Assert new ts > original |
| 12 | Hub K8s | `RestartFailed` condition empty or `False` |
| 13 | CLI | Delete instance |
| 14 | Hub K8s | Wait CR deleted |

---

## `test_compute_instance_restart_negative.py`

### `test_compute_instance_restart_past_timestamp_ignored`

**Description:** **Idempotence / monotonicity of restart time.** Brings an instance to **Running**, performs one **valid** restart and waits until **`lastRestartedAt`** reflects it, then sends a second **`update_restart`** with a deliberately **old** timestamp (`2020-01-01…`). After a short settle, **`lastRestartedAt` must not move backward**—stale requests should be ignored. Cleans up with **CLI** delete. Does **not** use **virt** client (hub-only assertion after the first restart).

| # | Surface | Event |
|---|---------|--------|
| 1 | CLI | Create → UUID |
| 2 | Hub K8s | Wait CR |
| 3 | Hub K8s | Wait `Running` |
| 4 | gRPC | Valid restart with current UTC ts |
| 5 | Hub K8s | `wait_for_restart` |
| 6 | Hub K8s | Save `lastRestartedAt` |
| 7 | gRPC | `Update` restart with **past** ts `2020-01-01T00:00:00Z` |
| 8 | (wall) | `sleep(15)` |
| 9 | Hub K8s | Assert `lastRestartedAt` unchanged |
| 10 | CLI | Delete |
| 11 | Hub K8s | Wait CR deleted |

---

## `test_compute_instance_cli_fields.py`

### `test_compute_instance_cli_explicit_fields`

**Description:** **CLI flag plumbing into the hub CR and Secrets.** Creates an instance with explicit **cores**, **memory**, **boot disk size**, **container image**, **image source type**, **runStrategy**, and **user-data** (cloud-init snippet). Asserts the **`ComputeInstance.spec`** on the hub matches those values; that **`userDataSecretRef.name`** follows `{uuid}-user-data`; that the **Secret** holds base64 **userdata** matching the input and has an **ownerReference** to the **ComputeInstance**. Then runs standard **provision** and **Running** waits and deletes. Validates that **`osac create`** options are faithfully represented in Kubernetes objects.

| # | Surface | Event |
|---|---------|--------|
| 1 | CLI | `create_compute_instance` with explicit cores/memory/disk/image/runStrategy/userData |
| 2 | gRPC | UUID in list |
| 3 | Hub K8s | Wait CR |
| 4 | Hub K8s | `get_json` ComputeInstance `spec` — assert cores, memoryGiB, bootDisk, image, runStrategy |
| 5 | Hub K8s | Assert `userDataSecretRef.name == {uuid}-user-data` |
| 6 | Hub K8s | `get_json` Secret — userdata base64, ownerReferences → ComputeInstance |
| 7 | Hub K8s | `wait_for_provision` |
| 8 | Hub K8s | `wait_for_running` |
| 9 | CLI | Delete |
| 10 | Hub K8s | Wait CR deleted |

---

## `test_compute_instance_api_fields.py`

### `test_compute_instance_api_fields`

**Description:** **Direct API behavior without fulfillment CLI.** Applies a **YAML** `ComputeInstance` to the **hub** (unique name, **tenant** annotation), waits **provision** and **Running**, reads the **VM namespace** from status, then exercises **mutability** of **`runStrategy`**: patch to **Halted** and poll **virt** until the **VirtualMachine** reports **Stopped** and **Halted**; patch back to **Always** and poll until **Running**. Then attempts forbidden patches—**cores**, **memoryGiB**, and **image**—and expects **kubectl** failure with messages containing **`cores is immutable`**, **`memoryGiB is immutable`**, and **`image is immutable`**. Deletes the CR and waits for removal. Separates **operator admission / KubeVirt sync** from **fulfillment** create.

| # | Surface | Event |
|---|---------|--------|
| 1 | Hub K8s | `kubectl apply` YAML ComputeInstance (name `e2e-test-api-fields-<epoch>`, tenant annotation) |
| 2 | Hub K8s | `wait_for_provision` |
| 3 | Hub K8s | `wait_for_running` |
| 4 | Hub K8s | Read VM namespace from CR |
| 5 | Hub K8s | Merge patch `runStrategy: Halted` |
| 6 | Virt K8s | Poll VM `printableStatus == Stopped` |
| 7 | Virt K8s | Assert VM `runStrategy` / `printableStatus` |
| 8 | Hub K8s | Patch `runStrategy: Always` |
| 9 | Virt K8s | Poll VM `printableStatus == Running` |
| 10 | Virt K8s | Assert VM strategy/status |
| 11 | Hub K8s | Patch `cores: 8` → expect failure + message contains `cores is immutable` |
| 12 | Hub K8s | Patch `memoryGiB: 16` → immutability error |
| 13 | Hub K8s | Patch image `sourceRef` → immutability error |
| 14 | Hub K8s | `oc delete computeinstance` |
| 15 | Hub K8s | `wait_for_deletion` |

**Note:** No `cli` / fulfillment create; direct API apply.

---

## `test_virtual_network_lifecycle.py`

### `test_virtual_network_lifecycle`

**Description:** **VirtualNetwork-only lifecycle** over **gRPC**. Creates a VN with a generated name, **NetworkClass** from env (`OSAC_NETWORK_CLASS`), and IPv4 CIDR; waits for the **hub** `VirtualNetwork` CR and **Ready** phase; verifies the id appears in **List** APIs; deletes via **gRPC**; waits for CR deletion and for the id to disappear from listings. Covers **L3 network** provisioning without compute instances.

| # | Surface | Event |
|---|---------|--------|
| 1 | gRPC | Create VirtualNetwork → id |
| 2 | Hub K8s | Wait VN CR name for id |
| 3 | gRPC | id ∈ list VN ids |
| 4 | Hub K8s | Wait VN phase `Ready` |
| 5 | gRPC | Delete VirtualNetwork |
| 6 | Hub K8s | Wait VN CR deleted |
| 7 | gRPC | Poll until id ∉ list |

---

## `test_subnet_lifecycle.py`

### `test_subnet_lifecycle`

**Description:** **Subnet nested under VirtualNetwork.** Provisions a **VirtualNetwork** and waits until **Ready**, then creates a **Subnet** (smaller CIDR inside the VN space) via **gRPC**, waits for the **Subnet** CR and **Ready**, deletes the **Subnet** first and confirms API + CR cleanup, then deletes the parent **VirtualNetwork** and confirms removal from **gRPC** lists. Validates **ordering** (child before parent delete) and **referential** consistency between VN and Subnet resources.

| # | Surface | Event |
|---|---------|--------|
| 1 | gRPC | Create VirtualNetwork → vn_id |
| 2 | Hub K8s | Wait VN CR; wait VN `Ready` |
| 3 | gRPC | Create Subnet on that VN → subnet_id |
| 4 | Hub K8s | Wait Subnet CR |
| 5 | gRPC | subnet_id ∈ list |
| 6 | Hub K8s | Wait Subnet `Ready` |
| 7 | gRPC | Delete Subnet |
| 8 | Hub K8s | Wait Subnet CR gone |
| 9 | gRPC | Poll subnet id ∉ list |
| 10 | gRPC | Delete VirtualNetwork |
| 11 | Hub K8s | Wait VN CR gone |
| 12 | gRPC | Poll vn_id ∉ list |

---

## Unit-test mapping hints

**Description:** When **unit-testing** the test module itself (or building parallel **contract** tests), replace external I/O at these boundaries with fakes. Integration tests keep real **`poll_until`** against a cluster or envtest; pure unit tests inject predetermined **job states**, **phases**, and **timestamps** so the tables above can be exercised without **oc**/**osac**.

| Boundary | Mock / stub candidates |
|----------|-------------------------|
| `OsacCLI` | `create_compute_instance`, `delete_compute_instance` return values |
| `GRPCClient` | `list_*_ids`, `create_*`, `delete_*`, `update_restart`, `call` |
| `K8sClient` | `get_*`, `is_present`, `apply`, `patch`, `delete`, `get_json` |
| `run` / `poll_until` | Replace with fixed timelines or fake clock for pure unit tests |

For **integration** tests, keep real `poll_until` but swap cluster doubles; for **pure unit** tests of test logic, inject fakes that emit the status transitions in the tables above.
