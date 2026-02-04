Ã# OpenClaw VM

This repository contains tools for spinning up openclaw in a VM
which is being started in qemu.

This is work in progress. Following functionality is planned:
* create a VM based on ubuntu-24.04 and the default user "claw"
* the VM needs nodejs installed in v22 or higher
* nodejs should install dependencies in the user directory, not at system level in order to prevent permission problems
* in the user's HOME we check out the openclaw github repository, the latest stable branch, install dependencies and build openclaw (locally)
* scripts for backing up the state of the agent and restoring them shall be available
* the OS in the VM shall run headless, with a vnc based X11 server which shall be accessible from localhost, only

