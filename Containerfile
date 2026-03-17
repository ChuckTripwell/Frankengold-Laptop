##################################################################################################################################################
### :::::: pull cachyos :::::: ###
##################################################################################################################################################
FROM docker.io/cachyos/cachyos-v3:latest AS cachyos

# :::::: prepare the kernel :::::: 
RUN rm -rf /lib/modules/*
RUN pacman -Sy --noconfirm
RUN pacman -S --noconfirm linux-cachyos-nvidia-open linux-cachyos-headers

##################################################################################################################################################
### :::::: pull ublue-os :::::: ###
##################################################################################################################################################
FROM ghcr.io/ublue-os/bazzite:testing

# :::::: disable countme ( we always disable it anyway, so this  is to save us time. you can enable it if you want... ) :::::: 
RUN sed -i -e s,countme=1,countme=0, /etc/yum.repos.d/*.repo && systemctl mask --now rpm-ostree-countme.timer

# :::::: force distrobox to use a sub-directory for home :::::: 
RUN mkdir -p /usr/share/distrobox/
RUN touch /usr/share/distrobox/distrobox.conf
RUN echo "DBX_CONTAINER_HOME_PREFIX=~/distrobox" >> /usr/share/distrobox/distrobox.conf

# :::::: forcefully remove and replace kernel :::::: 
RUN rm -rf /lib/modules/*
COPY --from=cachyos /lib/modules /lib/modules
COPY --from=cachyos /usr/share/licenses /usr/share/licenses


# ???
RUN curl -Lo /etc/yum.repos.d/_copr_ublue-os-staging.repo https://copr.fedorainfracloud.org/coprs/ublue-os/staging/repo/fedora-"$(rpm -E %fedora)"/ublue-os-staging-fedora-"$(rpm -E %fedora)".repo
RUN dnf5 install -y --allowerasing \
    /rpms/nvidia/libnvidia-cfg-* \
    /rpms/nvidia/libnvidia-fbc-* \
    /rpms/nvidia/libnvidia-gpucomp-* \
    /rpms/nvidia/libnvidia-ml-* \
    /rpms/nvidia/nvidia-libXNVCtrl-5* \
    /rpms/nvidia/nvidia-settings-5* \
    /rpms/nvidia/nvidia-driver-* \
    /rpms/nvidia/nvidia-kmod-common-* \
    /rpms/nvidia/nvidia-modprobe-5* \
    /rpms/nvidia/nvidia-persistenced-5* \
    /rpms/nvidia/xorg-x11* \
    /rpms/nvidia/nvidia-container-toolkit-1* \
    /rpms/nvidia/nvidia-container-toolkit-base-1* \
    /rpms/nvidia/libnvidia-container1-1* \
    /rpms/nvidia/libnvidia-container-tools-1* \
      libva-nvidia-driver supergfxctl \
RUN cp /etc/modprobe.d/nvidia-modeset.conf /usr/lib/modprobe.d/nvidia-modeset.conf

RUN TMPDIR="$(mktemp -d)" && \
    dnf5 download "VK_hdr_layer" --destdir "$TMPDIR" && \
    RPM_FILE=$(ls "$TMPDIR"/*.rpm) && \
    mkdir "$TMPDIR/VK_hdr_layer" && \
    cd "$TMPDIR/VK_hdr_layer" && \
    # Extract RPM
    rpm2cpio "$RPM_FILE" | cpio -idmv && \
    # Libraries
    mkdir -p /usr/lib64/VK_hdr_layer && \
    cp -v usr/lib64/VK_hdr_layer/* /usr/lib64/VK_hdr_layer/ && \
    # Vulkan implicit layer
    mkdir -p /usr/share/vulkan/implicit_layer.d && \
    cp -v usr/share/vulkan/implicit_layer.d/VkLayer_hdr_wsi.*.json \ && \
        /usr/share/vulkan/implicit_layer.d/ && \
    # License & Docs
    mkdir -p /usr/share/licenses/VK_hdr_layer && \
    cp -v usr/share/licenses/VK_hdr_layer/* /usr/share/licenses/VK_hdr_layer/ && \
    mkdir -p /usr/share/doc/VK_hdr_layer && \
    cp -v usr/share/doc/VK_hdr_layer/* /usr/share/doc/VK_hdr_layer/




# test for grub signing
RUN ln -s '/usr/lib/grub/i386-pc' '/usr/lib/grub/x86_64-efi'

# :::::: Set vm.max_map_count for stability/improved gaming performance :::::: 
# :::::: https://wiki.archlinux.org/title/Gaming#Increase_vm.max_map_count :::::: 
RUN echo -e "vm.max_map_count = 2147483642" > /etc/sysctl.d/80-gamecompatibility.conf
#RUN echo "vm.swappiness=10" >> /etc/sysctl.conf
RUN echo "kernel.sched_migration_cost_ns=5000000" >> /etc/sysctl.d/80-gamecompatibility.conf

# :::::: install preformence-related stuff :::::: 
RUN dnf5 -y copr enable bieszczaders/kernel-cachyos-addons
RUN dnf5 -y install --allowerasing scx-scheds scx-tools scxctl cachyos-settings uksmd scx-manager
RUN dnf5 -y copr disable bieszczaders/kernel-cachyos-addons

# :::::: install additional stuff :::::: 
RUN dnf5 -y install --allowerasing install python3-pygame

# :::::: Fix Nvidia GPU ..? :::::: 
RUN mkdir -p /etc/profile.d
#RUN echo "export __NV_PRIME_RENDER_OFFLOAD=1" >> /etc/bash.bashrc
#RUN echo "export __VK_LAYER_NV_optimus=NVIDIA_only" >> /etc/bash.bashrc
#RUN echo "export __GLX_VENDOR_LIBRARY_NAME=nvidia" >> /etc/bash.bashrc

# :::::: SecureBoot stuff :::::: 
RUN dnf5 -y install --allowerasing mokutil sbsigntools
RUN mkdir -p /usr/share/cert
RUN mkdir -p /tmp/cert
COPY MOK.priv /tmp/cert/MOK.priv
COPY build_files/MOK.pem /usr/share/cert/MOK.pem
COPY build_files/sign-kernel.sh /tmp/sign-kernel.sh 
RUN chmod +x /tmp/sign-kernel.sh && /tmp/sign-kernel.sh 

# :::::: refresh akmods so that nvidia drivers actually catch... :::::: 
RUN dnf5 -y install --allowerasing install rpmdevtools akmods

# :::::: slot the kernel into place :::::: 
RUN mkdir -p /var/tmp
RUN printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
      printf 'hostonly=no\nadd_dracutmodules+=" ostree bootc "' | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-modules.conf && \
      sh -c 'export KERNEL_VERSION="$(basename "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)")" && \
      dracut --force --no-hostonly --reproducible --zstd --verbose --kver "$KERNEL_VERSION"  "/usr/lib/modules/$KERNEL_VERSION/initramfs.img"'

#  :::::: finish :::::: 
ENV DRACUT_NO_XATTR=1
RUN bootc container lint
