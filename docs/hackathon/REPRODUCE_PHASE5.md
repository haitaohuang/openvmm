# Reproduce Phase 5: SNP-protected guest under OpenVMM

This is the recipe for what `HACKATHON_FINDINGS.md` originally called
"Phase 5: openvmm SNP — NOT POSSIBLE TODAY". It is now possible, on
this same DCas_cc_v5 host, by combining two pieces of work that landed
**after** the original hackathon:

1. A **17-patch nested-SNP backport** to stock Ubuntu 25.10 source
   (`linux-6.17.0-23.23`). This is what turns the L1 kernel into a
   Hyper-V-aware "virtualized SNP host". Branch:
   `haitaohuang/linux:nested-snp-port-6.17` (HEAD `2a624399c`).
2. **Chris Oo's `openvmm-snp` branch**, which has the full SNP launch
   sequence wired in `vm/kvm` and a working `guest_memfd`-backed
   memory model. Our fork is `haitaohuang/openvmm:openvmm_nested_snp`,
   currently at HEAD `10d28c05`.

This doc is a high-density quickstart. The full post-mortem (with
patch-by-patch analysis, iteration history, dropped candidates, and
diagnostic techniques) is in `REPORT_nested_snp_openvmm.md` in the
[`haitaohuang/vm_enclave`](https://github.com/haitaohuang/vm_enclave)
companion repo.

---

## 0. Prerequisites

| Item | Required |
|------|----------|
| Hardware | Azure DCas_cc_v5 (or equivalent Hyper-V nested-SNP-capable VM) |
| Base distro | Ubuntu 25.10 |
| Disk free | ≥ 50 GB on `/datadrive` |
| Tools | `build-essential bc bison flex libelf-dev libssl-dev libncurses-dev kmod rsync git fakeroot dpkg-dev devscripts pkg-config msr-tools` |
| Rust | stable toolchain (any 2024+) |

---

## 1. Build & install the patched host kernel

```bash
sudo apt update
sudo apt install -y build-essential bc bison flex libelf-dev libssl-dev \
    libncurses-dev kmod rsync git fakeroot dpkg-dev devscripts pkg-config \
    msr-tools

# 1.1 Source tree
mkdir -p /datadrive/nested_openvmm/host-kernel-6.17/ubuntu-source
cd /datadrive/nested_openvmm/host-kernel-6.17/ubuntu-source
apt source linux-image-6.17.0-23-generic     # creates linux-6.17.0-23.23/
cd linux-6.17.0-23.23
git init && git add -A && git commit -q -m "ubuntu 25.10 6.17.0-23.23 base"

# 1.2 Pull the 17-patch nested-SNP stack
git remote add hh https://github.com/haitaohuang/linux.git
git fetch hh nested-snp-port-6.17
git checkout -B master hh/nested-snp-port-6.17    # HEAD 2a624399c

# 1.3 Config
cp /boot/config-6.17.0-23-generic .config
yes "" | make olddefconfig
scripts/config -d MODULE_SIG_KEY                  # avoid signing-key issues
scripts/config -e DEBUG_INFO -e DEBUG_INFO_DWARF5

# 1.4 Build + install via the helper (it auto-reboots into the new kernel)
sudo bash /datadrive/nested_openvmm/build-iteration.sh 1
# (helper does: make bindeb-pkg, dpkg -i, update-grub, grub-reboot, reboot)
```

After reboot, verify the host environment:

```bash
uname -r
# expect: 6.17.13-nested-snp-port-nested-snp-port

# Every CPU should have SYSCFG.SNP_EN (bit 24) set:
sudo modprobe msr
for cpu in $(seq 0 $(($(nproc) - 1))); do
    printf "cpu%d 0xc0010010=0x%s\n" "$cpu" "$(sudo rdmsr -p $cpu 0xc0010010)"
done
# expect: each line has bit 24 set (e.g. 0x1800000)

sudo dmesg | grep -E "SEV-SNP|kvm_amd"
# expect:
#   SEV-SNP: Soft RMP table initialised; SYSCFG.SNP_EN set on all CPUs
#   kvm_amd: SEV-SNP enabled (ASIDs 1 - 64)
```

If any of those fail, **stop here** — the host kernel is the foundation
for everything below.

---

## 2. Build OpenVMM (Chris Oo's SNP branch)

```bash
cd /datadrive/nested_openvmm
git clone https://github.com/haitaohuang/openvmm.git
cd openvmm
git checkout openvmm_nested_snp    # tracks chris-oo/openvmm-snp
# at the time of this doc: HEAD 10d28c05

cargo build --release --bin openvmm
# binary at target/release/openvmm
```

The May 12 sync (`10d28c05`) adds three SNP-functional commits over the
original May 11 "victory" point:

- `7a2a01d7` — `virt_kvm/snp`: discard page-vis mappings on transitions
  (stability fix; recommended even for a single-vCPU smoke test).
- `47900c3b` — `snp`: allow PCIe virtio devices.
- `10d28c05` — comment-only.

---

## 3. Stage the guest payload

You can reuse the OHCL `vmlinux` and the initramfs you built for
Phase 2/3:

```bash
ls -lh \
    /datadrive/nested_openvmm/OHCL-Linux-Kernel/vmlinux \
    /datadrive/nested_openvmm/initramfs.cpio.gz
```

For the SNP demo we typically use the patched Ubuntu kernel image
directly with a more capable initrd (Rust enclave-init binary that
attempts a real SNP `SNP_GET_REPORT` ioctl). The runnable
`run-snp-openvmm.sh` plus all artifacts (`vmlinuz-…`, `initrd`,
rebuilt `openvmm` binary, host-kernel debs) are pre-staged at:

```text
/datadrive/nested_openvmm/snp-artifacts/
├── openvmm                       # built from openvmm_nested_snp
├── vmlinuz-6.17.0-23-generic     # patched L1 kernel reused as L2
├── initrd
└── run-snp-openvmm.sh
```

If you are starting from a clean checkout, that folder is the easiest
on-ramp; otherwise see §5 below for the full hand-roll.

---

## 4. Launch the SNP guest

### Option A — captured-to-file (recommended for autopilot / CI)

```bash
sudo timeout 60 /datadrive/nested_openvmm/snp-artifacts/run-snp-openvmm.sh \
    > /tmp/openvmm-run.log 2>&1
```

> **60 s is the minimum.** SNP `LAUNCH_UPDATE` on the kernel + initrd
> alone runs ~45 s on this hardware before the first vCPU starts.
> Use ≥ 60 s; the demo reaches userspace around 50–55 s.

Expected lines in `/tmp/openvmm-run.log`:

```
Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP
SEV: SNP running at VMPL0.
smp: Bringing up secondary CPUs ...                 # MP works with -p 2
virtio_blk virtio0: 1/0/0 default/read/poll queues  # PCIe virtio-blk
HELLO WORLD APP RUNNING IN SNP GUEST                # or your demo banner
```

### Option B — interactive (richest output, best for first run)

```bash
sudo /datadrive/nested_openvmm/snp-artifacts/run-snp-openvmm.sh
# Watch the guest boot in your terminal. Ctrl-A x to quit, or Ctrl-C twice.
```

### Option C — clean serial-only log (no trace noise)

Edit `run-snp-openvmm.sh` to replace `--com1 console` with
`--com1 file=/datadrive/nested_openvmm/openvmm-serial.log`, then run as
in Option B. The guest serial ends up in `openvmm-serial.log` (~400 lines,
no mesh trace mixed in).

### Pitfalls — these do **not** work

- `... 2>&1 | tee log` — the pipe blocks OpenVMM's mesh-spawned worker
  from emitting most output; you'll see ~50 s of trace logs and *no*
  guest dmesg.
- `sudo timeout 30 ...` — too short; the guest hasn't reached
  userspace yet.
- Running without `sudo` — `KVM_SNP_LAUNCH_*` ioctls need root.

---

## 5. Hand-rolling the launch command (advanced)

The wrapper script boils down to:

```bash
sudo /datadrive/nested_openvmm/snp-artifacts/openvmm \
    --hypervisor kvm \
    --isolation snp \
    --kernel  /datadrive/nested_openvmm/snp-artifacts/vmlinuz-6.17.0-23-generic \
    --initrd  /datadrive/nested_openvmm/snp-artifacts/initrd \
    --cmdline "console=ttyS0 earlyprintk=serial loglevel=7 panic=10 swiotlb=force init=/init" \
    -m 1GB -p 2 \
    --com1 console \
    --virtio-rng-pcie-port \
    --virtio-vsock-pcie-port \
    --disk pcie:image.raw          # optional: PCIe virtio-blk
```

Key flags worth noting:

| Flag | Why |
|------|-----|
| `--hypervisor kvm` | Selects the in-tree KVM backend (no Hyper-V WHP fallback). |
| `--isolation snp` | Drives the `IsolationType::Snp` plumbing on `openvmm-snp`. No `--vtl2` / IGVM required for the direct-kernel path. |
| `--virtio-*-pcie-port` | Legacy PCI virtio fails under SNP (`KVM SNP guest_memfd does not support disks`). PCIe transport is mandatory. The `--virtio-vsock-pcie-port` flag is a 2-line mirror of `--virtio-rng-pcie-port` carried in our fork. |
| `swiotlb=force` (guest cmdline) | Encrypted guest RAM means virtio rings must bounce through shared (decrypted) pages. Without this, the guest hangs at virtio init. |
| `-p 2` | Multi-vCPU works on `eced60b7`+; bumps the AP startup path. |

---

## 6. Confirming SNP is actually active

Inside the guest (drop to shell or rig your init to run these):

```sh
ls /dev/sev-guest                 # exists → SNP guest driver loaded
dmesg | grep -E "SEV|SNP"         # expect: Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP

# Real attestation report (1184 bytes, PSP-signed):
# Build the SNP_GET_REPORT helper or use the `snp-report` binary baked
# into the enclave-init initramfs.
cat /sys/devices/virtual/misc/sev-guest/measurement 2>/dev/null
```

The companion repo's `enclave-init` binary issues
`/dev/sev-guest` `SNP_GET_REPORT` (`ioctl 0xC0205300`) and prints
report version 3, size 1184 bytes, policy `0x30000` over AF_VSOCK to
the host driver.

---

## 7. Known good baselines & artifacts

- **Kernel deb**: `linux-image-6.17.13-nested-snp-port-…_amd64.deb`
  (in the kernel source tree after build #11).
- **Logs**:
  - `/datadrive/nested_openvmm/openvmm-run-20260513T064326Z.log` —
    first successful guest boot (HEAD `eced60b7`, 1 vCPU, no PCIe).
  - `/datadrive/nested_openvmm/openvmm-run-20260513T161202Z-postsync.log`
    — re-test after sync to `10d28c05` (2 vCPUs, PCIe virtio-blk).
- **Archive refs** (preserving dropped candidate patches):
  - `nested-snp-port-6.17-with-b868` (`b33f4a17f`) — soft-RMP fallback
    on WRMSR #GP (dropped after build #10nob868 confirmed it's dead
    code in the happy path).
  - `nested-snp-port-6.17-with-extable` (`3d41cdc9b`) — `virt_rmpupdate`
    extable wrapper (dropped after build #11noextable confirmed the
    wrapper is dead code once SYSCFG.SNP_EN is set per-CPU).
  - `nested-snp-port-6.17-2-patches` (`5fee34c93`) — pre-squash form
    of the `snp_rmptable_init_hv` device_initcall + cpuhp callback.

---

## 8. Known caveats / next steps

- **`SYSCFG.SNP_EN` is sticky.** A warm `systemctl reboot` keeps it
  set; only a cold Azure deallocate clears it. The cpuhp callback in
  `2a624399c` handles both cases idempotently.
- **Don't `grub-set-default` the experimental kernel** — use
  `grub-reboot` (one-shot) so a bad build doesn't strand the VM.
- **Soft-RMP entries**: the shadow is the source of truth for the
  guest-private regions we use, but the real L0 RMP isn't manipulated
  for non-launch operations. Live migration, page sharing, and guest-
  mediated RMP updates are **not** validated.
- **MP** works at HEAD `eced60b7`+; PCIe virtio works at `47900c3b`+;
  IGVM loader on the SNP path is still TODO.
- **Migration/teardown** of the soft RMP allocator is not yet
  exercised — when the guest exits, does the shadow get walked and
  reset? Open.

---

## 9. References

- `docs/HACKATHON_FINDINGS.md` (this directory's parent) — §"Phase 5
  completion" walks through which original blockers were fixed by what.
- `REPORT_nested_snp_openvmm.md` in `haitaohuang/vm_enclave` — full
  post-mortem with all 17 patches and iteration history.
- [`chris-oo/openvmm-snp`](https://github.com/chris-oo/openvmm/tree/openvmm-snp)
  upstream for OpenVMM SNP support.
- `haitaohuang/linux:nested-snp-port-6.17` for the host-kernel patch
  series.
- `haitaohuang/openvmm:openvmm_nested_snp` for the rebuilt OpenVMM.
