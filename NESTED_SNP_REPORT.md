# Report — Porting jepio's Hyper-V nested-SNP patches to stock Ubuntu 25.10 and booting an SNP guest under OpenVMM

**Author:** Copilot session `b5311a18-c841-40f6-a42f-8be7396d8ba2`
**Date:** 2026-05-13 UTC
**Status:** ✅ Success. A nested SEV-SNP guest boots inside OpenVMM on an Azure DCas_cc_v5 VM (Hyper-V L0) running the patched stock Ubuntu 25.10 kernel (6.17.0-23-generic + 19 patches).

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

19 commits, in apply order. (`git log --reverse` on `/datadrive/nested_openvmm/host-kernel-6.17/ubuntu-source/linux-6.17.0-23.23`.)

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
| 17 | `1b0402d1d` | x86/sev: Make virt_rmpupdate/virt_psmash WRMSR fault-safe | sev.c |
| 18 | `b868e81ee` | x86/sev: fall back to soft RMP when virt_rmpupdate/psmash #GP | sev.c |
| 19 | `371e6b424` | x86/sev: invoke snp_rmptable_init on Hyper-V nested SNP host | sev.c |
| 20 | `b33f4a17f` | x86/sev: set SYSCFG.SNP_EN on each CPU for nested Hyper-V soft RMP | sev.c |

#1–14 are ports of jepio's patches with minor refactoring to fit 6.17 APIs (most diffs were either context-only or a one-line type rename). #15 is a port of jepio's KVM patch. #16–20 are **new** patches written in this session to unblock the L0 contract on the Azure SKU.

### 3.1 Patches we wrote (not in jepio)

Four of the commits were authored during this session because they fixed bugs not present in jepio's environment:

- **`1b0402d1d` Make virt_rmpupdate/virt_psmash WRMSR fault-safe.** L0 in Azure delivers a `#GP` to the L1 instead of silently returning success when the prerequisites aren't met. The original jepio code used a plain `wrmsrl()` which converts that #GP into an oops. Switched to `wrmsrl_safe()` (with an extable entry in the inline asm) so we can detect and recover.
- **`b868e81ee` Fall back to soft RMP when virt_rmpupdate/psmash #GP.** Building on #17: when L0 refuses the WRMSR, fall back to writing only the soft shadow RMP entry. This is "good enough" for any code path that only inspects the shadow (e.g., the PSP-driven launch path needs the shadow state correct so that page validation succeeds).
- **`371e6b424` Invoke snp_rmptable_init on Hyper-V nested SNP host.** Wires the `mshyperv` Hyper-V detection path to call `snp_rmptable_init()` so that the L1 actually allocates and initializes the soft RMP. Without this the existing init path is only triggered on bare metal.
- **`b33f4a17f` Set SYSCFG.SNP_EN on each CPU.** The critical missing piece. The PSP / L0 contract requires that the *calling CPU* has `SYSCFG.SNP_EN` (bit 24 of MSR 0xc0010010) asserted before any `virt_rmpupdate`/`virt_psmash` MSR will be intercepted as a real RMP write. On bare metal, `init_amd()` does this. Under nested Hyper-V the kernel skips that path because it thinks it's a guest. The fix registers a cpuhp callback that re-runs the SNP_EN bit-set on every CPU online event.

The last patch is what unlocked the boot. Before it: L0 #GP'd every `virt_rmpupdate`, soft RMP got out of sync with reality, PSP rejected `SNP_GCTX_CREATE` with `INVALID_PLATFORM_STATE`. After it: L0 starts intercepting RMP writes for real, shadow stays consistent, PSP accepts the GCTX and the guest boots.

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

# 2. apply the 20-patch stack (from this session's tree)
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

Boot an SNP guest:

```bash
# uses snp-artifacts/{openvmm, vmlinuz-6.17.0-23-generic, initrd}
# IMPORTANT: openvmm writes the guest serial console + its own tracing
# to STDERR. Use `2>&1` (or `|&` in bash 4+) to capture both.
sudo timeout 60 /datadrive/nested_openvmm/snp-artifacts/run-snp-openvmm.sh \
    2>&1 | tee /datadrive/nested_openvmm/openvmm-run.log

# expect L2 dmesg in the log (these come from STDERR):
#   Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP
#   SEV: SNP running at VMPL0.
#   smp: Bringing up secondary CPUs ...           # MP (2 vCPUs)
#   virtio_blk virtio0: 1/0/0 default/read/poll queues   # PCIe virtio-blk
#   HELLO WORLD APP RUNNING IN SNP GUEST
#
# If you only see the "Running: env OPENVMM_LOG=..." line and nothing
# else, you forgot `2>&1` and only captured stdout.
```

That's the entire happy path.

## 8. Known caveats / next steps

- **L1 SYSCFG.SNP_EN is sticky** once flipped. A reboot via `systemctl reboot` (warm reset) will leave it set. Only a cold start through Azure deallocate clears it. Our cpuhp callback handles both cases idempotently.
- **`grub-reboot` not `grub-set-default`**: never `grub-set-default` the experimental kernel; only do `grub-reboot` (one-shot). This is what allowed multiple painless recoveries during iteration.
- **Soft-RMP-only paths** still leave the real L0 RMP entries in default state for some pages — fine for the GCTX_CREATE → LAUNCH_UPDATE happy-path but probably not for live migration, page sharing, or guest-mediated RMP updates. Worth auditing each WRMSR call site to confirm the shadow is the source of truth.
- **`CONFIG_DEBUG_INFO=y`** adds ~30 min per build. Keep on for now because the next debugging round will need it (kgdb / crash on guest live-migration etc.).
- **OpenVMM MP** works on Chris's latest (HEAD `eced60b7`). The 60s timeout in the repro shows guest reaching userspace on 1 vCPU; bumping `-p 2` and re-running is the next validation.
- **The 4 new patches** (1b0402d1d, b868e81ee, 371e6b424, b33f4a17f) should be sent upstream / to the jepio tree. They are written narrowly for the Hyper-V nested case and gated on `cpu_feature_enabled(X86_FEATURE_NESTED_VIRT_SNP_MSR)`, so they should be safe even on non-nested SNP hosts.
- **Migration/teardown path** for the new RMP allocator — when the guest exits, do we properly walk the soft RMP and reset shadow entries? Not yet exercised.

## 9. Artifacts (in `/datadrive/nested_openvmm/`)

- `host-kernel-6.17/ubuntu-source/linux-6.17.0-23.23/` — full patched source tree (HEAD `b33f4a17f`).
- `host-kernel-6.17/ubuntu-source/linux-*-gb33f4a17f-9_amd64.deb` — installed kernel debs.
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

— *end of report —*
