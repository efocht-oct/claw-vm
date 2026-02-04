#!/bin/bash

# --- CONFIGURATION ---
CONTAINER_NAME="ubuntu-ai-vm"
IMAGE="docker.io/library/ubuntu:24.04"
HOST_SHARE_DIR="/home/$USER/ai_projects"
GUEST_MOUNT_POINT="/home/user/ai_projects"

# --- 1. PRE-FLIGHT CHECKS ---
mkdir -p "$HOST_SHARE_DIR"

if ! command -v podman &> /dev/null; then
    echo "Podman not found. Installing..."
    sudo apt update && sudo apt install -y podman
fi

# --- 2. CONTAINER LOGIC ---
if podman container exists "$CONTAINER_NAME"; then
    echo "Resuming existing container '$CONTAINER_NAME'..."
    
    # Ensure it's running
    if ! podman container inspect -f '{{.State.Running}}' "$CONTAINER_NAME" > /dev/null 2>&1; then
        podman start "$CONTAINER_NAME"
    fi

else
    echo "Spinning up NEW Ubuntu 24.04 container..."
    
    # 1. Create and Start the container in background (-dt)
    # --userns=keep-id: Maps your host user to the container user (User 1000)
    # --device /dev/kfd | /dev/dri: Hardware access for Strix Halo
    podman run -dt \
      --name "$CONTAINER_NAME" \
      --network host \
      --userns=keep-id \
      --device /dev/kfd \
      --device /dev/dri \
      --security-opt label=disable \
      -v "$HOST_SHARE_DIR:$GUEST_MOUNT_POINT" \
      -w "$GUEST_MOUNT_POINT" \
      "$IMAGE" \
      /bin/bash

    echo "Container started. Provisioning 'VM-like' environment..."
    
    # 2. PROVISIONING STEP (Run as Root inside container)
    # Ubuntu images are stripped down. We need to install sudo and give your user rights.
    podman exec -u 0 -it "$CONTAINER_NAME" bash -c "
        apt-get update
        apt-get install -y sudo nano git wget python3 python3-pip
        
        # Determine the user name inside (created by keep-id)
        USER_NAME=\$(id -un 1000)
        
        # Add passwordless sudo for this user
        echo \"\$USER_NAME ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/ai_user
        chmod 0440 /etc/sudoers.d/ai_user
        
        echo 'Provisioning complete.'
    "
fi

# --- 3. ENTER THE VM ---
echo ""
echo "-------------------------------------------------------"
echo "Entering Ubuntu 24.04 AI Environment."
echo " * State is saved automatically."
echo " * Use 'sudo apt install ...' to add packages."
echo " * Files in $GUEST_MOUNT_POINT are shared with host."
echo "-------------------------------------------------------"

# Enter as your normal user (not root)
podman exec -it "$CONTAINER_NAME" /bin/bash
