# KVM Planes - COCONUT-SVSM Build & Run Notes

## Overview

KVM Planes is a feature that enables privilege separation in virtual machines,
supporting AMD SEV-SNP VMPLs and Intel TD Partitioning. COCONUT-SVSM uses
planes to run a secure Virtual Machine Service Module at a higher privilege
level (plane 0/1) while the guest OS runs on plane 2.

KVM Planes solves the key challenge described by the OpenHCL project: the host
needs to (1) run a paravisor that traps/emulates privileged guest instructions,
and (2) target interrupts directly into the guest OS without relaying through
the paravisor. Previously, only Hyper-V VTLs provided these primitives.

## Kernel Build (v6.17 with Planes Patches)

### Source & Branch

- Repository: `https://github.com/coconut-svsm/linux`
- Branch: `svsm-planes-v6.17` (60 patches on top of v6.17)
- Author: Paolo Bonzini (Red Hat) + Joerg Roedel (AMD)
- Local checkout: `/home/haitao/linux` (branch: `planes`)

### Key Kernel Config Options

| Config | Value | Purpose |
|--------|-------|---------|
| `CONFIG_KVM` | y | KVM hypervisor |
| `CONFIG_KVM_AMD` | y | AMD KVM support |
| `CONFIG_KVM_AMD_SEV` | y | SEV/SEV-ES/SEV-SNP support |
| `CONFIG_KVM_SW_PROTECTED_VM` | y | Software-protected VM support |
| `CONFIG_AMD_MEM_ENCRYPT` | y | AMD SME/SEV memory encryption |
| `CONFIG_SEV_GUEST` | y | SEV-SNP guest driver |
| `CONFIG_CRYPTO_DEV_SP_PSP` | y | AMD PSP (Platform Security Processor) |
| `CONFIG_AMD_IOMMU` | y | AMD IOMMU for device passthrough |
| `KVM_MAX_VCPU_PLANES` | 16 | Defined in `arch/x86/include/uapi/asm/kvm.h` (not a Kconfig) |
| `CONFIG_SECURITY_LOCKDOWN_LSM` | not set | Allows kexec of unsigned kernels |
| `CONFIG_LOCALVERSION` | `-svsm-planes-snp` | Kernel version suffix |

### Build Command (Ubuntu .deb packages)

```bash
cd /home/haitao/linux
make x86_64_defconfig
scripts/config --enable KVM --enable KVM_AMD --enable KVM_AMD_SEV \
  --enable KVM_SW_PROTECTED_VM --enable AMD_MEM_ENCRYPT \
  --enable SEV_GUEST --enable CRYPTO_DEV_SP_PSP \
  --enable AMD_IOMMU --enable VIRT_DRIVERS --enable EXPERT \
  --set-str LOCALVERSION "-svsm-planes-snp" \
  --enable DEBUG_INFO_NONE --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
make olddefconfig
make -j$(nproc) bindeb-pkg LOCALVERSION=""
```

### Output Packages

```
/home/haitao/linux-image-6.17.0-svsm-planes-snp-00060-g16e7d0b9c65c_6.17.0-00060-g16e7d0b9c65c-2_amd64.deb  (15M)
/home/haitao/linux-headers-6.17.0-svsm-planes-snp-00060-g16e7d0b9c65c_6.17.0-00060-g16e7d0b9c65c-2_amd64.deb (9.2M)
/home/haitao/linux-libc-dev_6.17.0-00060-g16e7d0b9c65c-2_amd64.deb (1.5M)
```

### Installation (Ubuntu, no Secure Boot)

```bash
sudo dpkg -i linux-image-6.17.0-svsm-planes-snp-*.deb
sudo update-grub
sudo reboot
```

**Note:** Azure VMs with Trusted Launch / Secure Boot enabled will reject
unsigned custom kernels. Use a VM with Security type = "Standard" for testing.

## Built Components

| Component | Location | Notes |
|-----------|----------|-------|
| Linux Kernel | `/home/haitao/linux-image-*.deb` | v6.17.0 + 60 planes patches |
| QEMU | `/home/haitao/qemu/build/qemu-system-x86_64` | v10.1.0, KVM + IGVM enabled |
| COCONUT-SVSM IGVM | `/home/haitao/svsm/bin/coconut-qemu.igvm` | 4.7MB, includes OVMF firmware |
| OVMF (EDK2) | `/home/haitao/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd` | svsm branch, TPM2 enabled |
| igvm library | System-installed (`/usr/lib/x86_64-linux-gnu/`) | v0.4.0 from microsoft/igvm |

## QEMU Build

- Source: `https://github.com/coconut-svsm/qemu` (branch with planes support)
- Configure: `--target-list=x86_64-softmmu --enable-kvm --enable-igvm`
- Required `libigvm` (C bindings built with `cargo-c` from https://github.com/microsoft/igvm)

## COCONUT-SVSM Build

```bash
cd /home/haitao/svsm
git submodule update --init
FW_FILE=/home/haitao/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd cargo xbuild configs/qemu-target.json
```

- No special branch needed for planes — standard `main` works
- `FW_FILE` bundles OVMF into the IGVM (required for full guest boot)
- Without `FW_FILE`, IGVM contains only the SVSM (useful for testing SVSM alone)

## EDK2 (OVMF) Build

```bash
cd /home/haitao/edk2   # branch: svsm
git submodule init && git submodule update
make -j$(nproc) -C BaseTools/
source ./edksetup.sh
build -p OvmfPkg/OvmfPkgX64.dsc -a X64 -b DEBUG -t GCC5 \
  -D DEBUG_ON_SERIAL_PORT -D DEBUG_VERBOSE -D TPM2_ENABLE \
  --pcd PcdUninstallMemAttrProtocol=TRUE -n $(nproc)
```

## Key QEMU Machine Properties for KVM Planes

### `kernel-irqchip=split`

The interrupt controller is split between kernel (local APIC) and userspace
(I/O APIC in QEMU). Required because COCONUT-SVSM's plane support needs QEMU
to control interrupt routing rather than letting KVM handle everything in-kernel.

### `device-plane=2`

Tells QEMU which plane owns devices and should receive IRQs. COCONUT-SVSM runs
the guest OS on plane 2, so device interrupts must be delivered there (not to
the SVSM on plane 0/1).

## Launch Command

```bash
sudo /home/haitao/qemu/build/qemu-system-x86_64 \
  -enable-kvm \
  -cpu EPYC-v4 \
  -machine q35,confidential-guest-support=sev0,memory-backend=ram1,igvm-cfg=igvm0,kernel-irqchip=split,device-plane=2 \
  -object memory-backend-memfd,id=ram1,size=8G,share=true,prealloc=false,reserve=false \
  -object sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1 \
  -object igvm-cfg,id=igvm0,file=/home/haitao/svsm/bin/coconut-qemu.igvm \
  -smp 8 \
  -no-reboot \
  -vga none \
  -netdev user,id=vmnic -device e1000,netdev=vmnic,romfile= \
  -drive file=/path/to/guest/image.qcow2,if=none,id=disk0,format=qcow2,snapshot=off \
  -device virtio-scsi-pci,id=scsi0,disable-legacy=on,iommu_platform=on \
  -device scsi-hd,drive=disk0,bootindex=0 \
  -serial stdio \
  -serial pty
```

## Hardware Requirements

- AMD EPYC Gen 3+ with SEV-SNP enabled in BIOS
- Host kernel with SEV-SNP + SVSM patches (`coconut-svsm/linux`, branch `svsm`)
- Must run QEMU as root (`/dev/sev` access)

## Guest Requirements

- Linux v6.16+ kernel (has SVSM guest support upstream)
- `CONFIG_TCG_SVSM` for vTPM support

## Architecture Summary

```
┌─────────────────────────────────────────┐
│              QEMU + KVM                 │
│  (kernel-irqchip=split, device-plane=2) │
├─────────────────────────────────────────┤
│  Plane 0/1: COCONUT-SVSM               │
│  - Secure services (vTPM, attestation)  │
│  - VMPL0 privilege                      │
├─────────────────────────────────────────┤
│  Plane 2: Guest OS                      │
│  - Receives device IRQs                 │
│  - Runs OVMF → Linux                   │
│  - Lower privilege VMPL                 │
└─────────────────────────────────────────┘
```

## KVM Planes Patch Series (60 patches, v6.17 base)

### Patch Categories

| Category | Key Commits | Description |
|----------|-------------|-------------|
| Core planes API | `a804c94e3a77`, `9bc6198b53a5`, `cafe5204324e` | KVM_CREATE_PLANE, KVM_CREATE_VCPU_PLANE ioctls, plane fd |
| Interrupt delivery | `e29f28dcec0a`, `f303752a54d4`, `06803f14dba1` | Per-plane LAPIC maps, KVM_SIGNAL_MSI on plane fd |
| IRQ routing | `23a293ccaf99`, `be2fb9437e91` | `kvm_irq_routing_entry.plane` field, validate plane exists |
| Plane switching | `0920e4ff72cf`, `866e2183adae` | KVM_EXIT_PLANE_EVENT, interrupt priorities, req_exit_planes |
| SEV-SNP / VMPL | `745abddd0dda`, `1042e2570e29`, `8aec2ec0cb65` | Restricted injection, #HV doorbell, IPI NAE |
| SEV-SNP AP creation | `18593f345adb`, `056097c5edd3`, `0cf4d2941abe` | VMPL-level VMSA, AP APIC IDs, multi-VMPL vCPU create |
| FPU/register state | `578d2fef0fe7`, `00a92dab0e26` | Shared/non-shared FPU across planes |
| Selftests | `0f8826afb75c`, `26100f8ca52e`, `0ff105d5dd3d` | plane_test.c, x86/plane_test.c |

### Full Commit List

```
16e7d0b9c65c kvm: x86: Request TLB flushes always via plane 0
294107b3b199 kvm: x86: Route IOAPIC scan requests to correct plane
3b9af14e6d65 kvm: Introduce plane-aware kvm_make_vcpus_request_mask*() functions
9976c5029d17 kvm: x86: Add plane to trace_kvm_accept_apic_irq()
9aaf53cf96e9 kvm: x86: Add plane to trace_kvm_msi_set_irq()
2f5a2874b48d kvm: amd: Make sure to wake plane0 vcpu when updating non-plane0 state
453450377b98 kvm/amd: Treat SEV_SNP_RUN_VMPL as INIT-SIPI
067c3d223c85 kvm: x86: Store CPUID information in plane0
f0565ef00829 KVM: SVM: Implement number of planes x86 operation
6db1b591f742 KVM: SVM: Advertise full multi-VMPL support to the SNP guest
3e03a42c1da1 kvm/x86: Force switch to plane 0 if it has events
be3fb2a01f02 kvm/amd: Allow planes to have different SEV_FEATURES
0cad62a064d8 KVM: SVM: Support measurement of a vCPU VMSA using IGVM
056097c5edd3 KVM: SVM: Invoke a specified VMPL level VMSA for the vCPU
18593f345adb KVM: SEV: Allow for VMPL level specification in AP create
0cf4d2941abe KVM: SVM: Implement GET_AP_APIC_IDS NAE event
be2fb9437e91 kvm/irq: Do not route IRQs to non-existent planes
ee0cefc3177c kvm/x86: Always block on plane 0
866e2183adae kvm: Introduce kvm_request_plane_switch()
23a293ccaf99 kvm/x86: Make IRQ routing entries aware of planes
cac77db6082a kvm: Introduce kvm_get_plane() helper
d2019f23343c kvm: Always use rcuwait object from plane0 vcpu
f303752a54d4 kvm/x86/irq: Deliver IRQs to correct plane
e07c01e1ec7c kvm/amd: Track SEV_FEATURES per VCPU
745abddd0dda KVM: SVM: Enable restricted injection for an SEV-SNP guest
f50969f2158b KVM: SVM: Add support for the SEV-SNP #HV IPI NAE event
31748c320849 KVM: SVM: Inject MCEs when restricted injection is active
9062dfa4f19d KVM: SVM: Inject NMIs when restricted injection is active
1042e2570e29 KVM: SVM: Inject #HV when restricted injection is active
8aec2ec0cb65 KVM: SVM: Add support for the SEV-SNP #HV doorbell page NAE event
9135b6e6b613 x86/sev: Define the #HV doorbell page structure
0ff105d5dd3d selftests: kvm: add x86-specific plane test
26100f8ca52e selftests: kvm: add plane infrastructure
0f8826afb75c selftests: kvm: introduce basic test for VM planes
7d8642db4986 KVM: x86: enable up to 16 planes
0920e4ff72cf KVM: x86: handle interrupt priorities for planes
b566fc1425d8 KVM: x86: initialize CPUID for non-default planes
a792638f4b5d KVM: x86: extract kvm_post_set_cpuid
00a92dab0e26 KVM: x86: implement initial plane support
578d2fef0fe7 KVM: x86: add infrastructure to share FPU across planes
e29f28dcec0a KVM: x86: add planes support for interrupt delivery
6c8178f4031a KVM: x86: move APIC map to kvm_arch_plane
c25b0e2f2c46 KVM: x86: track APICv inhibits per plane
46751e07c31b KVM: x86: block creating irqchip if planes are active
3dbd32f3ae36 KVM: x86: split "if" in __kvm_set_or_clear_apicv_inhibit
16980bcc6791 KVM: x86: pass vcpu to kvm_pv_send_ipi()
8c8504fc4053 KVM: pass plane to kvm_arch_vcpu_create
3d8e24bdc33a KVM: implement vCPU creation for extra planes
9486e0bc5fd0 KVM: share dirty ring for same vCPU id on different planes
211dadb23c41 KVM: anticipate allocation of dirty ring
62d6a63b4bd6 KVM: share statistics for same vCPU id on different planes
cafe5204324e KVM: implement plane file descriptors ioctl and creation
a90e35b11121 KVM: move vcpu_array to struct kvm_plane
8ef5c089d77b KVM: do not use online_vcpus to test vCPU validity
98b4eeeb98b8 KVM: move mem_attr_array to kvm_plane
06803f14dba1 KVM: add plane support to KVM_SIGNAL_MSI
bd513d1773ac KVM: introduce struct kvm_arch_plane
9bc6198b53a5 KVM: add plane info to structs
a710de512dcb KVM: API definitions for plane userspace exit
a804c94e3a77 Documentation: kvm: introduce "VM plane" concept
```

## How Interrupt Injection to Different Planes Works

### Problem Statement

A paravisor (SVSM/OpenHCL) needs to run at a higher privilege level and trap
guest operations, while the host must be able to inject device interrupts
**directly** into the guest OS plane without relaying through the paravisor.

### Solution: 5 Interrupt Delivery Mechanisms

#### 1. KVM_SIGNAL_MSI on Plane File Descriptor

Each plane has its own fd (from `KVM_CREATE_PLANE`). Userspace sends MSIs to
a specific plane:

```c
// QEMU targets plane 2 (guest OS):
ioctl(plane2_fd, KVM_SIGNAL_MSI, &msi);  // → plane 2 LAPIC
ioctl(vm_fd, KVM_SIGNAL_MSI, &msi);      // → plane 0 (default)
```

Implementation: `cafe5204324e` — `__kvm_plane_ioctl()` passes plane to
`kvm_send_userspace_msi(plane, &msi)`.

#### 2. IRQ Routing Table Per-Plane Targeting

The `kvm_irq_routing_entry.pad` field was repurposed as `plane`:

```c
struct kvm_irq_routing_entry {
    __u32 gsi;
    __u32 type;
    __u32 flags;
    __u32 plane;   // formerly 'pad' — selects target plane
    union { ... };
};
```

QEMU's `device-plane=2` configures all device IRQ routes with `plane=2`.
Implementation: `23a293ccaf99`.

#### 3. Per-Plane APIC Maps and Delivery

Each plane has its own APIC map. IRQ delivery iterates only vCPUs in the
target plane:

```c
struct kvm_plane *plane = kvm_get_plane(kvm, irq->plane);
kvm_for_each_plane_vcpu(i, vcpu, plane) { /* deliver */ }
```

IPIs from within a plane stay within that plane (`irq.plane = apic->vcpu->plane`).
Implementation: `e29f28dcec0a`, `f303752a54d4`.

#### 4. Cross-Plane Interrupt Notification (Plane Switch)

When an interrupt arrives for a plane that isn't currently executing:

1. KVM sets `irr_pending_planes |= BIT(target_plane)` atomically
2. Checks userspace-provided `req_exit_planes` bitmap
3. If target plane is in `req_exit_planes`, forces `KVM_EXIT_PLANE_EVENT`:

```c
vcpu->run->exit_reason = KVM_EXIT_PLANE_EVENT;
vcpu->run->plane_event.cause = KVM_PLANE_EVENT_INTERRUPT;  // or CREATE_CPU, RUN_SNP_VMPL
vcpu->run->plane_event.pending_event_planes = irr_pending_planes;
vcpu->run->plane_event.target = <bitmap of planes needing attention>;
```

Userspace then switches execution: `vcpu->run->plane = target_plane; ioctl(KVM_RUN)`.
Implementation: `0920e4ff72cf`.

#### 5. SEV-SNP Restricted Injection (#HV Doorbell)

For SNP guests with restricted injection, KVM cannot inject arbitrary interrupts.
Instead:

1. KVM writes to the **#HV doorbell page** (shared page per-vCPU)
2. KVM injects only `#HV` exception (vector 28)
3. SVSM (at VMPL0) handles `#HV`, reads doorbell, delivers actual interrupt to guest

```c
// prepare_hv_injection():
svm->vmcb->control.event_inj = HV_VECTOR | SVM_EVTINJ_TYPE_EXEPT | SVM_EVTINJ_VALID;
hvdb->events.no_further_signal = 1;
```

Implementation: `1042e2570e29`, `8aec2ec0cb65`.

### End-to-End Flow (COCONUT-SVSM)

```
QEMU                         KVM (host kernel)           Guest VM
─────                        ────────────────            ────────
ioctl(plane2_fd,             
  KVM_SIGNAL_MSI) ────────→  Set irq->plane = 2
                             Look up plane 2 APIC map
                             Deliver to plane 2 LAPIC
                             
                             Set irr_pending_planes |= BIT(2)
                             
                             If currently running plane 0:
                             Check req_exit_planes & BIT(2)
                             KVM_EXIT_PLANE_EVENT ──────→ QEMU
                             
QEMU: run->plane = 2        
ioctl(KVM_RUN) ───────────→  Enter vCPU on plane 2      
                                                         Guest OS handles IRQ
                             
                             (With SNP restricted injection):
                             Write #HV doorbell page ───→ #HV exception
                                                         SVSM reads doorbell
                                                         SVSM delivers to guest
```

## KVM API Extensions

### New ioctls

| ioctl | fd type | Description |
|-------|---------|-------------|
| `KVM_CREATE_PLANE` | vm fd | Creates a new plane, returns plane fd |
| `KVM_CREATE_VCPU_PLANE` | plane fd | Creates vCPU for non-default plane |
| `KVM_SIGNAL_MSI` | plane fd | Sends MSI to specific plane |
| `KVM_SET_MEMORY_ATTRIBUTES` | plane fd | Per-plane memory permissions |

### New Capabilities

| Capability | Value | Description |
|-----------|-------|-------------|
| `KVM_CAP_PLANES` | 16 (on x86) | Max number of planes supported |
| `KVM_CAP_PLANES_FPU` | — | Enable shared FPU state across planes |

### kvm_run Extensions

| Field | Description |
|-------|-------------|
| `run->plane` | Which plane to execute (set by userspace before KVM_RUN) |
| `run->req_exit_planes` | Bitmap of planes that should cause exit on interrupt |
| `run->plane_event.cause` | `INTERRUPT`, `CREATE_CPU`, or `RUN_SNP_VMPL` |
| `run->plane_event.target` | Bitmap of planes that triggered the event |
| `run->plane_event.pending_event_planes` | All planes with pending IRR |

## KVM Selftests

### Architecture-neutral test (`tools/testing/selftests/kvm/plane_test.c`)

Tests: error conditions, create plane, plane switch.

### x86-specific test (`tools/testing/selftests/kvm/x86/plane_test.c`)

Tests:
1. **get/set regs for planes** — Register state is independent per plane
2. **get/set FPU not shared** — Default: FPU state separate per plane
3. **get/set FPU shared** — With `KVM_CAP_PLANES_FPU`: FPU shared, PKRU separate
4. **signal MSI for planes** — MSI delivered to correct plane's LAPIC
5. **KVM_EXIT_PLANE_EVENT** — Verifies exit on cross-plane interrupt

### Build and Run

```bash
cd /home/haitao/linux
make -C tools/testing/selftests/kvm -j$(nproc)
./tools/testing/selftests/kvm/plane_test
./tools/testing/selftests/kvm/x86/plane_test
```

Expected output:
```
TAP version 13
1..5
# KVM_CAP_PLANES: 16
ok 1 get/set regs for planes
ok 2 get/set FPU not shared across planes
ok 3 get/set FPU shared across planes
ok 4 get/set PKRU with shared FPU
ok 5 signal MSI for planes
# Totals: pass:5 fail:0 xfail:0 xpass:0 skip:0 error:0
```

**Note:** Selftests work WITHOUT SEV-SNP hardware (planes are a software
abstraction). They validate the API on any x86 machine with KVM.

## Relationship to OpenHCL / Hyper-V VTLs

KVM Planes solves the gap described by the OpenHCL project:

| Requirement | Hyper-V Solution | KVM Planes Solution |
|-------------|-----------------|---------------------|
| Paravisor traps guest instructions | VTLs (Virtual Trust Levels) | Planes (plane 0 = highest privilege) |
| Host targets IRQs to guest directly | VTL interrupt targeting | `device-plane=2` + per-plane IRQ routing |
| Hardware-backed isolation | SNP VMPLs, TDX L2 | SNP VMPLs (TDX not yet) |
| Plane/VTL switch notification | VTL return | `KVM_EXIT_PLANE_EVENT` |

### What's solved:
- ✅ Multiple privilege levels in a single VM
- ✅ Per-plane LAPIC/interrupt delivery
- ✅ Host targeting interrupts to specific plane (bypassing paravisor)
- ✅ Plane switch notifications
- ✅ SNP VMPL integration
- ✅ Restricted injection via #HV doorbell
- ✅ Per-plane memory attributes

### What's partially addressed:
- ⚠️ Some vCPU state incorrectly unshared between planes (known issue)
- ⚠️ Only `kernel-irqchip=split` works (no full in-kernel irqchip)
- ⚠️ IPI virtualization not fully thought through (per TODO in code)

### What's not yet addressed:
- ❌ TDX L2 support (approach #4 from OpenHCL roadmap)
- ❌ Hyper-V hypercall compatibility (would need GHCB/VMGEXIT instead)

## QEMU Build

- Source: `https://github.com/coconut-svsm/qemu` (branch with planes support)
- Configure: `--target-list=x86_64-softmmu --enable-kvm --enable-igvm`
- Required `libigvm` (C bindings built with `cargo-c` from https://github.com/microsoft/igvm)

## COCONUT-SVSM Build

```bash
cd /home/haitao/svsm
git submodule update --init
FW_FILE=/home/haitao/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd cargo xbuild configs/qemu-target.json
```

- No special branch needed for planes — standard `main` works
- `FW_FILE` bundles OVMF into the IGVM (required for full guest boot)
- Without `FW_FILE`, IGVM contains only the SVSM (useful for testing SVSM alone)

## EDK2 (OVMF) Build

```bash
cd /home/haitao/edk2   # branch: svsm
git submodule init && git submodule update
make -j$(nproc) -C BaseTools/
source ./edksetup.sh
build -p OvmfPkg/OvmfPkgX64.dsc -a X64 -b DEBUG -t GCC5 \
  -D DEBUG_ON_SERIAL_PORT -D DEBUG_VERBOSE -D TPM2_ENABLE \
  --pcd PcdUninstallMemAttrProtocol=TRUE -n $(nproc)
```

## Key QEMU Machine Properties for KVM Planes

### `kernel-irqchip=split`

The interrupt controller is split between kernel (local APIC) and userspace
(I/O APIC in QEMU). Required because COCONUT-SVSM's plane support needs QEMU
to control interrupt routing rather than letting KVM handle everything in-kernel.

### `device-plane=2`

Tells QEMU which plane owns devices and should receive IRQs. COCONUT-SVSM runs
the guest OS on plane 2, so device interrupts must be delivered there (not to
the SVSM on plane 0/1).

## Launch Command

```bash
sudo /home/haitao/qemu/build/qemu-system-x86_64 \
  -enable-kvm \
  -cpu EPYC-v4 \
  -machine q35,confidential-guest-support=sev0,memory-backend=ram1,igvm-cfg=igvm0,kernel-irqchip=split,device-plane=2 \
  -object memory-backend-memfd,id=ram1,size=8G,share=true,prealloc=false,reserve=false \
  -object sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1 \
  -object igvm-cfg,id=igvm0,file=/home/haitao/svsm/bin/coconut-qemu.igvm \
  -smp 8 \
  -no-reboot \
  -vga none \
  -netdev user,id=vmnic -device e1000,netdev=vmnic,romfile= \
  -drive file=/path/to/guest/image.qcow2,if=none,id=disk0,format=qcow2,snapshot=off \
  -device virtio-scsi-pci,id=scsi0,disable-legacy=on,iommu_platform=on \
  -device scsi-hd,drive=disk0,bootindex=0 \
  -serial stdio \
  -serial pty
```

## Hardware Requirements

- AMD EPYC Gen 3+ with SEV-SNP enabled in BIOS
- Host kernel with SEV-SNP + planes patches (`coconut-svsm/linux`, branch `svsm-planes-v6.17`)
- Must run QEMU as root (`/dev/sev` access)
- **Cannot test SNP on Azure VMs** (Hyper-V does not expose SEV-SNP to guests)
- Selftests work on any x86 machine with KVM (no SNP needed)

### Verifying SEV-SNP on bare-metal host

```bash
dmesg | grep -i "SEV\|SNP"
# Expected: SEV-SNP: SNP enabled, ASIDs available

cat /sys/module/kvm_amd/parameters/sev_snp
# Expected: Y
```

## Guest Requirements

- Linux v6.16+ kernel (has SVSM guest support upstream)
- `CONFIG_TCG_SVSM` for vTPM support

## Architecture Summary

```
┌─────────────────────────────────────────┐
│              QEMU + KVM                 │
│  (kernel-irqchip=split, device-plane=2) │
│                                         │
│  IRQ Routing Table:                     │
│    GSI 0-23 → plane 2 (devices)         │
│    MSI routes → plane field per-entry   │
├─────────────────────────────────────────┤
│  Plane 0: COCONUT-SVSM (VMPL0)         │
│  - Secure services (vTPM, attestation)  │
│  - Handles #HV doorbell → delivers IRQ  │
│  - Traps PVALIDATE, guest privileged ops│
├─────────────────────────────────────────┤
│  Plane 2: Guest OS (VMPL2)             │
│  - Receives device IRQs directly        │
│  - Runs OVMF → Linux                   │
│  - Lower privilege VMPL                 │
│  - KVM_EXIT_PLANE_EVENT on cross-plane  │
└─────────────────────────────────────────┘
```

## Status / Known Issues

- `-vga none` is required with QEMU 10.1 (guests may fail during VGA init)
- The kernel branch `svsm-planes-v6.17` is based on v6.17 with 60 patches
- Only `kernel-irqchip=split` mode works (in-kernel irqchip blocks plane creation)
- Some per-vCPU state incorrectly unshared between planes (patch author known issue)
- Plane 2 is hardcoded in COCONUT-SVSM for guest OS execution
- IPI virtualization not fully addressed (TODO in source)
- TDX support not included in this patch series
- Azure/Hyper-V VMs cannot test full SNP flow (no SEV-SNP passthrough)
- KVM Planes is listed in COCONUT-SVSM's development plan but the SVSM
  codebase itself doesn't require a special branch for it
