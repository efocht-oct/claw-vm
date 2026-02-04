# OpenClaw VM

This repository contains tools for spinning up OpenClaw in a VM started via QEMU.

Current design goals:
- VM based on Ubuntu 24.04 with default user **claw**
- Node.js **v22+**
- Node/npm installs **in the user HOME** (no system-level npm global installs)
- In the user's HOME we check out the OpenClaw GitHub repository (**stable** branch), install deps and build OpenClaw locally
- Scripts for **backup/restore** of agent state are provided (optionally including secrets)
- VM runs headless, with **XFCE over TigerVNC**, bound to **localhost only** (use SSH tunneling)

## Usage

### Start VM

By default the VM state is stored under `./ubuntu24-qemu`. If your current VM directory is `~/ubuntu24-qemu`, you can reuse it:

Create a `.env` file (optional) by copying the example:

```bash
cp scripts/.env.example scripts/.env
# edit scripts/.env
```

Then build and start:

```bash
cd scripts
./build_claw_vm.sh
./start_claw_vm.sh
```

If the host uses NAT mode (no bridge), SSH will be available via the forwarded port (default 2222).

### Enable VNC inside the VM

After first boot, SSH in and set a VNC password:

```bash
vncpasswd
systemctl --user start vncserver@1
```

On the host, tunnel VNC:

```bash
ssh -L 5901:127.0.0.1:5901 -p 2222 claw@127.0.0.1
```

Then connect your VNC client to `127.0.0.1:5901`.

## Backup / Restore

Encrypted backup including secrets:

```bash
./scripts/backup-openclaw.sh
```

Restore (overwrites files):

```bash
./scripts/restore-openclaw.sh /path/to/openclaw-backup-*.tar.gpg
```

