#!/usr/bin/env bash
set -euo pipefail

########################################
# Globals
########################################
LOG_FILE="/var/log/arch-install.log"
DRY_RUN=false

########################################
# Argument parsing
########################################
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "⚠️  DRY-RUN MODE ENABLED — no changes will be made"
fi

########################################
# Logging (console + file)
########################################
mkdir -p /var/log
exec > >(tee -a "$LOG_FILE") 2>&1

########################################
# Helpers
########################################
info() {
  echo -e "\e[32m==>\e[0m $1"
}

warn() {
  echo -e "\e[33mWARNING:\e[0m $1"
}

error() {
  echo -e "\e[31mERROR:\e[0m $1"
  umount -R /mnt || true
  cryptsetup close cryptlvm || true
  exit 1
}

confirm() {
  read -rp "$1 [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

run() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

########################################
# Auto-cleanup on unexpected exit
########################################
trap 'warn "Unexpected error, cleaning up..."; umount -R /mnt || true; cryptsetup close cryptlvm || true' ERR


########################################
# Internet check
########################################
info "Checking internet connection"
ping -c 1 archlinux.org &>/dev/null || error "No internet connection"

########################################
# Time sync
########################################
run "timedatectl set-ntp true"

########################################
# Disk selection
########################################
lsblk
read -rp "Enter disk (e.g. /dev/sda): " DISK
[[ -b "$DISK" ]] || error "Invalid disk: $DISK"

EFI_SIZE="2G"
ROOT_SIZE="200G"

EFI_PART="${DISK}1"
LUKS_PART="${DISK}2"

########################################
# Preflight summary
########################################
clear
echo "========================================="
echo " ARCH LINUX INSTALLATION PREFLIGHT"
echo "========================================="
echo
echo " Disk            : $DISK"
echo " EFI partition   : $EFI_SIZE  (FAT32)"
echo " Root LV         : $ROOT_SIZE (ext4)"
echo " Home LV         : Remaining (~$(blockdev --getsize64 "$DISK") bytes - 200G - 2G) (ext4)"
echo " Encryption      : LUKS + LVM"
echo " Boot mode       : UEFI"
echo " Dry-run         : $DRY_RUN"
echo
echo " ⚠️  ALL DATA ON THIS DISK WILL BE LOST"
echo
confirm "Proceed with installation?" || exit 0

########################################
# Disk wipe (signatures only)
########################################
info "Wiping old disk signatures"
run "wipefs -a $DISK"

########################################
# Partitioning
########################################
info "Partitioning disk"
run "parted -s $DISK mklabel gpt"
run "parted -s $DISK mkpart ESP fat32 1MiB 2049MiB"
run "parted -s $DISK set 1 esp on"
run "parted -s $DISK mkpart primary 2049MiB 100%"

########################################
# Filesystems
########################################
info "Formatting EFI partition"
run "mkfs.fat -F32 $EFI_PART"

########################################
# LUKS
########################################
info "Setting up LUKS encryption"
run "cryptsetup luksFormat $LUKS_PART"
run "cryptsetup open $LUKS_PART cryptlvm"

########################################
# LVM
########################################
info "Creating LVM layout"
run "pvcreate /dev/mapper/cryptlvm"
run "vgcreate vg0 /dev/mapper/cryptlvm"
run "lvcreate -L $ROOT_SIZE vg0 -n root"
run "lvcreate -l 100%FREE vg0 -n home"

########################################
# Filesystems on LVM
########################################
run "mkfs.ext4 /dev/vg0/root"
run "mkfs.ext4 /dev/vg0/home"

########################################
# Mounting
########################################
run "mount /dev/vg0/root /mnt"
run "mkdir -p /mnt/home"
run "mount /dev/vg0/home /mnt/home"
run "mkdir -p /mnt/boot"
run "mount $EFI_PART /mnt/boot"

########################################
# Mirrors
########################################
info "Configuring mirrors"
run "pacman -Sy --noconfirm reflector"
run "cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup"

run "reflector \
  --country Bangladesh,India,Singapore \
  --latest 10 \
  --protocol https \
  --sort rate --fastest 5 \
  --save /etc/pacman.d/mirrorlist"

########################################
# Base install
########################################
info "Installing base system"
run "pacstrap -K /mnt \
  base linux linux-firmware sof-firmware intel-ucode base-devel \
  grub efibootmgr networkmanager vim \
  lvm2 cryptsetup"

########################################
# fstab
########################################
info "Generating fstab"
run "genfstab -U /mnt > /mnt/etc/fstab"

########################################
# Chroot script
########################################
UUID=$(blkid -s UUID -o value "$LUKS_PART")

cat <<EOF > /mnt/chroot-setup.sh
#!/usr/bin/env bash
set -euo pipefail

echo "Logging to /var/log/arch-install.log" >> /var/log/arch-install.log
exec >> /var/log/arch-install.log 2>&1

read -rp "Timezone (default Asia/Dhaka): " TZ
TZ=\${TZ:-Asia/Dhaka}
ln -sf /usr/share/zoneinfo/\$TZ /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

read -rp "Hostname: " HOSTNAME
echo "\$HOSTNAME" > /etc/hostname

sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo "Set root password"
passwd

read -rp "New username: " USERNAME
useradd -m -G wheel -s /bin/bash "\$USERNAME"
passwd "\$USERNAME"

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="cryptdevice=UUID=$UUID:cryptlvm root=/dev/vg0/root"|' /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

mkdir -p /boot/EFI/BOOT
cp /boot/EFI/GRUB/grubx64.efi /boot/EFI/BOOT/BOOTX64.EFI

efibootmgr -c -d "$DISK" -p 1 \
  -L "Arch Linux" \
  -l '\\EFI\\GRUB\\grubx64.efi'
EOF

run "chmod +x /mnt/chroot-setup.sh"

########################################
# Chroot execution
########################################
if ! $DRY_RUN; then
  arch-chroot /mnt /chroot-setup.sh
fi

run "umount -R /mnt || true"
run "cryptsetup close cryptlvm || true"

########################################
# Finish
########################################
info "Installation completed successfully"
warn "Log file saved at $LOG_FILE"
warn "You may now reboot"
confirm "Reboot now?" && run "reboot"