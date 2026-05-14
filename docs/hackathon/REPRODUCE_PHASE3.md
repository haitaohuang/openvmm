# Reproducing Phase 3: OHCL kernel boot inside an SNP mini VM (QEMU)

This document captures the exact steps used during the hackathon to boot
the **OpenHCL Linux kernel** as the *guest* of an **SEV-SNP protected
mini VM** under QEMU, with **no paravisor** inside the VM. It assumes
you are on an Azure VM that itself has nested SEV-SNP enabled (the L1
"jepio-style" host).

## 0. Prerequisites — what the host VM must already have

These are properties of the L1 Azure host VM and are not installed by
this guide:

* AMD EPYC CPU with `sev`, `sev_es`, `sev_snp` flags
  (`grep -m1 -o 'sev[_a-z]*' /proc/cpuinfo` should print `sev sev_es sev_snp`).
* Host kernel with SEV-SNP host support and `/dev/sev` present
  (`ls -l /dev/sev` returns `crw-------`).
* `/sys/module/kvm_amd/parameters/sev_snp` reads `Y`.
* `/sys/module/kvm/parameters/nested` reads `1`.
* `/usr/local/bin/qemu-system-x86_64` is **QEMU 9.2.0** with SEV-SNP
  support compiled in (the upstream `target/i386/sev.c` path).
  Verify: `/usr/local/bin/qemu-system-x86_64 --version`.
* OVMF firmware files at `/usr/local/share/qemu/OVMF_CODE.fd` and
  `/usr/local/share/qemu/OVMF_VARS.fd`. Build with `-DBUILD_RANGES=ON
  -DCONFIG_SEV=ON` if you build from source.

If `/dev/sev` is root-only, add yourself to a group or run the QEMU
command with `sudo` (this guide uses `sudo`).

## 1. Install build prerequisites

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential bison flex bc cpio rsync \
    libssl-dev libelf-dev libncurses5-dev \
    busybox-static \
    binutils-x86-64-linux-gnu
```

The host already has `git` and `gcc`. We need `busybox-static` for the
initramfs and the rest for the kernel build.

## 2. Get a working data directory

The OHCL kernel build needs ~25 GB. Mount a data drive if `/` is small.
The example below uses `/datadrive`:

```bash
# Pick a large filesystem
WORK=/datadrive/nested_openvmm
mkdir -p "$WORK"
cd "$WORK"
```

## 3. Clone the patched OHCL kernel branch

The hackathon branch carries 4 small build fixes plus the SNP PMU
workaround on top of the OHCL `kvm-nested` branch (6.12.52 base).

```bash
cd "$WORK"
git clone --branch hackathon-snp-mini-vm --depth 1 \
    https://github.com/haitaohuang/OHCL-Linux-Kernel.git
cd OHCL-Linux-Kernel
```

If you prefer to apply the fixes yourself, start from the `kvm-nested`
branch and cherry-pick commit `30ea0e02` from `hackathon-snp-mini-vm`.

## 4. Configure the kernel

Start from the upstream `x86_64_defconfig` and add what we need for an
SEV-SNP guest plus the virt I/O it expects:

```bash
make x86_64_defconfig

cat <<'EOF' >> .config
# SEV-SNP guest support
CONFIG_AMD_MEM_ENCRYPT=y
CONFIG_AMD_MEM_ENCRYPT_ACTIVE_BY_DEFAULT=y
CONFIG_SEV_GUEST=y
CONFIG_X86_CPUID=y
CONFIG_X86_MSR=y

# Console / init essentials
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y

# Optional virtio (only if you plan to attach virtio disks/nics)
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_MMIO=y

# Hyper-V is supported but VTL mode must stay OFF (no paravisor here)
CONFIG_HYPERV=y
# CONFIG_HYPERV_VTL_MODE is not set
EOF

make olddefconfig
```

> The hackathon branch already contains the source-level workarounds
> needed when `CONFIG_HYPERV_VTL_MODE` is off. If you start from another
> tree, you may hit `get_vtl` / `cpu_boot_mask` / `u128` build errors —
> see `HACKATHON_FINDINGS.md` for descriptions.

## 5. Build the kernel

```bash
make -j"$(nproc)" bzImage
```

Output: `arch/x86/boot/bzImage` (~13 MB). For openvmm direct boot you
also need `vmlinux` (the ELF), produced as a side effect.

## 6. Build a tiny initramfs with a hello-world init

The guest needs an init that proves SNP is active. Save this as a
script and run it:

```bash
cd "$WORK"
mkdir -p initramfs/{bin,sbin,proc,sys,dev}

# Pull in busybox and symlink the standard tools.
cp /usr/bin/busybox initramfs/bin/busybox
cd initramfs/bin
for f in sh ls cat echo mount mkdir grep dmesg sleep ps uname stat; do
    ln -sf busybox "$f"
done
cd "$WORK"

cat > initramfs/init <<'EOF'
#!/bin/sh
/bin/mount -t proc  proc  /proc
/bin/mount -t sysfs sys   /sys
/bin/mount -t devtmpfs dev /dev 2>/dev/null

echo
echo "============================================="
echo " Hello from SNP-protected mini VM!"
echo " Running OHCL kernel as direct guest"
echo "============================================="
echo "[init] Kernel: $(uname -a)"
echo
echo "[init] Checking SEV status..."
if [ -e /dev/sev-guest ]; then
    echo "[init] /dev/sev-guest EXISTS - SNP attestation available!"
else
    echo "[init] /dev/sev-guest does not exist"
fi
echo
echo "[init] Memory encryption status from dmesg:"
dmesg | grep -iE "memory encryption|SEV|SNP" | head -10
echo
echo "============================================="
echo "  HELLO WORLD APP RUNNING IN SNP GUEST"
echo "============================================="
echo "[init] Sleeping 5s, then dropping to shell..."
sleep 5
exec /bin/sh
EOF
chmod +x initramfs/init

# Pack it
( cd initramfs && find . | cpio -o -H newc | gzip -9 ) > initramfs.cpio.gz
ls -lh initramfs.cpio.gz   # ~1 MB
```

The init script in the repo lives at `docs/hackathon/initramfs-init.sh`
and is identical to the heredoc above.

## 7. Launch the SNP mini VM

This is the tested working command. The two `-perfctr-core,-ibpb`
suppressions silence harmless CPUID feature warnings on nested AMD
hosts. The `nopmu`-equivalent workaround is already inside the kernel
patch (`amd_pmu_init` returns early under SNP).

```bash
KERN=/datadrive/nested_openvmm/OHCL-Linux-Kernel/arch/x86/boot/bzImage
INITRD=/datadrive/nested_openvmm/initramfs.cpio.gz

sudo /usr/local/bin/qemu-system-x86_64 \
  -enable-kvm \
  -cpu EPYC-v4,-perfctr-core,-ibpb \
  -machine q35,confidential-guest-support=sev0 \
  -smp 1 -m 1024M -no-reboot \
  -drive if=pflash,format=raw,unit=0,file=/usr/local/share/qemu/OVMF_CODE.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/usr/local/share/qemu/OVMF_VARS.fd \
  -kernel  "$KERN" \
  -initrd  "$INITRD" \
  -append "console=ttyS0 earlyprintk=serial loglevel=7 panic=10 init=/init" \
  -object  sev-snp-guest,id=sev0,cbitpos=51,reduced-phys-bits=1 \
  -object  memory-backend-memfd,id=ram1,size=1024M,share=true \
  -machine memory-backend=ram1 \
  -display none -serial stdio -monitor none
```

Notes on the flags:

| Flag | Why |
|------|-----|
| `-cpu EPYC-v4` | Smallest CPU model that exposes SNP-required leaves on this host. |
| `-perfctr-core,-ibpb` | Drops two CPUID features the nested host does not expose; suppresses warnings. |
| `-machine q35,confidential-guest-support=sev0` | Wires the `sev-snp-guest` object into the machine. |
| `-object sev-snp-guest,...,cbitpos=51,reduced-phys-bits=1` | EPYC encryption bit position; mandatory. |
| `-object memory-backend-memfd,share=true` + `-machine memory-backend=ram1` | Required for `KVM_CREATE_GUEST_MEMFD` private RAM. |
| `-kernel/-initrd/-append` | Direct kernel boot (no GRUB, no UEFI shell). |
| `-serial stdio` | Console comes back to your terminal. |

If you want a log file instead of the terminal:

```bash
sudo ... -display none -serial file:/tmp/qemu_snp.log -monitor none &
sleep 30
sudo tail -60 /tmp/qemu_snp.log
```

## 8. What success looks like

The serial output will show OVMF reporting SEV/SNP, then the kernel
banner, then our init script:

```
SEV is enabled (mask 0x8000000000000)
SEV-ES is enabled, 2 GHCB pages allocated starting at 0x3FEF2000
Loading driver at 0x0003F161000 EntryPoint=0x0003F1636D9 AmdSevDxe.efi
Loading driver at 0x0003D130000 EntryPoint=0x0003D135330 SnpDxe.efi
...
[    0.354815] Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP
[    0.355693] SEV: Status: SEV SEV-ES SEV-SNP
[    0.466311] amd_pmu: disabled in SEV-SNP guest (nested SNP hack)
[    0.505271] SEV: Using SNP CPUID table, 31 entries present.
[    0.505798] SEV: SNP running at VMPL0.
[    1.037949] SEV: SNP guest platform device initialized.
[    1.359644] sev-guest sev-guest: Initialized SEV guest driver
...
[    1.603874] Run /init as init process

=============================================
 Hello from SNP-protected mini VM!
 Running OHCL kernel as direct guest
=============================================
[init] Kernel: Linux version 6.12.52-g8ff984f739df-dirty ...
[init] Checking SEV status...
[init] /dev/sev-guest EXISTS - SNP attestation available!
...
=============================================
  HELLO WORLD APP RUNNING IN SNP GUEST
=============================================

BusyBox v1.30.1 ... built-in shell (ash)
/ #
```

You are now in an interactive shell inside an SEV-SNP-protected mini VM
running an OHCL kernel with no paravisor. From here you can run a real
attestation request:

```sh
/ # cat /sys/devices/virtual/misc/sev-guest/measurement 2>/dev/null
```

Press `Ctrl-A x` to terminate the QEMU process.

## 9. Common failure modes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `qemu-system-x86_64: invalid object type: sev-snp-guest` | QEMU lacks SNP support | Use `/usr/local/bin/qemu-system-x86_64` (9.2.0); not the distro `/usr/bin/qemu-system-x86_64`. |
| `kvm_init_vm: unsupported VM type` | Host kernel lacks `KVM_X86_SNP_VM` | Ensure host is the SNP-host kernel. |
| `Kernel panic — SNP: Hypervisor requested exception ... check_hw_exists` | AMD PMU MSR; host #VC handler returns ES_VMM_ERROR | Use the hackathon kernel branch (the `amd_pmu_init` patch is the fix). |
| `[    0.xx] x86/fpu` then hang | Kernel ≥ 6.14 hits a different host-side #VC bug | Stay on 6.12.52 (this branch). Newer kernels need a host fix. |
| `Memory fault: GPA 0xc0000` warning | OVMF probing video BIOS | Harmless, ignore. |
| `host doesn't support requested feature: CPUID.80000001H:ECX.perfctr-core [bit 23]` | Host doesn't expose that bit | Add `-perfctr-core,-ibpb` to `-cpu`. |

## 10. Variant: running the same kernel under openvmm (no SNP)

The same `vmlinux` ELF will boot under openvmm without isolation:

```bash
cd /datadrive/nested_openvmm/openvmm
cargo build -p openvmm    # only needed once
sudo ./target/debug/openvmm \
    --kernel /datadrive/nested_openvmm/OHCL-Linux-Kernel/vmlinux \
    --initrd /datadrive/nested_openvmm/initramfs.cpio.gz \
    --cmdline "console=ttyS0 earlyprintk=serial loglevel=7 panic=10 init=/init" \
    -m 1GB -p 1 \
    --com1 stderr
```

You will reach the busybox shell, but `/dev/sev-guest does not exist`
because **mainline** openvmm cannot launch SNP guests.

> **Update 2026-05-13:** A separate workstream has since enabled
> SNP **under openvmm** by using Chris Oo's `openvmm-snp` branch
> together with a patched Hyper-V-aware host kernel. See
> [`REPRODUCE_PHASE5.md`](REPRODUCE_PHASE5.md) for the recipe and
> `HACKATHON_FINDINGS.md` §"Phase 5 completion" for the post-mortem.
