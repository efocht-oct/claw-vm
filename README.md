# Hermes Agent VM

This repository contains tools for spinning up Hermes Agent in a VM started via QEMU. It used to run openclaw but now it's geared towards the [hermes agent](https://hermes-agent.nousresearch.com/). Some names and scripts will remind you of openclaw.

Current design goals:
- VM based on Ubuntu 24.04 with default user **claw**
- Node.js **v22+**
- Node/npm installs **in the user HOME** (no system-level npm global installs)
- In the user's HOME we install the hermes agent.
- Scripts for **backup/restore** of agent state are provided (optionally including secrets)
- VM runs headless via QEMU, with per-VM **SSH** and **QEMU VNC** localhost ports

## Usage

### VM manager: `claw-vmctl`

The primary entrypoint is:

```bash
./scripts/claw-vmctl
```

Default base directory:

```bash
$HOME/ubuntu24-qemu-claw
```

Override base directory via:

- `--base-dir <path>` option on every command, or
- `CLAW_VM_BASE_DIR` environment variable.

### Directory layout

```text
<BASE_DIR>/
  base/
    ubuntu-24.04-server-cloudimg-amd64.img
  vms/
    <vm-id>/
      .env
      disk.qcow2
      seed.iso
      user-data
      meta-data
      runtime/
        qemu.pid
        qmp.sock
      logs/
        qemu.log
        serial.log
```

The Ubuntu base image is shared once in `<BASE_DIR>/base/`, while each VM has its own overlay and runtime state.

### Create, build, and start one VM

```bash
# create per-VM config file at <BASE_DIR>/vms/dev1/.env
./scripts/claw-vmctl init dev1

# build shared base image + VM overlay + cloud-init seed
./scripts/claw-vmctl build dev1

# start VM in background
./scripts/claw-vmctl start dev1

# inspect state
./scripts/claw-vmctl status dev1
```

### Create multiple VMs with distinct name/ports

```bash
./scripts/claw-vmctl init dev1 --name noble-claw-dev1 --ssh-port 2222 --vnc-port 5901
./scripts/claw-vmctl init dev2 --name noble-claw-dev2 --ssh-port 2223 --vnc-port 5902

./scripts/claw-vmctl build dev1
./scripts/claw-vmctl build dev2

./scripts/claw-vmctl start dev1
./scripts/claw-vmctl start dev2

./scripts/claw-vmctl list
```

Connect:

```bash
ssh -p 2222 claw@127.0.0.1
ssh -p 2223 claw@127.0.0.1
```

VNC clients:

- VM `dev1` -> `127.0.0.1:5901`
- VM `dev2` -> `127.0.0.1:5902`

### Stop a VM

```bash
./scripts/claw-vmctl stop dev1
```

### Per-VM `.env`

Per-VM config is stored inside the base directory, not globally in `scripts/`:

```text
<BASE_DIR>/vms/<vm-id>/.env
```

See example schema in:

```bash
scripts/.env.example
```

### Legacy wrappers (compatibility)

These wrappers now call `claw-vmctl` for `default` VM:

```bash
./scripts/build_claw_vm.sh
./scripts/start_claw_vm.sh
```

On first run they automatically migrate `scripts/.env` (if present) to:

```text
<BASE_DIR>/vms/default/.env
```

## Backup / Restore

Run backup inside a VM over SSH:

```bash
./scripts/claw-vmctl backup dev1
```

This executes [`backup-hermes.sh`](scripts/backup-hermes.sh) inside the target VM user context and downloads the resulting archive to the host under `./backups` by default.

Set a custom host output directory:

```bash
./scripts/claw-vmctl backup dev1 --out-dir /path/on/host/backups
```

Restore inside a VM over SSH (overwrites files):

```bash
./scripts/claw-vmctl restore dev1 /path/to/hermes-backup-*.tar.gpg
```

If the archive path exists on the host, it is uploaded to the VM temporarily and removed after restore.

## Resize a VM disk

> **Do not** change `DISK_GB` and rerun `build` on an existing VM — the build flow deletes and recreates the overlay disk.

### Minimal recipe (offline)

```bash
# 1) stop the VM
./scripts/claw-vmctl stop dev1

# 2) grow the qcow2 overlay on the host (example: add 20G)
qemu-img resize "$HOME/ubuntu24-qemu-claw/vms/dev1/disk.qcow2" +20G

# 3) start the VM
./scripts/claw-vmctl start dev1

# 4) inside the guest — grow the partition and filesystem
sudo growpart /dev/vda 1
sudo resize2fs /dev/vda1   # ext4; use "sudo xfs_growfs /" for XFS
```

Verify:

```bash
df -h /
lsblk
```

### Notes

- The overlay path follows `<BASE_DIR>/vms/<vm-id>/disk.qcow2`; adjust `BASE_DIR` if you use `--base-dir` or `CLAW_VM_BASE_DIR`.
- Ubuntu 24.04 cloud images use ext4 on `/dev/vda1` by default.
- Online grow (without stopping) is possible via the QMP socket at `runtime/qmp.sock` using `block_resize`, followed by `growpart`/`resize2fs` inside the guest.
