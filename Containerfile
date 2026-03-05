##################################################################################################################################################
### :::::: pull cachyos :::::: ###
##################################################################################################################################################
FROM docker.io/cachyos/cachyos-v3:latest AS cachyos

# :::::: prepare the kernel :::::: 
RUN rm -rf /lib/modules/*
RUN pacman -Sy --noconfirm
RUN pacman -S --noconfirm linux-cachyos-nvidia-open
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















RUN mkdir -p /etc/ublue-os || true

RUN echo '#!/usr/bin/env bash ' > /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'set -euo pipefail ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'REPO="/sysroot/ostree/repo" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'WORKDIR="/tmp/signing" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'BOOTED_LINE=$(ostree admin status | grep '\*') ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo "BRANCH=\$(echo \"\$BOOTED_LINE\" | awk '{print (\$1==\"*\")?\$2:\$1}')" >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'COMMIT=$(echo "$BOOTED_LINE" | awk '{print ($1=="*")?$3:$2}') ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'CLEAN_COMMIT="${COMMIT%%.*}" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'rm -rf "$WORKDIR" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '# Find kernel paths inside the commit ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'KERNELS=$(ostree ls "$CLEAN_COMMIT" /usr/lib/modules | awk '/vmlinuz/ {print $NF}') ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'for k in $KERNELS; do ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    SRC="/usr/lib/modules/$k/vmlinuz" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    DST="$WORKDIR/vmlinuz-$k" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    # Extract kernel ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    ostree cat "$CLEAN_COMMIT" "$SRC" > "$DST" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    # Sign it ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    sbctl sign -s "$DST" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    echo "✓ Signed $SRC" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'done ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '# Build minimal overlay tree ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'mkdir -p "$WORKDIR/tree/usr/lib/modules" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'for k in $KERNELS; do ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    mkdir -p "$WORKDIR/tree/usr/lib/modules/$k" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    mv "$WORKDIR/vmlinuz-$k" "$WORKDIR/tree/usr/lib/modules/$k/vmlinuz" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'done ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '# Commit overlay on top of existing commit ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'ostree commit \ ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    --repo="$REPO" \ ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    --branch="$BRANCH" \ ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    --parent="$CLEAN_COMMIT" \ ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    --tree=ref="$CLEAN_COMMIT" \ ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    --tree=dir="$WORKDIR/tree" \ ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo '    --subject="Signed kernels ($(date))" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'ostree admin deploy "$BRANCH" ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo ' ' >> /etc/ublue-os/pre-reboot-sign.sh
RUN echo 'echo "Deployment ready. Reboot to use signed kernels." ' >> /etc/ublue-os/pre-reboot-sign.sh








RUN mkdir -p /etc/ublue-os || true

RUN echo '#!/usr/bin/env bash' > /etc/ublue-os/post-reboot.sh
RUN echo 'set -euo pipefail' >> /etc/ublue-os/post-reboot.sh
RUN echo '' >> /etc/ublue-os/post-reboot.sh
RUN echo 'sbctl-batch-sign && bootc switch ghcr.io/chucktripwell/frankengold-desktop:latest' >> /etc/ublue-os/post-reboot.sh































# Pre-Reboot Service

RUN "echo '[Unit]' > /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo 'Description=Run pre-reboot script after OSTree pull' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo 'After=ostree-finalize-staged.service' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo 'Requires=ostree-finalize-staged.service' >> /etc/systemd/system/ublue-pre-reboot.service"

RUN "echo '' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo '[Service]' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo 'Type=oneshot' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo 'ExecStart=/etc/ublue-os/pre-reboot-sign.sh' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo 'User=root' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo 'Group=root' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo 'RemainAfterExit=yes' >> /etc/systemd/system/ublue-pre-reboot.service"

RUN "echo '' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo '[Install]' >> /etc/systemd/system/ublue-pre-reboot.service"
RUN "echo 'WantedBy=multi-user.target' >> /etc/systemd/system/ublue-pre-reboot.service"

RUN "systemctl enable ublue-pre-reboot.service"










# Post-Reboot Service

RUN "echo '[Unit]' > /etc/systemd/system/ublue-post-boot.service"
RUN "echo 'Description=Run post-reboot script after system boot' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo 'After=network.target' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo 'Wants=network.target' >> /etc/systemd/system/ublue-post-boot.service"

RUN "echo '' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo '[Service]' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo 'Type=oneshot' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo 'ExecStart=/etc/ublue-os/post-reboot.sh' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo 'User=root' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo 'Group=root' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo 'RemainAfterExit=no' >> /etc/systemd/system/ublue-post-boot.service"

RUN "echo '' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo '[Install]' >> /etc/systemd/system/ublue-post-boot.service"
RUN "echo 'WantedBy=multi-user.target' >> /etc/systemd/system/ublue-post-boot.service"

RUN "systemctl enable ublue-post-boot.service"















































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
