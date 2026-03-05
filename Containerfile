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



















# STEP: create ublue-os folder and pre-reboot script
RUN mkdir -p /etc/ublue-os && \
    cat > /etc/ublue-os/pre-reboot-sign.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

REPO="/sysroot/ostree/repo"
WORKDIR="/tmp/signing"

BOOTED_LINE=$(ostree admin status | grep '*')
BRANCH=$(echo "$BOOTED_LINE" | awk '{print ($1=="*")?$2:$1}')
COMMIT=$(echo "$BOOTED_LINE" | awk '{print ($1=="*")?$3:$2}')
CLEAN_COMMIT="${COMMIT%%.*}"

rm -rf "$WORKDIR"

# Find kernel paths inside the commit
KERNELS=$(ostree ls "$CLEAN_COMMIT" /usr/lib/modules | awk '/vmlinuz/ {print $NF}')

for k in $KERNELS; do
    SRC="/usr/lib/modules/$k/vmlinuz"
    DST="$WORKDIR/vmlinuz-$k"

    ostree cat "$CLEAN_COMMIT" "$SRC" > "$DST"
    sbctl sign -s "$DST"

    echo "✓ Signed $SRC"
done

# Build minimal overlay tree
mkdir -p "$WORKDIR/tree/usr/lib/modules"

for k in $KERNELS; do
    mkdir -p "$WORKDIR/tree/usr/lib/modules/$k"
    mv "$WORKDIR/vmlinuz-$k" "$WORKDIR/tree/usr/lib/modules/$k/vmlinuz"
done

ostree commit \
    --repo="$REPO" \
    --branch="$BRANCH" \
    --parent="$CLEAN_COMMIT" \
    --tree=ref="$CLEAN_COMMIT" \
    --tree=dir="$WORKDIR/tree" \
    --subject="Signed kernels ($(date))"

ostree admin deploy "$BRANCH"

echo "Deployment ready. Reboot to use signed kernels."
SCRIPT

RUN chmod +x /etc/ublue-os/post-reboot.sh






RUN mkdir -p /etc/systemd/system /etc/systemd/system/multi-user.target.wants && \
cat <<'EOF' > /etc/systemd/system/ostree-deploy-watch.path
[Unit]
Description=Watch for new OSTree deployments

[Path]
PathModified=/sysroot/ostree/deploy

[Install]
WantedBy=multi-user.target
EOF
cat <<'EOF' > /etc/systemd/system/ostree-deploy-watch.service
[Unit]
Description=Run signing script after OSTree deployment

[Service]
Type=oneshot
ExecStart=/etc/ublue-os/pre-reboot-sign.sh
EOF

RUN systemctl enable ublue-pre-reboot.service




RUN cat > /etc/systemd/system/ublue-post-boot.service <<'SERVICE'
[Unit]
Description=Run post-reboot script after system boot
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/etc/ublue-os/post-reboot.sh
User=root
Group=root
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
SERVICE

RUN systemctl enable ublue-post-boot.service









































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
