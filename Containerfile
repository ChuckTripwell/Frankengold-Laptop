##################################################################################################################################################
### :::::: pull cachyos :::::: ###
##################################################################################################################################################
FROM docker.io/cachyos/cachyos-v3:latest AS cachyos

# :::::: prepare the kernel :::::: 
RUN rm -rf /lib/modules/*
RUN pacman -Sy --noconfirm
RUN pacman -S --noconfirm linux-cachyos-bore-nvidia-open


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



# :::::: SecureBoot stuff :::::: 
RUN dnf5 -y install --allowerasing sbsigntools jq

RUN mkdir -p /etc/secureboot_keys
COPY MOK.pem /etc/secureboot_keys/
COPY MOK.der /etc/secureboot_keys/

RUN echo '[Unit]' > /etc/systemd/system/add-mok-key.service
RUN echo 'Description=Add MOK Key Using mokutil' >> /etc/systemd/system/add-mok-key.service
RUN echo 'After=local-fs.target' >> /etc/systemd/system/add-mok-key.service
RUN echo '' >> /etc/systemd/system/add-mok-key.service
RUN echo '[Service]' >> /etc/systemd/system/add-mok-key.service
RUN echo 'Type=oneshot' >> /etc/systemd/system/add-mok-key.service
RUN echo 'mokutil --timeout -1 & echo -e "universalblue\nuniversalblue" | mokutil --import /etc/secureboot_keys/MOK.der' >> /etc/systemd/system/add-mok-key.service
RUN echo 'RemainAfterExit=yes' >> /etc/systemd/system/add-mok-key.service
RUN echo '' >> /etc/systemd/system/add-mok-key.service
RUN echo '[Install]' >> /etc/systemd/system/add-mok-key.service
RUN echo 'WantedBy=multi-user.target' >> /etc/systemd/system/add-mok-key.service

RUN systemctl enable /etc/systemd/system/add-mok-key.service




# :::::: slot the kernel into place :::::: 
RUN mkdir -p /var/tmp
RUN printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
      printf 'hostonly=no\nadd_dracutmodules+=" ostree bootc "' | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-modules.conf && \
      sh -c 'export KERNEL_VERSION="$(basename "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)")" && \
      dracut --force --no-hostonly --reproducible --zstd --verbose --kver "$KERNEL_VERSION"  "/usr/lib/modules/$KERNEL_VERSION/initramfs.img"'

#  :::::: finish :::::: 
ENV DRACUT_NO_XATTR=1
RUN bootc container lint
