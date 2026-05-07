# Nested OpenHCL on KVM — Session Summary

## Goal

Run OpenVMM/OpenHCL as a paravisor inside a KVM guest, using the nested KVM
approach from the `kvm` branch of `chris-oo/openvmm`.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Azure Host (L0)                                         │
│  ┌────────────────────────────────────────────────────┐  │
│  │  Azure VM "L1" — Ubuntu 6.17, AMD EPYC 9V45       │  │
│  │  /dev/kvm (nested=1), 4 vCPUs, 16GB RAM           │  │
│  │                                                     │  │
│  │  ┌─── openvmm (host VMM) ───────────────────────┐  │  │
│  │  │  • Loads IGVM image (openhcl-x64-nested.bin)  │  │  │
│  │  │  • Creates KVM VM via /dev/kvm                │  │  │
│  │  │  • Emulates: serial, VMBus, storvsc           │  │  │
│  │  │  • Provides Hyper-V enlightenments to guest   │  │  │
│  │  └──────────────┬────────────────────────────────┘  │  │
│  │                 │ KVM_RUN                           │  │
│  │  ┌──────────────▼────────────────────────────────┐  │  │
│  │  │  OpenHCL "L2" — OHCL Kernel 6.12.52           │  │  │
│  │  │  (paravisor / VTL2-like role)                  │  │  │
│  │  │                                                │  │  │
│  │  │  underhill_init                                │  │  │
│  │  │   ├─ loads kvm.ko         ✅                   │  │  │
│  │  │   ├─ loads kvm-amd.ko     ✅                   │  │  │
│  │  │   │   • Nested Virtualization enabled          │  │  │
│  │  │   │   • Nested Paging enabled                  │  │  │
│  │  │   │   • TSC scaling supported                  │  │  │
│  │  │   └─ starts underhill_core (VMM)               │  │  │
│  │  │       ├─ creates /dev/kvm L3 VM   ✅           │  │  │
│  │  │       ├─ VMBus + storvsc          ✅           │  │  │
│  │  │       └─ GET pipe lookup          ❌           │  │  │
│  │  │                                                │  │  │
│  │  │  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐  │  │
│  │  │    Guest OS "L3" (never reached)               │  │
│  │  │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Environment

| Component | Detail |
|-----------|--------|
| L1 Host CPU | AMD EPYC 9V45 96-Core (4 vCPUs exposed) |
| L1 Host Kernel | 6.17.0-1010-azure-fde (Ubuntu) |
| L1 RAM | 16 GB |
| Nested Virt | Enabled (`/sys/module/kvm_amd/parameters/nested = 1`) |
| Rust | 1.95.0 |

## What We Built

### 1. openvmm Host VMM (`kvm` branch)

**Source:** `chris-oo/openvmm`, branch `kvm` (22 commits since `40bcf36c`)

Fixed 5 compilation errors to build against current `main` dependencies:

| File | Fix |
|------|-----|
| `partition.rs` | Fixed `virt::Synic` trait path → `virt::synic::Synic`; changed `into_synic()` return type to `Arc<dyn vmcore::synic::SynicPortAccess>` |
| `vp.rs` | Renamed `ChipsetPlusSynic` → `AdaptedChipset` |
| `worker.rs` | Fixed `Kvm` unit struct → `Kvm::new()?`; simplified synic creation; added missing `pci_chipset_devices`, `capabilities` fields to `VmChipsetResult` destructure; removed duplicate `serial_inputs` |
| `openvmm_entry/lib.rs` | Removed broken MCP server code block |
| `openvmm_mcp/src/lib.rs` | Created missing stub file for workspace compilation |

**Build:** `cargo build -p openvmm`

### 2. OpenHCL IGVM Image

**Build:** `cargo xflowey build-igvm x64-nested`

Produces `openhcl-x64-nested.bin` (~100 MB), configured with:
- `max_vtl: 0`, `isolation_type: none`
- `OPENHCL_KVM=1` environment variable
- OHCL kernel + initrd with KVM modules

### 3. OHCL Kernel with KVM Support

**Source:** `microsoft/OHCL-Linux-Kernel`, tag `rolling-lts/hcl-dev/6.12.52.5`

The stock OHCL kernel has **no KVM support** (`CONFIG_KVM` not set). We rebuilt
it from source:

1. **Cloned** the kernel at the exact revision matching the dev package
   (`2d93d01fe778`)
2. **Enabled KVM** in `.config`: `CONFIG_KVM=m`, `CONFIG_KVM_AMD=m`,
   `CONFIG_KVM_INTEL=m`, plus auto-selected dependencies
   (`PREEMPT_NOTIFIERS`, `MMU_NOTIFIER`, `VHOST_TASK`, etc.)
3. **Fixed missing code**: Added `kvm_lapic_get_reg`, `kvm_lapic_set_reg` and
   their 64-bit / raw (`__kvm_lapic_*`) variants as inlines in
   `arch/x86/kvm/lapic.h` — these were missing from the OHCL tree
4. **Full kernel rebuild** (`make bzImage && make modules`) — required because
   the kernel must export symbols (`preempt_notifier_*`, `mmu_notifier_*`,
   `fpu_*`, `vhost_task_*`) that KVM modules depend on
5. **Replaced** `vmlinux` and KVM `.ko` files in the OHCL kernel package used
   by the IGVM build

## Run Command

```bash
sudo ./target/debug/openvmm \
  --igvm flowey-out/artifacts/build-igvm/debug/x64-nested/openhcl-x64-nested.bin \
  --igvm-vtl2-relocation-type disable \
  --hv -m 4GB -p 1 \
  --com3 stderr
```

**Notes:**
- Use `--hv` not `--vtl2` (IGVM has `max_vtl:0`)
- Use `-p 1` (single VP) — multi-VP has SMP/SIPI issues
- Use `--com3 stderr` for serial output (headless VM, no terminal)
- Do NOT use `--com3 file=` (broken in this build)

## Results

| Boot Stage | Status |
|------------|--------|
| OHCL kernel boots | ✅ |
| underhill_init starts | ✅ |
| `kvm.ko` loads | ✅ |
| `kvm-amd.ko` loads (nested virt + paging) | ✅ |
| underhill_core creates nested L3 VM | ✅ |
| VMBus negotiation + storvsc channel | ✅ |
| GET (Guest Emulation Transport) pipe | ❌ |
| L3 guest OS boots | ❌ Not reached |

## Key Findings

### What Works
- The nested KVM approach is viable on AMD hardware with nested virt
- KVM modules can be built for the OHCL kernel with minor patching
- OpenHCL boots, loads KVM, creates the L2→L3 nested VM, and negotiates VMBus

### Remaining Issues

1. **GET pipe not available** — The VMM worker fails with:
   ```
   failed to launch GET: couldn't find uio device:
   failed to read directory `/sys/bus/vmbus/devices/.../uio`
   ```
   The host openvmm doesn't expose the Guest Emulation Transport VMBus device
   that underhill_core expects. This is the immediate blocker for L3 guest boot.

2. **SMP broken with >1 VP** — Secondary VPs triple-fault at the reset vector.
   The SIPI (Startup Inter-Processor Interrupt) delivery for AP startup doesn't
   work correctly. Workaround: use `-p 1`.

3. **Non-fatal MSR errors** — MSRs `0x3a` (`IA32_FEATURE_CONTROL`) and `0xd90`
   (Hyper-V related) return read errors. These don't block boot.

### Architectural Notes (KVM Planes vs Nested KVM)

The `kvm` branch uses **nested KVM** (L2 VM), not the new **KVM Planes**
feature described in `linux-kvm-planes.md`. Key differences:

| Aspect | Nested KVM (current) | KVM Planes (future) |
|--------|---------------------|---------------------|
| Execution model | Self-driven (OpenHCL calls `KVM_RUN`) | Host-driven (host calls `KVM_RUN` with plane) |
| Privilege | OpenHCL is L1 kernel with full KVM | Plane 0 runs at higher privilege, host-managed |
| Trap handling | OpenHCL intercepts L2 exits directly | `KVM_EXIT_PLANE_EVENT` notifies host |
| Hardware | Needs nested virt (VT-x/AMD-V) | Native, no nested virt overhead |
| Maturity | Working (this branch) | RFC stage in Linux kernel |

## Repos

| Repo | Branch | URL |
|------|--------|-----|
| openvmm (fork) | `kvm` | https://github.com/haitaohuang/openvmm/tree/kvm |
| OHCL-Linux-Kernel (fork) | `kvm-nested` | https://github.com/haitaohuang/OHCL-Linux-Kernel/tree/kvm-nested |

## Next Steps

1. **Fix GET dependency** — Either expose GET pipe from host openvmm, or make
   GET optional in underhill_core for the nested KVM path
2. **Fix SMP** — Debug SIPI delivery for multi-VP support
3. **Evaluate KVM Planes** — When the RFC lands in mainline Linux, prototype a
   planes-based backend as an alternative to nested KVM
