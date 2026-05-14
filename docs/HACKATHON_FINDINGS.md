# Hackathon Findings: Nested SNP Mini-VM with OpenHCL Kernel

> **Update 2026-05-14:** What was originally marked "Phase 5 blocked"
> below has since been **completed** via a separate workstream — a
> 17-patch backport of jepio's nested-SNP series to stock Ubuntu 25.10
> + Chris Oo's `openvmm-snp` branch. See
> [`REPRODUCE_PHASE5.md`](hackathon/REPRODUCE_PHASE5.md) for the
> reproducer and the companion [`REPORT_nested_snp_openvmm.md`][repnest]
> in `haitaohuang/vm_enclave` for the full post-mortem.
>
> A **Phase 6** investigation has also begun on **SMT Protection**
> (Kim Phillips's KVM RFC, 2025-08-07). The kernel patch is pre-applied
> on branch `smt-protection-dryrun`; the OpenVMM userspace prototype
> is on branch `feature/smt-protection`. Hardware verification is
> blocked on cc_v6 (Genoa) access — see the
> `smt-protection-hackathon/` folder in `haitaohuang/vm_enclave` for
> the full handoff.
>
> [repnest]: https://github.com/haitaohuang/vm_enclave/blob/main/REPORT_nested_snp_openvmm.md

## Goal
Launch a simple app on top of the OpenHCL Linux kernel inside an SEV-SNP
protected mini VM, with **no paravisor** inside the mini VM. This is run
nested on an Azure VM that itself has SNP enabled (L1), to launch an
SNP-protected L2 mini VM.

## TL;DR

| Phase | What | Status |
|-------|------|--------|
| 1 | Environment setup, prereqs | ✅ Done |
| 2 | Build OHCL 6.12.52 kernel + initramfs | ✅ Done (3 patches needed) |
| 3 | OHCL boots in SNP-protected QEMU (L2) | ✅ **WORKS** with one PMU hack — see [REPRODUCE_PHASE3.md](hackathon/REPRODUCE_PHASE3.md) |
| 4 | OHCL boots in openvmm without paravisor | ✅ **WORKS** (no isolation) — see [REPRODUCE_PHASE4.md](hackathon/REPRODUCE_PHASE4.md) |
| 5 | OHCL boots in openvmm with SNP isolation | ✅ **WORKS** via the `openvmm_nested_snp` branch + patched 6.17 host kernel — see [REPRODUCE_PHASE5.md](hackathon/REPRODUCE_PHASE5.md) |
| 6 | SMT Protection (Kim Phillips RFC) prototype | 🟡 Pre-staged, kernel + OpenVMM patches compile clean; hardware-verification blocked on cc_v6 access |

**Bottom line**: Booting an OHCL kernel inside an SNP-protected mini VM
on this host is feasible **on both QEMU 9.2 and OpenVMM**. The
hackathon-scaffolding `IsolationType::Snp` plumbing was the foundation;
a separate effort then ported jepio's 17-patch Hyper-V nested-SNP host
stack to Ubuntu 25.10 and rebuilt OpenVMM from Chris Oo's `openvmm-snp`
branch, which together close the loop. The next frontier (Phase 6) is
SMT Protection on Genoa, currently held by hardware access.

---

## Phase 2: OHCL Kernel build issues (kvm-nested branch, 6.12.52 base)

The Microsoft-patched OHCL kernel does not build cleanly with stock
`x86_64_defconfig` once you turn on SEV-SNP guest options. Three small
fixes were needed:

### Fix 1: `include/asm-generic/hyperv-tlfs.h`
The file uses `u128 reg128` in a structure that gets pulled into vdso32
build, which has no `u128` typedef. Replaced with a `struct { u64 low,
high; }`. The field is unused.

### Fix 2: `kernel/smp.c`
A custom OHCL patch attempts `cpu_boot_mask = mask` where `cpu_boot_mask`
is `cpumask_var_t` — an array type when `CONFIG_CPUMASK_OFFSTACK` is not
set. Fixed with `cpumask_copy()` plus a `cpu_boot_mask_set` flag.

### Fix 3: `arch/x86/hyperv/hv_init.c`
`get_vtl()` is referenced from generic Hyper-V init but only defined in
`hv_vtl.c` (built with `CONFIG_HYPERV_VTL_MODE`). Added a stub returning
0 when VTL mode is off.

### Configuration
Started from `x86_64_defconfig`, then added:
- `CONFIG_AMD_MEM_ENCRYPT=y`, `CONFIG_SEV_GUEST=y`
- `CONFIG_VIRTIO_BLK=y`, `CONFIG_VIRTIO_NET=y`, `CONFIG_VIRTIO_PCI=y`,
  `CONFIG_VIRTIO_MMIO=y`
- `CONFIG_DEVTMPFS=y`, `CONFIG_DEVTMPFS_MOUNT=y`
- `CONFIG_HYPERV=y` (kept disabled: `CONFIG_HYPERV_VTL_MODE`)

---

## Phase 3: QEMU 9.2 SNP Boot — **WORKS**

Successfully booted the 6.12.52 OHCL kernel as an SNP guest with
`/dev/sev-guest` available. Key dmesg output:

```
[    0.354815] Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP
[    0.355693] SEV: Status: SEV SEV-ES SEV-SNP
[    0.505271] SEV: Using SNP CPUID table, 31 entries present.
[    0.505798] SEV: SNP running at VMPL0.
[    1.037949] SEV: SNP guest platform device initialized.
[    1.359644] sev-guest sev-guest: Initialized SEV guest driver
```

### Issue encountered: AMD PMU panic
On first boot, the kernel panicked at `init_hw_perf_events` reading
`MSR 0xc0010000` (`MSR_K7_EVNTSEL0`). Backtrace shows
`vc_raw_handle_exception → kernel_exc_vmm_communication → check_hw_exists`.

**Root cause**: The host kernel's `#VC` handler responds with
`ES_VMM_ERROR` (which the guest treats as fatal) for unhandled MSRs,
instead of injecting `#GP` so `rdmsrl_safe` can fail gracefully. This
is a known limitation of pre-upstream SNP host kernels (see
`amdsev-kernel-gap-analysis.md`).

**Hack workaround**: Added an early-return in `amd_pmu_init()` when
running under SEV-SNP. The PMU is unavailable inside the guest anyway
(the host doesn't expose `perfctr-core`), so disabling it is correct:

```c
/* arch/x86/events/amd/core.c */
__init int amd_pmu_init(void)
{
    int ret;

    /* HACK (nested SNP): avoid panic from rdmsrl_safe(0xc0010000)
     * because host #VC handler returns ES_VMM_ERROR instead of #GP. */
    if (cc_platform_has(CC_ATTR_GUEST_SEV_SNP)) {
        pr_info("amd_pmu: disabled in SEV-SNP guest (nested SNP hack)\n");
        return -ENODEV;
    }
    ...
}
```

A proper fix belongs in the **host** kernel's `#VC` handler — make it
inject `#GP` for unhandled MSRs. That's documented as a known gap.

### Working QEMU command
```bash
sudo /usr/local/bin/qemu-system-x86_64 \
  -enable-kvm -cpu EPYC-v4,-perfctr-core,-ibpb \
  -machine q35,confidential-guest-support=sev0 \
  -smp 1 -m 1024M -no-reboot \
  -drive if=pflash,format=raw,unit=0,file=/usr/local/share/qemu/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/usr/local/share/qemu/OVMF_VARS.fd \
  -kernel /path/to/bzImage \
  -initrd /path/to/initramfs.cpio.gz \
  -append "console=ttyS0 earlyprintk=serial loglevel=7 panic=10 init=/init" \
  -object sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1 \
  -object memory-backend-memfd,id=ram1,size=1024M,share=true \
  -machine memory-backend=ram1 \
  -display none -serial stdio -monitor none
```

Note: `-perfctr-core,-ibpb` suppresses CPUID warnings for features the
nested host doesn't expose.

---

## Phase 4: openvmm Direct Kernel Boot — **WORKS**

The openvmm `--kernel` direct-boot path (no IGVM, no UEFI) works with the
OHCL kernel as long as you pass the **ELF `vmlinux`** (not the bzImage):

```bash
sudo ./target/debug/openvmm \
  --kernel /datadrive/nested_openvmm/OHCL-Linux-Kernel/vmlinux \
  --initrd /datadrive/nested_openvmm/initramfs.cpio.gz \
  --cmdline "console=ttyS0 earlyprintk=serial loglevel=7 panic=10 init=/init" \
  -m 1GB -p 1 --com1 stderr
```

Boot reaches our hello-world init and busybox shell. No SNP, no paravisor.

This is the **easiest path** to extend with SNP if/when openvmm gains it.

---

## Phase 5: openvmm SNP — historical blockers (resolved)

> **Status update (2026-05-13):** Everything in this section was true at
> the time of the hackathon. The "blocked" verdict was **subsequently
> overturned** by a separate workstream — see
> [§"Phase 5 completion"](#phase-5-completion-nested-snp-via-openvmm-2026-05-13)
> below for the resolution. The original blocker analysis is preserved
> here as a record of what was hard about the problem.

### Hard blockers in openvmm's KVM backend (original analysis)

#### B1. The KVM partition flat-out rejects isolation
`vmm_core/virt_kvm/src/arch/x86_64/mod.rs:138-140`:
```rust
if config.isolation.is_isolated() {
    return Err(KvmError::IsolationNotSupported);
}
```

#### B2. CLI / config layer only knows about `Vbs`
`openvmm/openvmm_defs/src/config.rs:437`:
```rust
pub enum IsolationType {
    Vbs,    // No Snp variant
}
```

`openvmm/openvmm_entry/src/cli_args.rs` and `lib.rs:1281` only map a
hypothetical `--isolation vbs` to `IsolationType::Vbs`.

#### B3. IGVM loader hardcodes VBS
`openvmm/openvmm_core/src/worker/vm_loaders/igvm.rs:135`:
```rust
let igvm_file = IgvmFile::new_from_binary(&file_contents,
    Some(igvm::IsolationType::Vbs))
```
And lines 1031-1033 explicitly:
```rust
IgvmDirectiveHeader::SnpVpContext { .. } |
IgvmDirectiveHeader::SnpIdBlock { .. } => todo!("snp not supported"),
```

(For a hackathon we don't actually need IGVM if we use direct boot.)

#### B4. KVM ioctls crate has no SEV/SNP plumbing
`vm/kvm/src/lib.rs` (mod ioctl, lines 25-90) defines roughly 35 KVM
ioctls but none of:
- `KVM_MEMORY_ENCRYPT_OP` (KVMIO 0xba)
- `KVM_MEMORY_ENCRYPT_REG_REGION` / `UNREG_REGION` (0xbb / 0xbc)
- `KVM_SET_USER_MEMORY_REGION2` (0x49) — needed for guest_memfd
- `KVM_SET_MEMORY_ATTRIBUTES` (0xd2)
- `KVM_CREATE_GUEST_MEMFD` (0xd4)

`new_vm()` (line 262) uses `vm_type=0` (KVM_X86_DEFAULT_VM); SNP needs
`vm_type=4` (`KVM_X86_SNP_VM`).

#### B5. Guest memory model is incompatible with SNP
The current `KvmPartition::map_region` (vmm_core/virt_kvm/src/lib.rs:201)
calls `set_user_memory_region` on raw mmap'd anonymous memory. Modern
SNP requires:
- A `guest_memfd` (created via `KVM_CREATE_GUEST_MEMFD`)
- Memory regions registered via `KVM_SET_USER_MEMORY_REGION2` with the
  `guest_memfd` field set
- Per-page `KVM_SET_MEMORY_ATTRIBUTES` to mark pages private
- Then `KVM_SEV_SNP_LAUNCH_UPDATE` to encrypt+measure them

This affects the entire memory abstraction (`vm/vmcore/guestmem`), not
just the KVM ioctl wrapper.

### What the host kernel actually supports
Verified by `strace`-ing QEMU 9.2 doing a successful SNP boot:
- `KVM_MEMORY_ENCRYPT_OP` (0xba) ✅
- `KVM_SET_USER_MEMORY_REGION2` (0xae 0x49 size 0xa0) ✅
- `KVM_SET_MEMORY_ATTRIBUTES` (0xae 0xd2 size 0x20) ✅
- `KVM_CREATE_GUEST_MEMFD` (0xae 0xd4 size 0x40) ✅

So this host has the **modern (mainline 6.11+ style)** SNP API, NOT the
old jepio pre-upstream API. (Initial assumption was wrong — host kernel
banner says `6.7.0-rc6-next-...-snp-host` but it has been updated with
the modern API.)

QEMU bundled at `/tmp/qemu-9.2.0/` is QEMU 9.2.0, not 8.2.

### The minimum SNP launch sequence (per QEMU 9.2 source)
From `target/i386/sev.c`:

```
1.  KVM_CREATE_VM(vm_type=KVM_X86_SNP_VM=4)
2.  Open /dev/sev → sev_fd
3.  KVM_MEMORY_ENCRYPT_OP(KVM_SEV_INIT2 with kvm_sev_init { vmsa_features, ghcb_version=2 })
4.  For each guest memory region:
       fd = KVM_CREATE_GUEST_MEMFD(size, flags=0)
       KVM_SET_USER_MEMORY_REGION2(slot, gpa, size, host_addr, guest_memfd=fd, offset=0)
5.  KVM_MEMORY_ENCRYPT_OP(KVM_SEV_SNP_LAUNCH_START with kvm_sev_snp_launch_start { policy, gosvw, flags })
6.  Load kernel/initrd/CPUID/SECRETS pages into host memory.
7.  For each page:
       KVM_SET_MEMORY_ATTRIBUTES(addr, size, attributes=PRIVATE)
       KVM_MEMORY_ENCRYPT_OP(KVM_SEV_SNP_LAUNCH_UPDATE with kvm_sev_snp_launch_update {
            gfn_start, uaddr, len, type=NORMAL/CPUID/SECRETS/ZERO/UNMEASURED })
8.  KVM_MEMORY_ENCRYPT_OP(KVM_SEV_SNP_LAUNCH_FINISH with kvm_sev_snp_launch_finish {
        id_block_uaddr, id_auth_uaddr, host_data, ... })
9.  KVM_RUN normally; CPU starts at the AP-creation reset vector with
    encrypted state per the launch measurement.
```

OVMF firmware-less direct kernel boot would need to skip OVMF and put
the kernel + cmdline + initrd at the right addresses (this is what
QEMU's `-kernel` path does even for SNP, by populating the loader's
memory map and using a special launch sequence).

### Concrete openvmm patch outline (NOT a hackathon-day deliverable)

```rust
// vm/kvm/src/lib.rs — additions
const KVMIO: u8 = 0xae;
ioctl_readwrite!(kvm_memory_encrypt_op, KVMIO, 0xba, kvm_sev_cmd);
ioctl_write_ptr!(kvm_set_user_memory_region2, KVMIO, 0x49, kvm_userspace_memory_region2);
ioctl_write_ptr!(kvm_set_memory_attributes, KVMIO, 0xd2, kvm_memory_attributes);
ioctl_readwrite!(kvm_create_guest_memfd, KVMIO, 0xd4, kvm_create_guest_memfd);

#[repr(C)]
pub struct kvm_sev_cmd { pub id: u32, pub _pad: u32, pub data: u64,
                         pub error: u32, pub sev_fd: u32, }
#[repr(C)]
pub struct kvm_sev_init { pub vmsa_features: u64, pub flags: u32,
                          pub ghcb_version: u16, pub _pad1: u16,
                          pub _pad2: [u32; 8], }
#[repr(C)]
pub struct kvm_sev_snp_launch_start {
    pub policy: u64, pub gosvw: [u8; 16], pub flags: u16,
    pub _pad0: [u8; 6], pub _pad1: [u64; 4], }
#[repr(C)]
pub struct kvm_sev_snp_launch_update {
    pub gfn_start: u64, pub uaddr: u64, pub len: u64,
    pub ty: u8, pub _pad0: u8, pub flags: u16,
    pub _pad1: u32, pub _pad2: [u64; 4], }

pub const KVM_X86_SNP_VM: u64 = 4;
pub const KVM_SEV_INIT2: u32 = 22;
pub const KVM_SEV_SNP_LAUNCH_START: u32 = 100;
pub const KVM_SEV_SNP_LAUNCH_UPDATE: u32 = 101;
pub const KVM_SEV_SNP_LAUNCH_FINISH: u32 = 102;
pub const KVM_SEV_SNP_PAGE_TYPE_NORMAL: u8 = 1;
pub const KVM_MEMORY_ATTRIBUTE_PRIVATE: u64 = 1 << 3;

// New methods on Kvm/Partition
impl Kvm {
    pub fn new_snp_vm(&self) -> Result<Partition> {
        // Like new_vm but vm_type = KVM_X86_SNP_VM
    }
}
impl Partition {
    pub fn sev_init(&mut self, vmsa_features: u64) -> Result<RawFd> { ... }
    pub fn snp_launch_start(&self, policy: u64) -> Result<()> { ... }
    pub fn snp_launch_update(&self, gfn: u64, host_addr: usize, len: u64,
                             page_type: u8) -> Result<()> { ... }
    pub fn snp_launch_finish(&self, host_data: [u8; 32]) -> Result<()> { ... }
    pub fn create_guest_memfd(&self, size: u64) -> Result<RawFd> { ... }
    pub fn set_memory_region2(&self, slot: u32, gpa: u64, size: u64,
                              host_addr: u64, guest_memfd: RawFd,
                              offset: u64, readonly: bool) -> Result<()> { ... }
    pub fn set_memory_attributes(&self, gpa: u64, size: u64,
                                 attrs: u64) -> Result<()> { ... }
}
```

```rust
// openvmm/openvmm_defs/src/config.rs
pub enum IsolationType { Vbs, Snp }
impl From<IsolationType> for virt::IsolationType {
    fn from(value: IsolationType) -> Self {
        match value {
            IsolationType::Vbs => Self::Vbs,
            IsolationType::Snp => Self::Snp,
        }
    }
}

// openvmm/openvmm_entry/src/cli_args.rs
pub enum IsolationCli { Vbs, Snp }

// openvmm/openvmm_entry/src/lib.rs
match isolation {
    cli_args::IsolationCli::Vbs => Some(...IsolationType::Vbs),
    cli_args::IsolationCli::Snp => Some(...IsolationType::Snp),
}
```

```rust
// vmm_core/virt_kvm/src/arch/x86_64/mod.rs
fn new_partition<'a>(&mut self, config: ProtoPartitionConfig<'a>) -> ...
{
    // Stop returning IsolationNotSupported for SNP.
    let snp = config.isolation == IsolationType::Snp;
    let vm = if snp { self.kvm.new_snp_vm()? } else { self.kvm.new_vm()? };
    // ... and call sev_init+launch_start during finalization,
    //     launch_update for each loaded region,
    //     launch_finish before first KVM_RUN.
}
```

### Memory backend changes (the largest piece)

`vm/vmcore/guestmem/` would need a new "encrypted" memory backend that:
- Allocates a `guest_memfd` per region instead of (or alongside) anon mmap
- Tracks per-page `private/shared` state
- Plumbs the `guest_memfd` and offsets through to `set_memory_region2`
- Optionally calls `set_memory_attributes` when the guest issues
  page-state-change requests

This is the biggest blocker. The current `guestmem` model assumes the
VMM can directly read/write all guest memory (which is impossible for
private SNP pages without `KVM_DEBUG_DECRYPT/ENCRYPT`).

---

## Phase 5 completion: Nested SNP via OpenVMM (2026-05-13)

> **All five blockers above (B1–B5) have since been addressed**, not by
> implementing the "land IsolationType::Snp end-to-end in mainline
> openvmm" plan we sketched in the original recommendation, but by
> picking up Chris Oo's **`chris-oo/openvmm-snp`** branch and pairing
> it with a patched Hyper-V-aware host kernel. The result: an OHCL-style
> Linux guest boots inside OpenVMM at VMPL0 with `Memory Encryption
> Features active: AMD SEV SEV-ES SEV-SNP` printed by the L2 kernel.

### What unblocked Phase 5

| Original blocker | What actually closed it |
|------------------|--------------------------|
| B1 — CLI gate (`vtl2 configured but not loading from igvm`) | `openvmm-snp` accepts `--isolation snp` on the direct-kernel path; no IGVM required. |
| B2 — Missing `KVM_SEV_INIT2` / `LAUNCH_*` ioctls | All four launch-state ioctls are wired in `vm/kvm` on the `chris-oo` branch. |
| B3 — No `guest_memfd` integration | `set_user_memory_region2` is plumbed and the entire RAM region is backed by `guest_memfd`. |
| B4 — Missing CPUID 0x8000001f / SNP_GUEST_REQ wiring | OHCL guest sees the SNP CPUID table; `/dev/sev-guest` opens; `snp-report` reads a real PSP-signed attestation report. |
| B5 — `guestmem` direct-read-write assumption | Memory is treated as opaque for SNP regions; pre-launch population happens before `LAUNCH_FINISH`, post-launch debug is gated. |

### Host kernel work (the prerequisite)

OpenVMM-with-SNP requires a host kernel that knows it is running as an
L1 SNP host *under Hyper-V*, not on bare metal. We ported jepio's
nested-SNP series (originally for a custom in-house tree) onto stock
**Ubuntu 25.10 source `linux-6.17.0-23.23`**. The minimal stack is
**17 commits** and lives at:

- `haitaohuang/linux:nested-snp-port-6.17` (HEAD `2a624399c`)

Key pieces of the patch stack:

- `x86/hyperv`: allocate the RMP table at boot, advertise the
  `NestedVirtSnpMsr` CPUID bit, maintain a shadow RMP and route writes
  through `virt_rmpupdate` / `virt_psmash` MSRs.
- `x86/amd`: configure SYSCFG.SNP_EN per-CPU via a cpuhp callback (the
  prerequisite for L0 to even intercept the virt MSRs — see the
  in-tree `__snp_enable_hv` device_initcall added in `2a624399c`).
- `crypto/ccp`: Hyper-V exposes the PSP through ACPI ASPT, not PCI;
  the platform-PSP path needed a vdata table, master-device promotion,
  and quirks to skip firmware-version / SEV-init / TMR steps that
  Hyper-V already did out-of-band.

The kernel boots as `6.17.13-nested-snp-port-nested-snp-port` and prints
`SEV-SNP enabled (ASIDs 1 - 64)` in dmesg. See
[`REPORT_nested_snp_openvmm.md`][repnest] for the full post-mortem
including all 17 patches, iteration history, diagnostics, and dropped
candidates (`b868e81ee`, `1b0402d1d` — preserved on archive refs).

### OpenVMM side

- Branch: `haitaohuang/openvmm:openvmm_nested_snp` (forks
  `chris-oo/openvmm-snp`, validated at HEADs `eced60b7` and `10d28c05`).
- Build: `cargo build --release --bin openvmm`.
- The May 12 sync adds three SNP-functional commits on top of the
  initial victory point: a stability fix (`7a2a01d7` — discard page
  visibility mappings on transitions), PCIe virtio support
  (`47900c3b`), and a comment-only update.

### Verifying the L2 guest

```bash
sudo timeout 60 /datadrive/nested_openvmm/snp-artifacts/run-snp-openvmm.sh \
    > /tmp/openvmm-run.log 2>&1

# Expect in /tmp/openvmm-run.log:
#   Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP
#   SEV: SNP running at VMPL0.
#   smp: Bringing up secondary CPUs ...                  # MP with -p 2
#   virtio_blk virtio0: 1/0/0 default/read/poll queues   # PCIe virtio-blk
```

60 s is the minimum timeout: SNP `LAUNCH_UPDATE` on the kernel + initrd
alone takes ~45 s on this hardware before the first vCPU starts.

### vsock differences vs the Phase 3 QEMU recipe

The same OHCL kernel and the same enclave-init initramfs run under
both QEMU (Phase 3) and OpenVMM (Phase 5), with one transport
difference for the demo's ecall/ocall plane:

| | QEMU (Phase 3) | OpenVMM (Phase 5) |
|---|---|---|
| Vsock device | `vhost-vsock-pci` (legacy PCI) | `virtio-vsock-pci` over PCIe root port |
| L2 driver | `vhost_vsock` module | virtio-vsock |
| Guest CID | `42` (set by user) | always `0x3` |
| Host plumbing | `/dev/vhost-vsock`, kernel-side | userspace "hybrid vsock" relay over AF_UNIX |

Legacy PCI virtio under SNP fails OpenVMM's `guest_memfd` check
(`KVM SNP guest_memfd does not support disks`) — the PCIe transport
is mandatory. A 2-line OpenVMM patch adds the `--virtio-vsock-pcie-port`
flag (mirror of `--virtio-rng-pcie-port`); the rebuilt binary lives
at `/datadrive/nested_openvmm/snp-artifacts/openvmm`.

### Where the reproducer lives

- **In-tree:** [`docs/hackathon/REPRODUCE_PHASE5.md`](hackathon/REPRODUCE_PHASE5.md)
- **Companion repo:** `haitaohuang/vm_enclave/REPORT_nested_snp_openvmm.md`
  and the runnable `demo-openvmm.sh` in the same tree.

---

## Phase 6 (in progress): SMT Protection on cc_v6

After Phase 5 closed, the next workstream targets **SMT-side-channel
protection** for SEV-SNP guests via Kim Phillips's KVM RFC
([lkml.org/lkml/2025/8/7/867](https://lkml.org/lkml/2025/8/7/867)).
The RFC adds a per-vCPU "SMT-protected" mode that:

- Tags the sibling thread as "guest-private" while the SNP vCPU runs.
- Returns the sibling to a known IDLE state on every VMEXIT.
- Requires VMM cooperation: per-vCPU `PR_SCHED_CORE_CREATE` and
  pinned `pthread_setaffinity_np` to a core-sibling pair.

### Status on our current cc_v5 (Milan / Zen 3) host

- CPUID `0x8000001f.EAX` bit 25 (SmtProtection) is **clear**. The
  hardware doesn't expose the feature — it requires Zen 4+ (Genoa).
- L0 Azure Hyper-V doesn't propagate this CPUID bit either; adding
  it is a separate L0 ask.

We will not enable SMT Protection on cc_v5. We are however staging
everything that can be staged ahead of cc_v6 (Genoa) hardware:

- **Kernel**: Kim Phillips's 24-line RFC patch is applied verbatim
  on branch `haitaohuang/linux:smt-protection-dryrun` (HEAD
  `de6a7b07f`). Builds clean against the 6.17 base.
- **OpenVMM userspace**: a single env-var-gated prototype lives on
  `haitaohuang/openvmm:feature/smt-protection` (HEAD `03cfcb6b`).
  Setting `OPENVMM_SMT_PROTECTION=1` and `OPENVMM_VP_AFFINITY=<csv>`
  pins each vCPU to one logical CPU and joins the core-scheduling
  cookie. `cargo check / clippy / doc / fmt` all clean.
- **Probes**: a four-tier validation harness (CPUID probe → KVM ABI
  probe → in-guest `/dev/sev-guest` attestation → perf-stat sibling
  IDLE measurement) is staged at
  `haitaohuang/vm_enclave/smt-protection-hackathon/` (commit `0de44ad`).

### Open dependencies

1. cc_v6 (Genoa) hardware access — currently the blocker.
2. L0 exposure of CPUID `0x8000001f.EAX[25]` and the `KVM_CAP_…`
   feature flag.
3. Upstream merge of the RFC. The RFC author has noted in-guest CPU
   stalls after several minutes; scheduler thread-info coordination
   is not yet solved upstream.

See [`haitaohuang/vm_enclave/smt-protection-hackathon/README.md`][smtdir]
for the full hackathon-handoff package (entry-gate test, probe
ordering, expected outputs, and a hackathon report skeleton).

[smtdir]: https://github.com/haitaohuang/vm_enclave/tree/main/smt-protection-hackathon

---

## Recommendation for next steps

> **Historical, pre-Phase 5 plan** — the items below were the path
> we sketched at the close of the hackathon. The actual route taken
> was different: we picked up Chris Oo's `openvmm-snp` branch (which
> already does items 1–3 in concept) rather than reimplementing in
> mainline OpenVMM. The list is preserved as a record of how we
> framed the problem at the time.

1. ~~**Short term (achievable)**: Land the IsolationType::Snp + CLI plumbing
   patch and the new ioctls in `vm/kvm` (no semantic change). This is a
   compile-only change that makes the path discoverable.~~ — superseded
   by `chris-oo/openvmm-snp`.
2. ~~**Medium term**: Implement an "SNP-naive" memory backend that uses
   `guest_memfd` for the entire RAM region, populated via direct kernel
   boot before launch_finish. No page-state-change handling. Single VCPU.~~
   — done on `openvmm-snp` (also handles MP and PCIe virtio).
3. ~~**Long term**: Full PSC handling, multi-VCPU, IGVM SNP loader.~~
   — MP + PCIe virtio working; IGVM-loader and live-migration still
   open on the OpenVMM side.

### Forward-looking recommendations (current)

1. **Upstream the host-kernel patch we added on top of jepio's series**
   (`2a624399c` — `snp_rmptable_init_hv` device_initcall + per-CPU
   `SYSCFG.SNP_EN` via cpuhp). It is narrowly gated on
   `snp_soft_rmptable()` so it is a no-op on non-Hyper-V SNP hosts.
2. **Exercise the migration/teardown path** for the soft RMP — when
   the guest exits, walk the shadow and reset entries.
3. **Drive Phase 6 (SMT Protection) on cc_v6** as soon as hardware is
   available; the kernel patch, OpenVMM userspace prototype, and
   probe scripts are already staged (see the `smt-protection-hackathon/`
   folder in `haitaohuang/vm_enclave`).

---

## Hackathon scaffolding patch (delivered)

The following changes have been **applied to the cloned repos** and the
codebase rebuilds cleanly:

### `openvmm/openvmm_defs/src/config.rs`
Added `Snp` variant to `IsolationType` and the corresponding mapping to
`virt::IsolationType::Snp`.

### `openvmm/openvmm_entry/src/cli_args.rs`
Added `Snp` variant to `IsolationCli` so users can pass `--isolation snp`.

### `openvmm/openvmm_entry/src/lib.rs`
Map `IsolationCli::Snp` → `IsolationType::Snp`.

### `vm/kvm/src/lib.rs`
Added:
- New module `kvm::sev` with all the constants and structs needed for
  SEV-SNP launch (`KVM_X86_SNP_VM`, `KVM_SEV_INIT2`, `KVM_SEV_SNP_LAUNCH_*`,
  `kvm_sev_cmd`, `kvm_sev_init`, `kvm_sev_snp_launch_{start,update,finish}`,
  `kvm_create_guest_memfd`, `kvm_memory_attributes`,
  `kvm_userspace_memory_region2`).
- Four new ioctls in `mod ioctl` (`kvm_memory_encrypt_op = KVMIO 0xba`,
  `kvm_set_user_memory_region2 = 0x49`,
  `kvm_set_memory_attributes = 0xd2`,
  `kvm_create_guest_memfd = 0xd4`).
- New `Kvm::new_vm_of_type(vm_type)` so the SNP path can pass
  `KVM_X86_SNP_VM = 4`.
- New `Partition::sev_init2()`, `snp_launch_start()`, `snp_launch_update()`,
  `snp_launch_finish()`, `create_guest_memfd()`,
  `set_user_memory_region2()`, `set_memory_attributes()`,
  `memory_encrypt_op()` helpers.

### Verified
```
$ cargo build -p openvmm
    Finished `dev` profile [unoptimized + debuginfo] target(s)
$ ./target/debug/openvmm --isolation snp ... 2>&1 | grep -i isolation
Possible values:
  - snp: AMD SEV-SNP isolation (KVM backend, hackathon scaffolding only)
```

The CLI parse succeeds. The launch fails at the next gate because the
existing `--isolation` path also requires `--vtl2 --hv` and an IGVM file:

```
fatal error: failed to launch vm worker
Caused by:
    1: vtl2 configured but not loading from igvm
```

That gate (`openvmm/openvmm_entry/src/lib.rs`) is the second blocker:
the isolation path is hard-wired to the OpenHCL-paravisor architecture
(IGVM file with VTL2). To support a "naive" SNP mini-VM (no paravisor,
direct kernel boot), this constraint would need to be relaxed for SNP
specifically, plus the changes in #B5 above (guest_memfd memory backend).

### What still needs to happen (concrete, in order)

1. Make `--isolation snp` not require `--vtl2`/IGVM. Branch the CLI so
   SNP can be combined with `--kernel`/`--initrd` direct boot.
2. In `vmm_core/virt_kvm/src/arch/x86_64/mod.rs:138-140`, replace the
   blanket `IsolationNotSupported` rejection with a match on the
   isolation type. For `Snp`, call `self.kvm.new_vm_of_type(KVM_X86_SNP_VM)`
   and store the `is_snp` flag on the partition.
3. Add an "encrypted RAM" path to the partition's memory mapper. Each
   `map_range()` call should:
   a. `create_guest_memfd(size, 0)` and keep the fd alive in `KvmPartitionInner`.
   b. `mmap(size, MAP_SHARED, fd, 0)` into the host so we can populate
      it (the same range stays available for reads — KVM's
      guest_memfd supports SHARED mappings of NOT-YET-PRIVATE pages).
   c. `set_user_memory_region2` with `KVM_MEM_GUEST_MEMFD`.
4. Add an SNP launch sequencer that runs after the kernel/initrd are
   loaded but before the first `KVM_RUN`:
   a. Open `/dev/sev`, `KVM_SEV_INIT2`.
   b. `KVM_SEV_SNP_LAUNCH_START` with `policy = 0x30000` (default).
   c. For each populated page region: `KVM_SET_MEMORY_ATTRIBUTES`
      (PRIVATE) + `KVM_SEV_SNP_LAUNCH_UPDATE` (NORMAL or specific type).
   d. `KVM_SEV_SNP_LAUNCH_FINISH`.
5. (Optional, for boot to work without OVMF) Build SECRETS and CPUID
   pages and lay them out where the SEV-SNP kernel expects.

Items 3-4 are roughly 300-500 LOC; item 5 is another ~200 LOC and may
need OVMF after all. Items 1-2 are <50 LOC with the scaffolding above.

---

## Files modified during this hackathon

### openvmm scaffolding (kvm branch, /datadrive/nested_openvmm/openvmm)
| File | Purpose |
|------|---------|
| `openvmm/openvmm_defs/src/config.rs` | Added `IsolationType::Snp` variant + mapping |
| `openvmm/openvmm_entry/src/cli_args.rs` | Added `IsolationCli::Snp` |
| `openvmm/openvmm_entry/src/lib.rs` | Map `IsolationCli::Snp` → `IsolationType::Snp` |
| `vm/kvm/src/lib.rs` | New `sev` module + 4 ioctls + 8 partition helpers |

### OHCL kernel (kvm-nested branch, /datadrive/nested_openvmm/OHCL-Linux-Kernel)
| File | Lines | Purpose |
|------|-------|---------|
| `include/asm-generic/hyperv-tlfs.h` | 761-767 | u128 → struct of two u64s |
| `kernel/smp.c` | 987-1006, 1031-1033 | cpu_boot_mask array assignment fix |
| `arch/x86/hyperv/hv_init.c` | 363-374 | get_vtl() stub when VTL_MODE off |
| `arch/x86/events/amd/core.c` | 1-12, 1516-1532 | Skip PMU init under SEV-SNP |

### Initramfs
| File | Purpose |
|------|---------|
| `/datadrive/nested_openvmm/initramfs/init` | Hello-world init script |
| `/datadrive/nested_openvmm/initramfs.cpio.gz` | 1 MB initramfs with busybox |

### Build artifacts
| File | Purpose |
|------|---------|
| `/datadrive/nested_openvmm/OHCL-Linux-Kernel/arch/x86/boot/bzImage` | For QEMU |
| `/datadrive/nested_openvmm/OHCL-Linux-Kernel/vmlinux` | For openvmm direct boot |
| `/datadrive/nested_openvmm/openvmm/target/debug/openvmm` | Built openvmm |
