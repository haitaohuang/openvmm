# Reproducing Phase 4: OHCL kernel boot under openvmm (no paravisor, no SNP)

This document captures the exact steps used during the hackathon to boot
the **OpenHCL Linux kernel** as a *direct* L2 guest under **openvmm**
using the KVM backend — **no IGVM, no paravisor, no isolation**. It is
the baseline that proves the kernel and the userspace path work before
attempting to layer SEV-SNP on top (the goal of Phase 5).

If you have not built the kernel yet, follow Phase 3 sections 1-6 first
(`docs/hackathon/REPRODUCE_PHASE3.md`). This guide reuses the same
`vmlinux` and `initramfs.cpio.gz` artifacts.

## 0. Prerequisites — what the host VM must already have

* Linux on x86_64 with KVM enabled (`/dev/kvm` accessible — most Azure
  VMs already have this; on the nested-SNP host it is `/dev/kvm`
  group-owned by `kvm`).
* `cargo` 1.95 or newer (rustup recommended).
* The build prereqs for openvmm itself:
  ```bash
  sudo apt-get install -y \
      build-essential pkg-config libssl-dev \
      protobuf-compiler binutils-x86-64-linux-gnu \
      bzip2 git libarchive-tools
  rustup target add x86_64-unknown-linux-musl
  rustup target add x86_64-unknown-none
  ```
* The OHCL `vmlinux` ELF and an initramfs (produced by Phase 3 or
  reused from the artifacts on this VM at
  `/datadrive/nested_openvmm/`).

> openvmm direct kernel boot wants the **ELF `vmlinux`**, not the
> `bzImage`. Passing the bzImage produces
> `linux loader error / elf loader error / invalid file header`.

## 1. Get the openvmm source

```bash
WORK=/datadrive/nested_openvmm
mkdir -p "$WORK"
cd "$WORK"

git clone --branch hackathon-snp-mini-vm \
    https://github.com/haitaohuang/openvmm.git
cd openvmm
```

The `hackathon-snp-mini-vm` branch carries the SNP scaffolding patch.
For Phase 4 the scaffolding is harmless — it only adds new code paths
and does not alter the default direct-boot behavior.

## 2. Restore openvmm build dependencies

openvmm uses a flowey-driven dependency resolver that downloads protoc,
the GitHub CLI, and IGVM release artifacts. Run it once:

```bash
cargo xflowey restore-packages
```

Notes on common failures:

* If it gets stuck on `sudo apt-get install bzip2 git libarchive-tools`
  waiting for a password, install those manually first:
  ```bash
  sudo apt-get install -y bzip2 git libarchive-tools
  ```
  then re-run `cargo xflowey restore-packages`.
* If it fails to find protoc, ensure the symlink it expects is in place:
  ```bash
  mkdir -p .packages/Google.Protobuf.Tools/tools/
  ln -sf /usr/bin/protoc .packages/Google.Protobuf.Tools/tools/protoc
  ```

A successful run prints `=== done! ===` for each step and exits 0.

## 3. Build the openvmm host binary

```bash
cargo build -p openvmm
```

First build is ~3 minutes. Output: `target/debug/openvmm` (~520 MB
debug binary).

## 4. Confirm the artifacts you need

```bash
ls -lh \
    /datadrive/nested_openvmm/OHCL-Linux-Kernel/vmlinux \
    /datadrive/nested_openvmm/initramfs.cpio.gz \
    target/debug/openvmm
```

Expected (rough):

| File | Size | Format |
|------|------|--------|
| `vmlinux` | ~60 MB | ELF 64-bit, `not stripped` |
| `initramfs.cpio.gz` | ~1 MB | gzipped cpio newc |
| `openvmm` | ~520 MB | dynamic ELF |

If `vmlinux` is missing, run `make -j$(nproc)` again in the kernel
tree — it falls out of the same build that produces the bzImage.

## 5. Launch openvmm with direct kernel boot

```bash
KERN=/datadrive/nested_openvmm/OHCL-Linux-Kernel/vmlinux
INITRD=/datadrive/nested_openvmm/initramfs.cpio.gz

cd /datadrive/nested_openvmm/openvmm
sudo ./target/debug/openvmm \
    --kernel  "$KERN" \
    --initrd  "$INITRD" \
    --cmdline "console=ttyS0 earlyprintk=serial loglevel=7 panic=10 init=/init" \
    -m 1GB -p 1 \
    --com1 stderr
```

Flag reference:

| Flag | Meaning |
|------|---------|
| `--kernel <ELF>` | Linux direct-boot kernel image (must be ELF, not bzImage). |
| `--initrd <FILE>` | Initial ramdisk. Mounted as `rootfs` at boot. |
| `--cmdline "..."` | Appended to the kernel command line. openvmm prepends `panic=-1 debug` automatically. |
| `-m 1GB` | Guest RAM size. |
| `-p 1` | One vCPU. Multi-VCPU works too; one keeps logs simple. |
| `--com1 stderr` | Wires the guest COM1 to the openvmm process's stderr so you see the boot. |

Useful additions:

* `--com1 listen=tcp:127.0.0.1:9000` to attach an external terminal.
* `--paused` (`-P`) to start paused — useful for attaching a debugger.
* `--vmbus-vsock-path /tmp/openvmm.vsock` if you build something
  vmbus-aware later.

`sudo` is needed because of `/dev/kvm` group permissions; if your user
is in the `kvm` group you can drop it.

## 6. What success looks like

You'll see openvmm worker logs first (mesh setup, device adds), then
the kernel banner, then our init script:

```
   0.001599963s  INFO worker_new ... action="new"
   0.002186601s  INFO worker_new: openvmm_core::worker::dispatch:  guest RAM config mem_size=0x40000000
[    0.000000] Linux version 6.12.52-g8ff984f739df-dirty ...
[    0.000000] Command line: panic=-1 debug console=ttyS0 earlyprintk=serial loglevel=7 panic=10 init=/init
[    0.000000] Booting paravirtualized kernel on bare hardware
...
[    1.025602] x86/mm: Checked W+X mappings: passed, no W+X pages found.
[    1.028245] Run /init as init process

=============================================
 Hello from SNP-protected mini VM!
 Running OHCL kernel as direct guest
=============================================
[init] Kernel: Linux version 6.12.52-g8ff984f739df-dirty ...

[init] Checking SEV status...
[init] /dev/sev-guest does not exist          <-- expected: NO SNP here

[init] Memory encryption status from dmesg:
                                              <-- expected: empty

=============================================
  HELLO WORLD APP RUNNING IN SNP GUEST
=============================================
[init] Sleeping 5s, then dropping to shell...

BusyBox v1.30.1 (Ubuntu 1:1.30.1-7ubuntu3.1) built-in shell (ash)
/ #
```

> The init script prints the same "SNP-protected" banner regardless of
> whether SNP is actually active. The *real* signals are the absence of
> `/dev/sev-guest` and the empty grep over dmesg for SEV/SNP — both of
> which prove this is a plain VM. (You can edit the init to fail loudly
> if you prefer.)

To exit cleanly: type `poweroff` at the busybox prompt or `Ctrl-C` in
the openvmm process. `init=/init` will not respawn after exit, but the
VM will idle until you kill openvmm.

## 7. Common failure modes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `linux loader error / elf loader error / invalid file header` | You passed `bzImage` to `--kernel` | Pass `vmlinux` (ELF), not the bzImage. |
| `failed to launch vm worker: failed to launch worker: open kvm error` | `/dev/kvm` not accessible | Add user to `kvm` group or run with `sudo`. |
| `Caused by: vtl2 configured but not loading from igvm` | `--isolation` or `--vtl2` was passed without an IGVM file | Drop those flags. The Phase 4 path is plain — no isolation, no VTL2. |
| Hangs at `[    0.xx] x86/fpu` | Kernel ≥ 6.14 hits the host #VC handler bug from gap analysis | Use the 6.12.52 OHCL build. |
| `protoc: not found` during build | Restore-packages failed silently | Re-run `cargo xflowey restore-packages` after installing `bzip2 git libarchive-tools`. |
| Build error `failed to download Google.Protobuf.Tools` | Restore step couldn't reach the network | Place `protoc` manually under `.packages/Google.Protobuf.Tools/tools/protoc`. |

## 8. Customizing the run

### 8.1 Multi-CPU

```bash
sudo ./target/debug/openvmm --kernel "$KERN" --initrd "$INITRD" \
    --cmdline "console=ttyS0 init=/init" \
    -m 2GB -p 2 --com1 stderr
```

OpenVMM brings up secondary CPUs via the standard SMP boot path; the
`smpboot` lines in dmesg should show CPU1 online.

### 8.2 Real serial console in another window

```bash
# Terminal A
sudo ./target/debug/openvmm ... --com1 listen=tcp:127.0.0.1:9000

# Terminal B
nc 127.0.0.1 9000
```

### 8.3 Different rootfs (block device instead of initramfs)

If you have a Linux disk image:

```bash
sudo ./target/debug/openvmm \
    --kernel  "$KERN" \
    --cmdline "console=ttyS0 root=/dev/vda init=/sbin/init" \
    --disk    rootfs.img \
    -m 2GB -p 2 --com1 stderr
```

`--disk` adds a virtio-blk attached device.

## 9. Path forward to Phase 5 (SNP) — ✅ DONE

> **Update 2026-05-13:** Phase 5 has been completed via a separate
> workstream. The end-to-end SNP-with-OpenVMM recipe is in
> [`REPRODUCE_PHASE5.md`](REPRODUCE_PHASE5.md) (this directory) and
> the full post-mortem with all kernel patches is in
> [`REPORT_nested_snp_openvmm.md`](https://github.com/haitaohuang/vm_enclave/blob/main/REPORT_nested_snp_openvmm.md).
> The four-bullet plan below is preserved for historical context;
> in practice the work was unlocked by picking up Chris Oo's
> `openvmm-snp` branch and porting jepio's nested-SNP host-kernel
> series to Ubuntu 25.10.

This Phase 4 path is what we want to extend with SNP. The minimal
deltas from this command line to a (future) working SNP launch:

1. `--isolation snp` to flip the partition into SNP mode.
2. The CLI gate that requires `--vtl2`/IGVM must be relaxed for SNP
   direct-boot (still TBD).
3. Memory backend in `vmm_core/virt_kvm` must allocate guest_memfd
   regions and call `KVM_SET_USER_MEMORY_REGION2` (helpers already
   exist in `vm/kvm/src/lib.rs::sev`).
4. Before the first `KVM_RUN`, run the `KVM_SEV_INIT2`,
   `KVM_SEV_SNP_LAUNCH_START/UPDATE/FINISH` sequence (helpers already
   exist on `Partition`).

See `docs/HACKATHON_FINDINGS.md` §"Phase 5 completion" for how all
four were ultimately addressed.
