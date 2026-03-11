#!/usr/bin/env bash

    log "Enabling Nvidia repositories."
    curl -fsSL --retry 5 --create-dirs \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        -o /etc/yum.repos.d/nvidia-container-toolkit.repo
    curl -fsSL --retry 5 --create-dirs \
        https://negativo17.org/repos/fedora-nvidia.repo \
        -o /etc/yum.repos.d/fedora-nvidia.repo
        

    log "Temporarily disabling akmodsbuild script."
    disable_akmodsbuild || exit 1

    log "Building and installing Nvidia kernel module packages."    
    dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=noscripts \
        akmod-nvidia \
        nvidia-kmod-common \
        nvidia-modprobe \
        gcc-c++
    akmods --force --verbose --kernels "${KERNEL_VERSION}" --kmod "nvidia"
    
    # akmods always fails with exit 0 so we have to check explicitly
    FAIL_LOG_GLOB=/var/cache/akmods/nvidia/*-for-${KERNEL_VERSION}.failed.log

    shopt -s nullglob
    FAIL_LOGS=( ${FAIL_LOG_GLOB} )
    shopt -u nullglob

    if (( ${#FAIL_LOGS[@]} )); then
        error "Nvidia akmod build failed"
        for f in "${FAIL_LOGS[@]}"; do
            cat "${f}" || log "Failed to read ${f}"
            log "--------------"
        done
        exit 1
    fi

    log "Restoring akmodsbuild script."
    restore_akmodsbuild

    log "Installing Nvidia userspace packages."
    dnf install -y --setopt=skip_unavailable=1 \
        libva-nvidia-driver \
        nvidia-driver \
        nvidia-persistenced \
        nvidia-settings \
        nvidia-driver-cuda \
        libnvidia-cfg \
        libnvidia-fbc \
        libnvidia-ml \
        libnvidia-gpucomp \
        nvidia-driver-libs.i686 \
        nvidia-driver-cuda-libs.i686 \
        libnvidia-fbc.i686 \
        libnvidia-ml.i686 \
        libnvidia-gpucomp.i686 \
        nvidia-container-toolkit

    log "Cleaning Nvidia repositories."
    rm -f /etc/yum.repos.d/*nvidia*

    log "Installing Nvidia SELinux policy."
    curl -fsSL --retry 5 --create-dirs \
        https://raw.githubusercontent.com/NVIDIA/dgx-selinux/master/bin/RHEL9/nvidia-container.pp \
        -o nvidia-container.pp
    semodule -i nvidia-container.pp
    rm -f nvidia-container.pp

    log "Installing Nvidia container toolkit service and preset."
    install -D -m 0644 /dev/stdin /usr/lib/systemd/system/nvctk-cdi.service <<'EOF'
[Unit]
Description=NVIDIA Container Toolkit CDI auto-generation
ConditionFileIsExecutable=/usr/bin/nvidia-ctk
ConditionPathExists=!/etc/cdi/nvidia.yaml
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

[Install]
WantedBy=multi-user.target
EOF

    install -D -m 0644 /dev/stdin /usr/lib/systemd/system-preset/70-nvctk-cdi.preset <<'EOF'
enable nvctk-cdi.service
EOF

    log "Setting up Nvidia modules."
    install -D -m 0644 /dev/stdin /etc/modprobe.d/nvidia.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
EOF

    log "Setting up GPU modules for initramfs."
    install -D -m 0644 /dev/stdin /usr/lib/dracut/dracut.conf.d/99-nvidia.conf <<'EOF'
# Force the i915 amdgpu nvidia drivers to the ramdisk
force_drivers+=" i915 amdgpu nvidia nvidia_drm nvidia_modeset nvidia_peermem nvidia_uvm "
EOF

    log "Injecting Nvidia kernel args"
    install -D -m 0644 /dev/stdin /usr/lib/bootc/kargs.d/90-nvidia.toml <<'EOF'
kargs = [
"rd.driver.blacklist=nouveau",
"modprobe.blacklist=nouveau",
"rd.driver.pre=nvidia",
"nvidia-drm.modeset=1",
"nvidia-drm.fbdev=1"
]
EOF
