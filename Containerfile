##################################################################################################################################################
### :::::: create a ctx :::::: ###
##################################################################################################################################################
FROM scratch AS ctx
COPY build_files /

##################################################################################################################################################
### :::::: pull cachyos :::::: ###
##################################################################################################################################################
FROM docker.io/cachyos/cachyos-v3:latest AS cachyos

# :::::: prepare the kernel :::::: 
RUN rm -rf /lib/modules/*
RUN pacman -Sy --noconfirm
RUN pacman -S --noconfirm linux-cachyos-lto

##################################################################################################################################################
### :::::: pull ublue-os :::::: ###
##################################################################################################################################################
FROM ghcr.io/ublue-os/bazzite-nvidia-open:latest

# :::::: disable countme ( we always disable it anyway, so this  is to save us time. you can enable it if you want... ) :::::: 
RUN sed -i -e s,countme=1,countme=0, /etc/yum.repos.d/*.repo && systemctl mask --now rpm-ostree-countme.timer

# :::::: force distrobox to use a sub-directory for home :::::: 
RUN mkdir -p /usr/share/distrobox/
RUN touch /usr/share/distrobox/distrobox.conf
RUN echo "DBX_CONTAINER_HOME_PREFIX=~/distrobox" >> /usr/share/distrobox/distrobox.conf

# :::::: forcefully remove and replace kernel :::::: 
RUN rm -rf /usr/lib/modules
COPY --from=cachyos /usr/lib/modules /usr/lib/modules
COPY --from=cachyos /usr/share/licenses /usr/share/licenses

# test for grub signing
RUN ln -s '/usr/lib/grub/i386-pc' '/usr/lib/grub/x86_64-efi'

# :::::: refresh akmods so that nvidia drivers actually catch... :::::: 
RUN dnf5 -y install --allowerasing install rpmdevtools akmods jq

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

# :::::: SecureBoot stuff :::::: 
#RUN dnf5 -y install --allowerasing mokutil sbsigntools
#
#RUN mkdir -p /usr/share/cert
#COPY MOK.priv /tmp/cert/MOK.priv
#
#COPY --from=ctx MOK.pem /usr/share/cert/MOK.pem
#
#COPY --from=ctx sign-kernel.sh /tmp/sign-kernel.sh 
#RUN chmod +x /tmp/sign-kernel.sh && /tmp/sign-kernel.sh 
#
#COPY --from=ctx sign-akmods.sh /tmp/sign-akmods.sh 
#RUN chmod +x /tmp/sign-akmods.sh && /tmp/sign-akmods.sh 



#RUN akmods --force --kernels $(ls /usr/lib/modules/*)
#RUN dracut -force --kver $(ls /usr/lib/modules/*)

RUN dnf5 -y install --allowerasing kernel-devel




RUN KERNEL_NAME=$(ls /usr/lib/modules | sort -V | tail -n 1) && \
    OLD_KVER=$(ls /usr/lib/modules | grep -v "${KERNEL_NAME}" | head -n 1) && \
    echo "Refreshing Nvidia drivers from ${OLD_KVER} to ${KERNEL_NAME}" && \
    \
    # 1. Create the destination directory in the new kernel tree
    mkdir -p "/usr/lib/modules/${KERNEL_NAME}/extra/nvidia" && \
    \
    # 2. Copy the existing pre-compiled modules from the previous kernel
    # This assumes they were already built into the base image
    cp /usr/lib/modules/${OLD_KVER}/extra/nvidia/*.ko "/usr/lib/modules/${KERNEL_NAME}/extra/nvidia/" 2>/dev/null || \
    cp /usr/lib/modules/*/extra/nvidia/*.ko "/usr/lib/modules/${KERNEL_NAME}/extra/nvidia/" || true && \
    \
    # 3. Update the module dependency list for the new kernel
    # This makes the kernel 'aware' of the moved drivers
    depmod -a "${KERNEL_NAME}" && \
    \
    # 4. Refresh the initrd inside the module directory (safe for atomic build)
    dracut --kver "${KERNEL_NAME}" -f "/usr/lib/modules/${KERNEL_NAME}/initrd"






# :::::: slot the kernel into place :::::: 
RUN mkdir -p /var/tmp
RUN printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
      printf 'hostonly=no\nadd_dracutmodules+=" ostree bootc "' | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-modules.conf && \
      sh -c 'export KERNEL_VERSION="$(basename "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)")" && \
      dracut --force --no-hostonly --reproducible --zstd --verbose --kver "$KERNEL_VERSION"  "/usr/lib/modules/$KERNEL_VERSION/initramfs.img"'

#  :::::: finish :::::: 
ENV DRACUT_NO_XATTR=1
RUN bootc container lint
