# Report — Porting jepio's Hyper-V nested-SNP patches to stock Ubuntu 25.10 and booting an SNP guest under OpenVMM

**Author:** Copilot session `b5311a18-c841-40f6-a42f-8be7396d8ba2`
**Date:** 2026-05-13 UTC
**Status:** ✅ Success. A nested SEV-SNP guest boots inside OpenVMM on an Azure DCas_cc_v5 VM (Hyper-V L0) running the patched stock Ubuntu 25.10 kernel (6.17.0-23-generic + 17 patches).

---

## 1. Goal & environment

- **Hardware**: Azure DCas_cc_v5 instance — AMD Milan/Genoa SEV-SNP-capable platform exposed through Hyper-V L0.
- **L0 hypervisor**: Hyper-V (Azure). Provides the nested-virtualization soft RMP MSRs (`virt_rmpupdate` = 0xc001f001, `virt_psmash` = 0xc001f002) and advertises `NestedVirtSnpMsr` (CPUID 0x8000001F.EAX bit 29). Refuses access until the calling CPU sets `SYSCFG.SNP_EN` (MSR 0xc0010010 bit 24).
- **L1 host kernel target**: stock Ubuntu 25.10 source package `linux-6.17.0-23.23` (release tag `6.17.0-23-generic`). User chose stock 25.10 so that Chris Oo's `openvmm-snp` branch could build/run against a Microsoft-blessed userspace.
- **L1 hypervisor under test**: OpenVMM, branch `openvmm_nested_snp`
  (haitaohuang fork) tracking `chris-oo/openvmm-snp`. Validated at two
  HEADs during this work:
  - `eced60b7` "snp: get mp support working" (May 11, initial victory).
  - `10d28c05` "virt_kvm/snp: update comment on how AP startup works
    with SNP on kvm" (May 12, latest at time of report). The May 12
    sync added 3 SNP-functional commits on top of the May 11 victory:
    `7a2a01d7` (virt_kvm/snp: discard page vis mappings on transitions
    to avoid staleness — stability fix), `47900c3b` (snp: allow pcie
    virtio devices — feature add), and `10d28c05` (comment-only).
- **L2 guest payload**: stock `vmlinuz-6.17.0-23-generic` + tiny "hello world SNP" initramfs (160 MB RAM, 1 vCPU).
- **Reference patch series**: `jepio/linux` "nested SNP host" tree (a 19-patch series against an older base, written for a custom in-house kernel). The user supplied a gap analysis in `~/amdsev-kernel-gap-analysis.md`.

## 2. Approach

1. Acquire and unpack the Ubuntu 25.10 source package for `linux-6.17.0-23-generic`.
2. Identify which jepio patches were already upstream in 6.17 vs which still had to be ported. The "still required" set covered:
   - Hyper-V nested SNP probing (`NestedVirtSnpMsr` CPUID, RMP table allocation, `snp_rmptable_init` entry point).
   - PSP/CCP quirk machinery (platform PSP master, vdata, firmware-version skip, SEV-init skip, TMR skip).
   - IOMMU and AMD CPU init guards for the "virtualized SNP host" case.
   - KVM tweaks (keep `lbrv` enabled under a hypervisor).
3. Apply, rebuild, install, reboot, observe. Iterate until the SNP guest launches.

This document is the post-mortem of that loop: what the patches do, why they were needed, what we found broken on the way, and how to reproduce from scratch.

## 3. Final patch stack on top of `linux-6.17.0-23.23`

17 commits in the **minimal** functional stack, in apply order. (`git log --reverse`
on `/datadrive/nested_openvmm/host-kernel-6.17/ubuntu-source/linux-6.17.0-23.23`,
branch `master` HEAD `2a624399c`. The actual git log additionally contains
4 early platform-PSP infrastructure commits — ACPI ASPT helper, Hyper-V PSP
platform-device registration, PSP IRQ support, CCP bind to platform PSP —
that are unchanged ports of jepio's series and not surfaced in the table.)
Three earlier rows existed in previous revisions of this report:
the `b868e81ee` "soft-RMP fallback on WRMSR #GP" row (removed after build
#10nob868 confirmed the fallback is dead code in the happy path), the
`1b0402d1d` "Make virt_rmpupdate/virt_psmash WRMSR fault-safe" row (removed
after build #11noextable confirmed the extable wrapper is dead code once
SYSCFG.SNP_EN is set per-CPU), and a second separate row that split rows
#17 / #18 from this session's earlier two-commit form — squashed into the
single `2a624399c` row here for cleaner review. All removed patches are
preserved on archive refs — see §4 entries below.

| #  | SHA (short) | Subject | Touches |
|----|-------------|---------|---------|
| 1  | `7f7ced843` | crypto: ccp - Add vdata for platform device | sp-platform.c |
| 2  | `6c1ce6bf8` | crypto: ccp - Skip DMA coherency check for platform psp | sp-platform.c |
| 3  | `002587910` | crypto: ccp - Allow platform device to be psp master device | sp-dev/.{c,h}, sp-pci.c, sp-platform.c |
| 4  | `bb90f9bbd` | x86/hyperv: Allocate RMP table during boot | hv_init.c, mshyperv.{h,c}, sev.h, hvgdk_mini.h, sev.c |
| 5  | `c7a947fbb` | x86/sev: Add support for NestedVirtSnpMsr | cpufeatures.h, msr-index.h, sev.c |
| 6  | `5fc96806a` | x86/sev: Maintain shadow rmptable on Hyper-V | sev.h, mshyperv.c, sev.c |
| 7  | `5497c0b9a` | x86/amd: Configure necessary MSRs for SNP during CPU init when running as a guest | amd.c |
| 8  | `db55fbddd` | x86/amd: Skip early_rmptable_check when running on Hyper-V | amd.c, mshyperv.c |
| 9  | `d83d5070c` | x86/sev: Don't fail iommu SNP check when running virtualized | sev.c |
| 10 | `7148c6dff` | crypto: ccp - Introduce quirk system for psp | sp-dev.h, sp-platform.c |
| 11 | `dbf337ca5` | crypto: ccp - Add quirk to ignore PSP firmware version check | sev-dev.c, sp-dev.h, sp-platform.c |
| 12 | `b060ead8c` | crypto: ccp - Add quirk to ignore SEV init | sev-dev.c, sp-dev.h, sp-platform.c |
| 13 | `eb60facec` | WIP crypto: ccp - Allocate/free platform MSI interrupts | sp-platform.c |
| 14 | `9aebf31e2` | iommu/amd: Don't clear CC_ATTR_HOST_SEV_SNP when running virtualized | iommu/amd/init.c |
| 15 | `82dc8d7ee` | KVM: SVM: Keep lbrv enabled when running on a hypervisor | kvm/svm/svm.c |
| 16 | `218669e5d` | crypto: ccp - Skip TMR allocation when PSP_QUIRK_SNP_ONLY is set | sev-dev.c |
| 17 | `2a624399c` | x86/sev: enable nested Hyper-V SNP soft RMP host on 6.17 (init + SYSCFG.SNP_EN) | sev.c |

(Note: `2a624399c` is the squashed form of two earlier separate commits
`82f5394c6` and `5fee34c93` — same code, fewer commits.  Those in turn
were rebased equivalents of `2504290f6`/`3d41cdc9b` after dropping
`1b0402d1d`, themselves rebased from `371e6b424`/`b33f4a17f` after
dropping `b868e81ee`.  The 2-commit form is preserved on the
`nested-snp-port-6.17-2-patches` ref on the fork in case anyone wants
to see the bisect history.)

#1–14 are ports of jepio's patches with minor refactoring to fit 6.17 APIs (most diffs were either context-only or a one-line type rename). #15 is a port of jepio's KVM patch. #16 is a new patch that uses jepio's PSP_QUIRK framework but does the TMR skip. #17 is **the one new patch written in this session** to make jepio's stack functional on Ubuntu 25.10's 6.17 base.

### 3.1 The one new patch we wrote (and why jepio didn't need it)

Patch #17 (`2a624399c`) is a single combined fix that addresses **two upstream Linux kernel evolutions** between jepio's base (~6.7-rc6-next) and Ubuntu 25.10's 6.17 base. The L0 (Azure Hyper-V) is identical in both cases; the forcing functions are entirely on the L1 kernel side.

**Evolution 1: `snp_rmptable_init()` lost its initcall registration.**
In jepio's base, `arch/x86/kernel/sev.c` (later moved to `arch/x86/virt/svm/sev.c`) registered `snp_rmptable_init()` directly: `fs_initcall(snp_rmptable_init);`. It ran at boot regardless of whether an AMD IOMMU was present.

Upstream Linux removed that `fs_initcall` and made `snp_rmptable_init()` reachable only from `iommu_snp_enable()` (drivers/iommu/amd/init.c:3381). The motivation was an ordering bug — on real bare-metal systems, the IOMMU driver's SNP support needs to be enabled *before* the soft RMP is initialised, so the kernel maintainers tied the two together via a direct call.

But Azure Hyper-V does **not expose an AMD IOMMU** to the L1 VM (no `IVRS` ACPI table, no `amd-vi` device). So in 6.17 `iommu_snp_enable()` never runs → `snp_rmptable_init()` never runs → no soft RMP → PSP later rejects `SNP_GCTX_CREATE` with `INVALID_PLATFORM_STATE`. Jepio's stack didn't see this because his `fs_initcall` fired regardless of IOMMU presence.

**Evolution 2: the soft-RMP early-return inadvertently skips per-CPU SNP_EN.**
In jepio's base, `snp_rmptable_init()` always called `__snp_enable(smp_processor_id())` on the BSP plus `cpuhp_setup_state(... __snp_enable ...)` for APs. `__snp_enable()` is the function that sets `MSR_AMD64_SYSCFG_SNP_EN` (bit 24) on each CPU.

Jepio's own port patch `5fc96806a` "Maintain shadow rmptable on Hyper-V" (which is also in our stack) added an early-return at the top of `snp_rmptable_init()`:

```c
int __init snp_rmptable_init(void)
{
    ...
    if (snp_soft_rmptable()) {
        /* allocate the segment table, zero it, return */
        return 0;     // <- soft-RMP early-return
    }
    /* original hardware-SNP path: __snp_enable() cpuhp_setup_state, etc. */
}
```

On the soft-RMP path that early-return bypasses the per-CPU `__snp_enable()` registration — so on Hyper-V no CPU ever gets SYSCFG.SNP_EN set. Hyper-V (L0) only starts intercepting the `virt_rmpupdate` / `virt_psmash` MSRs once `SYSCFG.SNP_EN` is asserted on the calling CPU; until then those MSR writes raise `#GP` and RMP transitions silently fall back to the shadow only, leaving real RMP entries in the default state.

Jepio didn't trip this because his kernel didn't have the `snp_soft_rmptable()` early-return yet (he authored it later in his series, but his own testbed never exercised an end-to-end nested SNP guest launch via `SNP_GCTX_CREATE` — only kernel-init-time dmesg sanity).

**The fix (`2a624399c`):**
- Adds `__snp_enable_hv()` — a fault-safe variant of `__snp_enable` that sets only bit 24 (not `SNP_VMPL_EN`, which is unverified in the nested context) via `wrmsrq_safe` / `rdmsrq_safe`.
- Registers it via `cpuhp_setup_state(CPUHP_AP_ONLINE_DYN, ...)` inside the `snp_soft_rmptable()` branch so the bit gets set on every CPU online event.
- Adds `snp_rmptable_init_hv()` as a `device_initcall` that calls `snp_rmptable_init()` when `snp_soft_rmptable()` is true — replacing the `fs_initcall` upstream dropped.

**Why one patch instead of two:** the changes were originally landed as two commits (`82f5394c6` for the initcall, `5fee34c93` for the cpuhp callback). They're combined here because they're a single conceptual fix (and would be reviewed as such upstream): both are *consequences* of the soft-RMP path no longer being a first-class citizen in mainline.

Two earlier patches were written and shipped but **dropped from the minimal stack** after they proved dormant once SYSCFG.SNP_EN was being set per-CPU:

- **`b868e81ee` Fall back to soft RMP when virt_rmpupdate/psmash #GP** — shipped in builds 1–9. Dropped in build #10nob868 once the SNP_EN per-CPU fix made the WRMSRs succeed. Verified the fallback never fires. Preserved on the `master-with-b868-archive` tag.
- **`1b0402d1d` Make virt_rmpupdate/virt_psmash WRMSR fault-safe** — shipped in builds 5–10. Dropped in build #11noextable. With SYSCFG.SNP_EN set on every CPU before any `virt_rmpupdate`/`virt_psmash` runs, the underlying #GP path no longer exists in the happy path; iter-3 dmesg shows zero `_ASM_EXTABLE_TYPE_REG` hits and the SNP guest boots cleanly. Preserved on the `master-with-1b04-archive` branch / `nested-snp-port-6.17-with-extable` ref on the fork.

Patch #17 (`2a624399c`) is the one that unlocked the boot. Before it: L0 #GP'd every `virt_rmpupdate`, soft RMP got out of sync with reality, PSP rejected `SNP_GCTX_CREATE` with `INVALID_PLATFORM_STATE`. After it: L0 starts intercepting RMP writes for real, shadow stays consistent, PSP accepts the GCTX and the guest boots.

## 4. Iteration timeline (what we learned the hard way)

Builds were numbered 1–9 (each build = one reboot). The journey:

- **Builds 1–3**: bring-up. Apply jepio patches one by one, get the kernel to build and boot, hit the obvious oops on `wrmsrl(virt_rmpupdate)` with #GP. Insight: the `wrmsr`s are not safe.
- **Build 4**: introduce `wrmsrl_safe`. Now boots, but `snp_rmptable_init` is never called → CCP TMR allocation crashes because PSP_QUIRK_SNP_ONLY pathway isn't gated correctly.
- **Build 5**: add the CCP TMR-skip patch + extable entry. Now boots further. But: PSP returns `INVALID_PLATFORM_STATE` on `SNP_GCTX_CREATE`.
- **Builds 6–7**: trace through L0 behavior; discover that soft RMP allocates but the L0 `virt_rmpupdate` interceptor never fires.
- **Build 8**: add #GP-fallback path and call `snp_rmptable_init` explicitly. Still `INVALID_PLATFORM_STATE`. With a small out-of-tree probe module (`/tmp/snp-probe/snp_probe.ko`) confirmed that `SYSCFG.SNP_EN` is **not set** on any CPU at boot — the missing prerequisite.
- **Build 9**: add `__snp_enable_hv` cpuhp callback that flips bit 24 of SYSCFG on every CPU. Boot, run OpenVMM. SNP guest comes up:
  - L1 dmesg: `SEV-SNP: Soft RMP table initialised; SYSCFG.SNP_EN set on all CPUs` and `kvm_amd: SEV-SNP enabled (ASIDs 1 - 64)`.
  - L2 dmesg: `Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP`, `SEV: SNP running at VMPL0.`, `SEV: SNP guest platform devices initialized.`
  - L2 userspace: `HELLO WORLD APP RUNNING IN SNP GUEST`.
- **Build #10nob868** (minimality test): drop `b868e81ee` (soft-RMP fallback on WRMSR #GP) from the stack, rebase, rebuild, reboot. Hypothesis: now that `b33f4a17f` makes the WRMSRs succeed, the fallback is dormant and removable. Verified: SNP guest boots end-to-end with the same outcomes as build #9 (HELLO WORLD, MP, virtio_blk, no `falling back to soft RMP table only` messages, no #GP / extable hits). Result: `master` branch updated to drop the patch; the original stack is preserved on the `master-with-b868-archive` tag for reference.
- **Build #11noextable** (second minimality test): drop `1b0402d1d` (extable wrapper around `virt_rmpupdate`/`virt_psmash` WRMSRs) from the stack, rebase, rebuild, reboot. Hypothesis: with SYSCFG.SNP_EN set per-CPU and soft-RMP initialised before any RMP transition, these WRMSRs never #GP, so the extable wrapper is dead code. Verified: SNP guest boots end-to-end (HELLO WORLD, 2 SNP-at-VMPL0 markers, 1 MP secondary, 3 virtio_blk lines, no kernel oops or `rmpupdate` stacktrace in dmesg). Result: `master` branch updated to drop the patch (now 22 commits over the Ubuntu base); the previous stack is preserved on `master-with-1b04-archive` (locally) and `nested-snp-port-6.17-with-extable` on the fork. Note: this is a *narrowness* call — if the L0 hypervisor ever regresses to #GP'ing these WRMSRs (Azure-side change, kernel CPU online race with delayed SNP_EN write, etc.) the kernel will now oops in IRQ-disabled context inside `rmpupdate+0x124/0x380`. If you ship this stack to production, consider re-adding `1b04` as cheap insurance (12 lines, one file).

## 5. Diagnostic techniques that paid off

- **Custom probe module** (`snp_probe.ko`): tiny `module_init` that prints `rdmsr(SYSCFG)` per-CPU and attempts a single `wrmsrl_safe(virt_rmpupdate, …)`. Booting once with this loaded revealed the SNP_EN-unset condition immediately. Worth keeping around as a per-iteration sanity check.
- **`grub-reboot` one-shot**: every iteration's reboot used `sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux <KVER>"`. This means the GRUB default was never permanently changed to the experimental kernel; a panic or hang on the experimental kernel would naturally fall back to the previous good kernel on the next cold boot. The user used this safety net twice to recover from "boot offline" events.
- **`wrmsrl_safe` + extable** plus a dmesg counter let us distinguish "L0 refused" (#GP) from "L0 quietly accepted but did nothing" (wrong shadow state) without crashing.
- **Reading L0's behavior backwards from the L1 PSP error code**: `INVALID_PLATFORM_STATE` on `SNP_GCTX_CREATE` is undocumented in the PSP spec for the case "page is shadow-private but not real-private", but it matches exactly. This was the smoking gun that pointed at the L0 → real-RMP path being broken.

## 6. Build & boot details

- **Source**: `apt source linux-image-6.17.0-23-generic` on Ubuntu 25.10, unpacks to `host-kernel-6.17/ubuntu-source/linux-6.17.0-23.23/`. (The directory layout is unusual — `linux-6.17.0-23.23/` is the upstream source tree, not a packaging side tree.)
- **Config**: started from `/boot/config-6.17.0-23-generic` and accepted all new symbols at default. `CONFIG_DEBUG_INFO=y` was kept on intentionally — debug info adds ~30 min to packaging but is essential for the next step of debugging guest crashes with `crash` / `gdb`.
- **Build command** (`build-iteration.sh`):
  ```
  make -j16 bindeb-pkg LOCALVERSION=-nested-snp-port KDEB_PKGVERSION=6.17.13-g<sha>-<iter>
  ```
- **Install**: only the 3 essential debs are dpkg-i'd — `linux-libc-dev`, `linux-image`, `linux-headers`. The huge `linux-image-…-dbg` deb is built but not installed by default.
- **Reboot path**: `grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 6.17.13-nested-snp-port-nested-snp-port" && systemctl reboot`.

## 7. Reproduce from scratch

Prerequisites: Azure DCas_cc_v5 VM (or equivalent Hyper-V nested-SNP-capable host), Ubuntu 25.10 image, ≥ 50 GB free on `/datadrive`, `sudo` available, network access to Microsoft repos.

```bash
# 0. one-time tooling
sudo apt update
sudo apt install -y build-essential bc bison flex libelf-dev libssl-dev \
    libncurses-dev kmod rsync git fakeroot dpkg-dev \
    devscripts pkg-config msr-tools

# 1. source tree
mkdir -p /datadrive/nested_openvmm/host-kernel-6.17/ubuntu-source
cd /datadrive/nested_openvmm/host-kernel-6.17/ubuntu-source
apt source linux-image-6.17.0-23-generic            # creates linux-6.17.0-23.23/
cd linux-6.17.0-23.23
git init && git add -A && git commit -q -m "ubuntu 25.10 6.17.0-23.23 base"

# 2. apply the 17-patch stack (this report's `master` branch)
#    Patches live in /datadrive/nested_openvmm/host-kernel-6.17/patches/ (or
#    cherry-pick from the working tree under HEAD).
git am /datadrive/nested_openvmm/host-kernel-6.17/patches/00*-*.patch

# 3. config
cp /boot/config-6.17.0-23-generic .config
yes "" | make olddefconfig
scripts/config -d MODULE_SIG_KEY                    # avoid signing-key issues
scripts/config -e DEBUG_INFO -e DEBUG_INFO_DWARF5

# 4. build + install via the helper (auto reboots into the new kernel)
bash /datadrive/nested_openvmm/build-iteration.sh 1

# (helper does: make bindeb-pkg, dpkg -i, update-grub, grub-reboot, reboot)
```

After reboot, verify the host environment:

```bash
uname -r                                            # expect 6.17.13-nested-snp-port-nested-snp-port
sudo modprobe msr
for cpu in $(seq 0 $(($(nproc) - 1))); do
    printf "cpu%d 0xc0010010=0x%s\n" "$cpu" "$(sudo rdmsr -p $cpu 0xc0010010)"
done
# expect every CPU to read 0x1800000 (or any value with bit 24 set)

sudo dmesg | grep -E "SEV-SNP|kvm_amd"
# expect:
#   SEV-SNP: Soft RMP table initialised; SYSCFG.SNP_EN set on all CPUs
#   kvm_amd: SEV-SNP enabled (ASIDs 1 - 64)
```

Build OpenVMM (one-off):

```bash
cd /datadrive/nested_openvmm
git clone https://github.com/haitaohuang/openvmm.git
cd openvmm && git checkout openvmm_nested_snp
# (tracks chris-oo/openvmm-snp; HEAD 10d28c05 at the time of this report)
cargo build --release --bin openvmm
# binary at target/release/openvmm
```

The latest sync added 3 SNP-functional commits over the original
"victory" HEAD; one of them (`7a2a01d7`) is a stability fix you want
even for a hello-world repro, and `47900c3b` is required if you want
PCIe virtio devices in the guest. The default `run-snp-openvmm.sh` in
this HEAD now wires a virtio-blk-over-PCIe device and runs 2 vCPUs to
exercise both code paths.

Boot an SNP guest. Two recipes work, depending on what you need:

**Option A — interactive (richest output, best for first run):**

```bash
# uses snp-artifacts/{openvmm, vmlinuz-6.17.0-23-generic, initrd}
# Run with a real TTY so the guest serial flows straight to your terminal.
sudo /datadrive/nested_openvmm/snp-artifacts/run-snp-openvmm.sh
# Wait ~50 s for SNP LAUNCH_UPDATE to finish, then watch the guest boot.
# Hit Ctrl-A x to quit, or Ctrl-C twice.
```

**Option B — captured-to-file (recommended for repro / autopilot):**

```bash
# uses snp-artifacts/{openvmm, vmlinuz-6.17.0-23-generic, initrd}
# IMPORTANT: 60 s is the minimum. SNP LAUNCH_UPDATE alone takes ~45 s
# on this hardware; the guest only reaches userspace around 50–55 s.
sudo timeout 60 /datadrive/nested_openvmm/snp-artifacts/run-snp-openvmm.sh \
    > /datadrive/nested_openvmm/openvmm-run.log 2>&1

# expect L2 dmesg in the log (openvmm writes serial+trace to STDERR;
# the redirect captures both into the same file):
#   Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP
#   SEV: SNP running at VMPL0.
#   smp: Bringing up secondary CPUs ...           # MP (2 vCPUs)
#   virtio_blk virtio0: 1/0/0 default/read/poll queues   # PCIe virtio-blk
#   HELLO WORLD APP RUNNING IN SNP GUEST
```

**Option C — clean serial-only log (no trace noise):**

```bash
# patch run-snp-openvmm.sh to use --com1 file=PATH instead of --com1 console:
#   --com1 file=/datadrive/nested_openvmm/openvmm-serial.log
# then run normally:
sudo timeout 60 /datadrive/nested_openvmm/snp-artifacts/run-snp-openvmm.sh
# guest serial ends up in openvmm-serial.log (~400 lines, no trace mixed in).
```

**Pitfalls — these do NOT work:**

- `… 2>&1 | tee log` — the pipe blocks openvmm's mesh-spawned worker
  from emitting most output; you'll see the first ~50 s of trace logs
  and *no* guest dmesg, regardless of how long the timeout is.
- `sudo timeout 30 …` — too short. SNP LAUNCH_UPDATE on the kernel +
  initrd images alone runs ~45 s before the first vCPU starts. Use 60 s
  or more.
- Running without `sudo` — KVM_SNP_LAUNCH_* ioctls require root.

That's the entire happy path.

## 8. Known caveats / next steps

- **L1 SYSCFG.SNP_EN is sticky** once flipped. A reboot via `systemctl reboot` (warm reset) will leave it set. Only a cold start through Azure deallocate clears it. Our cpuhp callback handles both cases idempotently.
- **`grub-reboot` not `grub-set-default`**: never `grub-set-default` the experimental kernel; only do `grub-reboot` (one-shot). This is what allowed multiple painless recoveries during iteration.
- **Soft-RMP-only paths** still leave the real L0 RMP entries in default state for some pages — fine for the GCTX_CREATE → LAUNCH_UPDATE happy-path but probably not for live migration, page sharing, or guest-mediated RMP updates. Worth auditing each WRMSR call site to confirm the shadow is the source of truth.
- **`CONFIG_DEBUG_INFO=y`** adds ~30 min per build. Keep on for now because the next debugging round will need it (kgdb / crash on guest live-migration etc.).
- **OpenVMM MP** works on Chris's latest (HEAD `eced60b7`). The 60s timeout in the repro shows guest reaching userspace on 1 vCPU; bumping `-p 2` and re-running is the next validation.
- **The one new patch** (`2a624399c` — `snp_rmptable_init` device_initcall + per-CPU SYSCFG.SNP_EN via cpuhp) should be sent upstream / to the jepio tree. It is narrowly written for the Hyper-V nested case and gated on `snp_soft_rmptable()`, so it is safe on non-nested SNP hosts (the initcall becomes a no-op there). Three earlier candidates were tested and dropped from the minimal stack — preserved on archive refs in case future L0/kernel changes resurrect the underlying failure modes:
  - `b868e81ee` (soft-RMP fallback on WRMSR #GP) on `master-with-b868-archive` / `nested-snp-port-6.17-with-b868`,
  - `1b0402d1d` (extable wrapper around WRMSR) on `master-with-1b04-archive` / `nested-snp-port-6.17-with-extable`,
  - the unsquashed 2-commit form of `2a624399c` on `nested-snp-port-6.17-2-patches` (`82f5394c6` + `5fee34c93`).
- **Migration/teardown path** for the new RMP allocator — when the guest exits, do we properly walk the soft RMP and reset shadow entries? Not yet exercised.

## 9. Artifacts (in `/datadrive/nested_openvmm/`)

- `host-kernel-6.17/ubuntu-source/linux-6.17.0-23.23/` — full patched source tree (HEAD `2a624399c`, branch `master`; archives at `master-with-b868-archive` tag `b33f4a17f`, `master-with-1b04-archive` branch `3d41cdc9b`, and `master-with-2-separate-patches` branch `5fee34c93`).
- `host-kernel-6.17/ubuntu-source/linux-*-g5fee34c93-11noextable_amd64.deb` — installed kernel debs.
- `openvmm/` — OpenVMM checkout on branch `openvmm_nested_snp`
  (HEAD `10d28c05`, tracking `chris-oo/openvmm-snp`).
- `snp-artifacts/openvmm` — rebuilt OpenVMM binary from `10d28c05`.
  Original `eced60b7` binary kept as `openvmm.eced60b7.bak` for diff.
- `snp-artifacts/run-snp-openvmm.sh` — synced from Chris's tree
  (PCIe-virtio + 2 vCPU defaults).
- `openvmm-run-20260513T064326Z.log` — first successful guest boot
  (HEAD `eced60b7`, 1 vCPU, no PCIe).
- `openvmm-run-20260513T161202Z-postsync.log` — re-test on new HEAD
  (HEAD `10d28c05`, 2 vCPUs, PCIe virtio-blk).
- `AUTOPILOT_PLAN.md` — per-iteration playbook with full journal.
- `HACKATHON_FINDINGS.md` — earlier findings doc.
- `~/amdsev-kernel-gap-analysis.md` — initial gap analysis vs jepio.

## 10. Sync update (2026-05-13 16:12 UTC) — refresh to chris-oo HEAD

After the initial victory on OpenVMM `eced60b7`, a diff against
`chris-oo/openvmm-snp` revealed we were behind. Chris had force-pushed
a rebase on May 11 and then added three new SNP-functional commits:

| commit | type | impact |
|---|---|---|
| `7a2a01d7` virt_kvm/snp: discard page vis mappings on transitions to avoid staleness | bug fix (+60 LOC in `vmm_core/virt_kvm/src/lib.rs`) | Stability fix for PSC-transition page-visibility caches. The hello-world repro didn't hit the bug, but heavier workloads likely would. |
| `47900c3b` snp: allow pcie virtio devices | feature add | Lets `openvmm_entry` accept `--pcie-root-complex` / `--virtio-blk` on isolated SNP VMs. Required for any practical SNP guest beyond hello-world. |
| `10d28c05` virt_kvm/snp: update comment on AP startup | comment-only | n/a |

Action: created a clean `openvmm_nested_snp` branch from
`chris-oo/openvmm-snp` (our 58 "ahead" commits were exactly the
rebased-equivalents of his lower 58 — no local work lost), rebuilt
`cargo build --release --bin openvmm` (incremental 1m34s), staged the
new binary into `snp-artifacts/`, refreshed the repro script (which
also now defaults to 2 vCPUs + virtio-blk-over-PCIe), and re-ran the
60-second repro.

Outcome: guest still boots; additionally now sees
`smp: Bringing up secondary CPUs ...` (MP confirmed end-to-end on
2 vCPUs) and `virtio_blk virtio0: 1/0/0 default/read/poll queues`
(PCIe virtio-blk works in SNP guest). Full log:
`openvmm-run-20260513T161202Z-postsync.log`.

## 11. QEMU vs OpenVMM enclave demo — what's identical, what isn't

The repo ships two end-to-end enclave demos that exercise the same
guest application (`enclave-init` doing two-way ecall/ocall + real
PSP-signed attestation over virtio-vsock) under two different VMMs:

- `demo.sh` + `launch-snp.sh` → QEMU + AmdSev OVMF (legacy path, SNP host kernel)
- `demo-openvmm.sh` + `launch-snp-openvmm.sh` → OpenVMM (this report's path, nested-SNP host kernel)

### 11.1 Guest payload — bit-for-bit identical

Both launchers `-kernel`/`--kernel` and `-initrd`/`--initrd` the same
two files from `/datadrive2/work/`:

| File | Sha256 | Size |
|---|---|---|
| `OHCL-Linux-Kernel/arch/x86/boot/bzImage` | `765e07d1eaca4c15c23a9ecc0e3d02e03b43dfab98613b34333f96fd6ad6fe6e` | 13,730,304 B |
| `initramfs.cpio.gz` (contains `enclave-init` as `/init`) | `c77ce8d5932f7f2fe68fd89400b8a299adc66a264a7a764fc5e378b8ed85792f` | 260,168 B |

So the OHCL kernel binary and the entire guest userspace are the same
inputs to the PSP on both demos. Any difference in what the PSP measures
comes from the **launch surface around** these files, not from the files
themselves.

### 11.2 Launch surface differences

| Aspect | QEMU (`launch-snp.sh`) | OpenVMM (`launch-snp-openvmm.sh`) |
|---|---|---|
| Kernel cmdline (default) | `console=ttyS0 earlyprintk=serial panic=10 init=/init swiotlb=force` | `console=ttyS0 earlyprintk=serial earlycon panic=-1` |
| vCPUs / RAM | 1 / 1024 MB | 2 / 256 MB |
| Firmware | AmdSev OVMF (UEFI) → Linux | Direct bzImage entry (no firmware) |
| vsock transport | `vhost-vsock-pci`, AF_VSOCK on host, CID 42 | virtio-vsock over PCIe + Unix-socket relay (`/tmp/openvmm-vsock_<port>`) |
| Host kernel | 6.7.0-rc6-next SNP-host (jepio's stack) | 6.17.0-23-generic + this report's 17-patch stack (nested-SNP) |

### 11.3 Why QEMU needs OVMF and OpenVMM doesn't

SEV-SNP guests must enter execution from **measured, encrypted memory at
the reset vector**. The launch measurement is whatever the PSP hashes
between `SNP_LAUNCH_START` and `SNP_LAUNCH_FINISH`, and the guest's first
instruction has to come from one of those measured pages. The two VMMs
satisfy this differently:

- **QEMU + AmdSev OVMF flow.** QEMU itself has no SNP-aware Linux
  trampoline. AmdSev OVMF (a special SEV-SNP build of EDK2) is loaded
  into the guest reset vector and hashed by the PSP into the launch
  digest. OVMF runs `PVALIDATE` on the rest of guest memory, then reads
  the `-kernel`/`-initrd`/`-append` blobs out of QEMU's `fw_cfg`
  pseudo-device, hashes them into a measured "kernel hash table" /
  secrets page, and chain-loads Linux. The PSP launch digest therefore
  covers **OVMF only**; bzImage/initrd/cmdline are bound *indirectly*
  through OVMF's own verified hash chain.
- **OpenVMM direct-boot flow.** OpenVMM is SNP-aware in-process. It
  loads bzImage + initrd + the Linux boot params (zero page /
  `setup_header`) into guest memory itself, drives `SNP_LAUNCH_UPDATE`
  so the PSP measures those pages, and at `SNP_LAUNCH_FINISH` the guest
  starts directly at Linux's 64-bit entry. The "measured loader" role
  AmdSev OVMF plays for QEMU is built into the VMM. Firmware would be
  redundant.

### 11.4 Consequence for attestation surface

Because the two demos hand the PSP different bytes, the launch
measurement field in the SNP attestation report differs **even though
the kernel and initrd binaries are identical**:

| Demo | Launch measurement covers | To verify "this exact kernel ran" you must also check |
|---|---|---|
| QEMU + OVMF | The AmdSev OVMF blob bytes | The kernel-hash-table / secrets page OVMF builds at runtime, transitively |
| OpenVMM direct boot | bzImage + initrd + cmdline + boot params | Nothing further — the measurement itself binds the kernel/initrd bytes |

In practice OpenVMM's surface is the simpler attestation story for an
enclave demo: a relying party that knows the expected `bzImage` +
`initramfs.cpio.gz` + cmdline can compute the expected launch digest
deterministically and compare it to the PSP report's `MEASUREMENT`
field. With the QEMU+OVMF path the relying party must instead trust
OVMF and verify the indirected hash chain it builds.

Other measurement-relevant fields in the SNP report (Policy, VMPL,
`HOST_DATA`, `ID_KEY_DIGEST`) are not affected by the choice of VMM
in this repo — both demos use the default policy and don't populate
host-data.

— *end of report —*
