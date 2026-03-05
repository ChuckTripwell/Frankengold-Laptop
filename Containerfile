##################################################################################################################################################
### :::::: pull cachyos :::::: ###
##################################################################################################################################################
FROM docker.io/cachyos/cachyos-v3:latest AS cachyos

# :::::: prepare the kernel :::::: 
RUN rm -rf /lib/modules/*
RUN pacman -Sy --noconfirm
RUN pacman -S --noconfirm linux-hardened
#linux-cachyos-nvidia-open


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
RUN rm -rf /lib/modules
COPY --from=cachyos /lib/modules /lib/modules
COPY --from=cachyos /usr/share/licenses/ /usr/share/licenses/

# :::::: refresh akmods so that nvidia drivers actually catch... :::::: 
RUN dnf5 -y install rpmdevtools akmods

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
RUN dnf5 -y install python3-pygame

##################################################################################################################################################
### :::::: fixes :::::: ###
##################################################################################################################################################

# :::::: install sbctl to sign some keys later..? ::::::
RUN dnf5 -y copr enable chenxiaolong/sbctl
RUN dnf5 -y install sbctl


# :::::: experimental millennium support :::::: 
#RUN bash -c 'id(){ echo 1000; }; export -f id; curl -fsSL https://steambrew.app/install.sh -o /tmp/install.sh; sed -i "/:: Proceed with installation? \[Y\/n\]/d" /tmp/install.sh; bash /tmp/install.sh'

# test for grub signing
RUN ln -s '/usr/lib/grub/i386-pc' '/usr/lib/grub/x86_64-efi'










# Create ostree-finalize.service
RUN echo "[Unit]" >> /etc/systemd/system/ostree-finalize.service
RUN echo "Description=Finalize staged OSTree deployment and sign bootloader" >> /etc/systemd/system/ostree-finalize.service
RUN echo "Wants=ostree-finalize.path" >> /etc/systemd/system/ostree-finalize.service
RUN echo "After=local-fs.target" >> /etc/systemd/system/ostree-finalize.service
RUN echo "" >> /etc/systemd/system/ostree-finalize.service
RUN echo "[Service]" >> /etc/systemd/system/ostree-finalize.service
RUN echo "Type=oneshot" >> /etc/systemd/system/ostree-finalize.service
RUN echo "ExecStart=/etc/ublue-os/ostree-finalize.sh" >> /etc/systemd/system/ostree-finalize.service

# Create ostree-finalize.path
RUN echo "[Unit]" >> /etc/systemd/system/ostree-finalize.path
RUN echo "Description=Watch /ostree/deploy for new OSTree deployments" >> /etc/systemd/system/ostree-finalize.path
RUN echo "" >> /etc/systemd/system/ostree-finalize.path
RUN echo "[Path]" >> /etc/systemd/system/ostree-finalize.path
RUN echo "PathModified=/ostree/deploy" >> /etc/systemd/system/ostree-finalize.path
RUN echo "Unit=ostree-finalize.service" >> /etc/systemd/system/ostree-finalize.path
RUN echo "" >> /etc/systemd/system/ostree-finalize.path
RUN echo "[Install]" >> /etc/systemd/system/ostree-finalize.path
RUN echo "WantedBy=multi-user.target" >> /etc/systemd/system/ostree-finalize.path

# Create the wrapper script
RUN mkdir -p /etc/ublue-os || true
RUN echo '#!/bin/bash' > /etc/ublue-os/ostree-finalize.sh
RUN echo 'set -euo pipefail' >> /etc/ublue-os/ostree-finalize.sh
RUN echo '' >> /etc/ublue-os/ostree-finalize.sh
RUN echo 'if ostree admin status --verbose | grep -q staged; then' >> /etc/ublue-os/ostree-finalize.sh
RUN echo '    ostree admin finalize-staged' >> /etc/ublue-os/ostree-finalize.sh
RUN echo '    sbctl-batch-sign' >> /etc/ublue-os/ostree-finalize.sh
RUN echo 'fi' >> /etc/ublue-os/ostree-finalize.sh
RUN chmod +x /etc/ublue-os/ostree-finalize.sh

# Enable the path unit
RUN systemctl daemon-reload
RUN systemctl enable ostree-finalize.path





















##################################################################################################################################################
### :::::: fixes end here :::::: ###
##################################################################################################################################################

# :::::: slot the kernel into place :::::: 
RUN mkdir -p /var/tmp
RUN printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
      printf 'hostonly=no\nadd_dracutmodules+=" ostree bootc "' | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-modules.conf && \
      sh -c 'export KERNEL_VERSION="$(basename "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)")" && \
      dracut --force --no-hostonly --reproducible --zstd --verbose --kver "$KERNEL_VERSION"  "/usr/lib/modules/$KERNEL_VERSION/initramfs.img"'

# test 
#RUN sbctl-batch-sign
#RUN sbctl enroll-keys --microsoft


#  :::::: finish :::::: 
ENV DRACUT_NO_XATTR=1
RUN bootc container lint
