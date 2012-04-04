#!/bin/bash

# This script is designed to be run in conjunction with a UEFI boot using Archboot intall media.

# prereqs:
# --------------------
# EFI "BIOS" set to boot *only* from EFI
# successful EFI boot of Archboot USB
# mount /dev/sdb1 /src

set -o nounset
#set -o errexit

# ------------------------------------------------------------------------
# Host specific configuration
# ------------------------------------------------------------------------
# this whole script needs to be customized, particularly disk partitions
# and configuration, but this section contains global variables that
# are used during the system configuration phase for convenience
HOSTNAME=tau
USERNAME=es

# ------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------
# We don't need to set these here but they are used repeatedly throughout
# so it makes sense to reuse them and allow an easy, one-time change if we
# need to alter values such as the install target mount point.

AURHELPER=packer
INSTALL_TARGET="/install"
HR="--------------------------------------------------------------------------------"
PACMAN="pacman --noconfirm --config /tmp/pacman.conf"
TARGET_PACMAN="pacman --noconfirm --config /tmp/pacman.conf -r ${INSTALL_TARGET}"
CHROOT_PACMAN="pacman --noconfirm --cachedir /var/cache/pacman/pkg --config /tmp/pacman.conf -r ${INSTALL_TARGET}"
FILE_URL="file:///packages/core-$(uname -m)/pkg"
FTP_URL='ftp://mirrors.kernel.org/archlinux/$repo/os/$arch'
HTTP_URL='http://mirrors.kernel.org/archlinux/$repo/os/$arch'

# ------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------
# I've avoided using functions in this script as they aren't required and
# I think it's more of a learning tool if you see the step-by-step 
# procedures even with minor duplciations along the way, but I feel that
# these functions clarify the particular steps of setting values in config
# files.

SetValue () { 
# EXAMPLE: SetValue VARIABLENAME '\"Quoted Value\"' /file/path
VALUENAME="$1" NEWVALUE="$2" FILEPATH="$3"
sed -i "s+^#\?\(${VALUENAME}\)=.*$+\1=${NEWVALUE}+" "${FILEPATH}"
}

CommentOutValue () {
VALUENAME="$1" FILEPATH="$2"
sed -i "s/^\(${VALUENAME}.*\)$/#\1/" "${FILEPATH}"
}

UncommentValue () {
VALUENAME="$1" FILEPATH="$2"
sed -i "s/^#\(${VALUENAME}.*\)$/\1/" "${FILEPATH}"
}

# ------------------------------------------------------------------------
# Initialize
# ------------------------------------------------------------------------
# Warn the user about impending doom, set up the network on eth0, mount
# the squashfs images (Archboot does this normally, we're just filling in
# the gaps resulting from the fact that we're doing a simple scripted
# install). We also create a temporary pacman.conf that looks for packages
# locally first before sourcing them from the network. It would be better
# to do either *all* local or *all* network but we can't for two reasons.
#     1. The Archboot installation image might have an out of date kernel
#	 (currently the case) which results in problems when chrooting
#	 into the install mount point to modprobe efivars. So we use the
#	 package snapshot on the Archboot media to ensure our kernel is
#	 the same as the one we booted with.
#     2. Ideally we'd source all local then, but some critical items,
#	 notably grub2-efi variants, aren't yet on the Archboot media.

# Warn
# ------------------------------------------------------------------------
timer=9
echo -e "\n\nMAC WARNING: This script is not designed for APPLE MAC installs and will potentially misconfigure boot to your existing OS X installation. STOP NOW IF YOU ARE ON A MAC.\n\n"
echo -n "GENERAL WARNING: This procedure will completely format /dev/sda. Please cancel with ctrl-c to cancel within $timer seconds..."
while [[ $timer -gt 0 ]]
do
	sleep 1
	let timer-=1
	echo -en "$timer seconds..."
done

echo "STARTING"

# Get Network
# ------------------------------------------------------------------------
echo -n "Waiting for network address.."
#dhclient eth0
dhcpcd -p eth0
echo -n "Network address acquired."

# Mount packages squashfs images
# ------------------------------------------------------------------------
# normally these do not exist/are not mounted yet,
# but to be sure...: (interrupted previous run?)
umount "/packages/core-$(uname -m)" 2>&1 | grep -vi 'not found'
umount "/packages/core-any" 2>&1 | grep -vi 'not found'
rm -rf "/packages/core-$(uname -m)"
rm -rf "/packages/core-any"

mkdir -p "/packages/core-$(uname -m)"
mkdir -p "/packages/core-any"

modprobe -q loop
modprobe -q squashfs
mount -o ro,loop -t squashfs "/src/packages/archboot_packages_$(uname -m).squashfs" "/packages/core-$(uname -m)"
mount -o ro,loop -t squashfs "/src/packages/archboot_packages_any.squashfs" "/packages/core-any"

# Create temporary pacman.conf file
# ------------------------------------------------------------------------
cat << PACMANEOF > /tmp/pacman.conf
[options]
Architecture = auto
CacheDir = ${INSTALL_TARGET}/var/cache/pacman/pkg
CacheDir = /packages/core-$(uname -m)/pkg
CacheDir = /packages/core-any/pkg

[core]
Server = ${FILE_URL}
Server = ${FTP_URL}
Server = ${HTTP_URL}

[extra]
Server = ${FILE_URL}
Server = ${FTP_URL}
Server = ${HTTP_URL}

PACMANEOF

# Prepare pacman
# ------------------------------------------------------------------------
[[ ! -d "${INSTALL_TARGET}/var/cache/pacman/pkg" ]] && mkdir -m 755 -p "${INSTALL_TARGET}/var/cache/pacman/pkg"
[[ ! -d "${INSTALL_TARGET}/var/lib/pacman" ]] && mkdir -m 755 -p "${INSTALL_TARGET}/var/lib/pacman"
${PACMAN} -Sy
${TARGET_PACMAN} -Sy

# Install prereqs from network (not on archboot media)
# ------------------------------------------------------------------------
echo -e "\nInstalling prereqs...\n$HR"
#sed -i "s/^#S/S/" /etc/pacman.d/mirrorlist # Uncomment all Server lines
UncommentValue S /etc/pacman.d/mirrorlist # Uncomment all Server lines
${PACMAN} --noconfirm -Sy gptfdisk btrfs-progs-unstable

# ------------------------------------------------------------------------
# Configure Host
# ------------------------------------------------------------------------
# Here we create three partitions:
# 1. efi and /boot (one partition does double duty)
# 2. swap
# 3. our encrypted root
# Note that all of these are on a GUID partition table scheme. This proves
# to be quite clean and simple since we're not doing anything with MBR
# boot partitions and the like.

echo -e "\nFormatting disk...\n$HR"

# disk prep
sgdisk -Z /dev/sda # zap all on disk
sgdisk -a 2048 -o /dev/sda # new gpt disk 2048 alignment

# create partitions
sgdisk -n 1:0:+200M /dev/sda # partition 1 (UEFI BOOT), default start block, 200MB
sgdisk -n 2:0:+4G /dev/sda # partition 2 (SWAP), default start block, 200MB
sgdisk -n 3:0:0 /dev/sda # partition 3, (LUKS), default start, remaining space

# set partition types
sgdisk -t 1:ef00 /dev/sda
sgdisk -t 2:8200 /dev/sda
sgdisk -t 3:8300 /dev/sda

# label partitions
sgdisk -c 1:"UEFI Boot" /dev/sda
sgdisk -c 2:"Swap" /dev/sda
sgdisk -c 3:"LUKS" /dev/sda

# format LUKS on root
cryptsetup --cipher=aes-xts-plain --verify-passphrase --key-size=512 luksFormat /dev/sda3
cryptsetup luksOpen /dev/sda3 root

# NOTE: make sure to add dm_crypt and aes_i586 to MODULES in rc.conf
# NOTE2: actually this isn't required since we're mounting an encrypted root and grub2/initramfs handles this before we even get to rc.conf

# make filesystems
echo -e "\nCreating Filesystems...\n$HR"
mkfs.vfat /dev/sda1
# following swap related commands not used now that we're encrypting our swap partition
#mkswap /dev/sda2
#swapon /dev/sda2
#mkfs.ext4 /dev/sda3 # this is where we'd create an unencrypted root partition, but we're using luks instead
mkfs.ext4 /dev/mapper/root

# mount target
mkdir ${INSTALL_TARGET}
#mount /dev/sda3 ${INSTALL_TARGET} # this is where we'd mount the unencrypted root partition
mount /dev/mapper/root ${INSTALL_TARGET}
mkdir ${INSTALL_TARGET}/boot
mount -t vfat /dev/sda1 ${INSTALL_TARGET}/boot

# ------------------------------------------------------------------------
# Install base, necessary utilities
# ------------------------------------------------------------------------

mkdir -p ${INSTALL_TARGET}/var/lib/pacman
${TARGET_PACMAN} -Sy
${TARGET_PACMAN} -Su base
# curl could be installed later but we want it ready for rankmirrors
${TARGET_PACMAN} -S curl
${TARGET_PACMAN} -R grub
rm -rf ${INSTALL_TARGET}/boot/grub
${TARGET_PACMAN} -S grub2-efi-x86_64

# ------------------------------------------------------------------------
# Configure new system
# ------------------------------------------------------------------------
SetValue HOSTNAME ${HOSTNAME} ${INSTALL_TARGET}/etc/rc.conf
sed -i "s/^\(127\.0\.0\.1.*\)$/\1 ${HOSTNAME}/" ${INSTALL_TARGET}/etc/hosts
SetValue CONSOLEFONT Lat2-Terminus16 ${INSTALL_TARGET}/etc/rc.conf
#following replaced due to netcfg
#SetValue interface eth0 ${INSTALL_TARGET}/etc/rc.conf

# ------------------------------------------------------------------------
# write fstab
# ------------------------------------------------------------------------
# You can use UUID's or whatever you want here, of course. This is just
# the simplest approach and as long as your drives aren't changing values
# randomly it should work fine.
cat > ${INSTALL_TARGET}/etc/fstab <<FSTAB_EOF
# 
# /etc/fstab: static file system information
#
# <file system>		<dir>	<type>	<options>		<dump>	<pass>
tmpfs			/tmp	tmpfs	nodev,nosuid		0	0
/dev/sda1		/boot	vfat	defaults		0	0 
/dev/mapper/cryptswap	none	swap	defaults		0	0 
/dev/mapper/root	/ 	ext4	defaults,noatime	0	1 
FSTAB_EOF

# ------------------------------------------------------------------------
# write crypttab
# ------------------------------------------------------------------------
# encrypted swap (random passphrase on boot)
echo cryptswap /dev/sda2 SWAP "-c aes-xts-plain -h whirlpool -s 512" >> ${INSTALL_TARGET}/etc/crypttab

# ------------------------------------------------------------------------
# copy configs we want to carry over to target from install environment
# ------------------------------------------------------------------------

mv ${INSTALL_TARGET}/etc/resolv.conf ${INSTALL_TARGET}/etc/resolv.conf.orig
cp /etc/resolv.conf ${INSTALL_TARGET}/etc/resolv.conf

mkdir -p ${INSTALL_TARGET}/tmp
cp /tmp/pacman.conf ${INSTALL_TARGET}/tmp/pacman.conf

# ------------------------------------------------------------------------
# mount proc, sys, dev in install root
# ------------------------------------------------------------------------

mount -t proc proc ${INSTALL_TARGET}/proc
mount -t sysfs sys ${INSTALL_TARGET}/sys
mount -o bind /dev ${INSTALL_TARGET}/dev

# we have to remount /boot from inside the chroot
umount ${INSTALL_TARGET}/boot

# ------------------------------------------------------------------------
# Create install_efi script (to be run *after* chroot /install)
# ------------------------------------------------------------------------

touch ${INSTALL_TARGET}/install_efi
chmod a+x ${INSTALL_TARGET}/install_efi
cat > ${INSTALL_TARGET}/install_efi <<EFI_EOF

# functions (these could be a library, but why overcomplicate things
# ------------------------------------------------------------------------
SetValue () { VALUENAME="\$1" NEWVALUE="\$2" FILEPATH="\$3"; sed -i "s+^#\?\(\${VALUENAME}\)=.*\$+\1=\${NEWVALUE}+" "\${FILEPATH}"; }
CommentOutValue () { VALUENAME="\$1" FILEPATH="\$2"; sed -i "s/^\(\${VALUENAME}.*\)\$/#\1/" "\${FILEPATH}"; }
UncommentValue () { VALUENAME="\$1" FILEPATH="\$2"; sed -i "s/^#\(\${VALUENAME}.*\)\$/\1/" "\${FILEPATH}"; }

# remount here or grub et al gets confused
# ------------------------------------------------------------------------
mount -t vfat /dev/sda1 /boot

# mkinitcpio
# ------------------------------------------------------------------------
# NOTE: intel_agp drm and i915 for intel graphics
SetValue MODULES '\\"dm_mod dm_crypt aes_x86_64 ext2 ext4 vfat intel_agp drm i915\\"' /etc/mkinitcpio.conf
SetValue HOOKS '\\"base udev pata scsi sata usb usbinput keymap consolefont encrypt filesystems\\"' /etc/mkinitcpio.conf
mkinitcpio -p linux

# locale-gen
# ------------------------------------------------------------------------
UncommentValue en_US /etc/locale.gen
locale-gen

# kernel modules for EFI install
# ------------------------------------------------------------------------
modprobe efivars
modprobe dm-mod

# install and configure grub2
# ------------------------------------------------------------------------
# did this above
#${CHROOT_PACMAN} -Sy
#${CHROOT_PACMAN} -R grub
#rm -rf /boot/grub
#${CHROOT_PACMAN} -S grub2-efi-x86_64

# you can be surprisingly sloppy with the root value you give grub2 as a kernel option and
# even omit the cryptdevice altogether, though it will wag a finger at you for using
# a deprecated syntax, so we're using the correct form here
# NOTE: take out i915.modeset=1 unless you are on intel graphics
SetValue GRUB_CMDLINE_LINUX '\\"cryptdevice=/dev/sda3:root add_efi_memmap i915.modeset=1 i915.i915_enable_rc6=1 i915.i915_enable_fbc=1 i915.lvds_downclock=1 pcie_aspm=force quiet\\"' /etc/default/grub

# set output to graphical
SetValue GRUB_TERMINAL_OUTPUT gfxterm /etc/default/grub
SetValue GRUB_GFXMODE 960x600x32,auto /etc/default/grub
SetValue GRUB_GFXPAYLOAD_LINUX keep /etc/default/grub # comment out this value if text only mode

# install the actual grub2. Note that despite our --boot-directory option we will still need to move
# the grub directory to /boot/grub during grub-mkconfig operations until grub2 gets patched (see below)
grub_efi_x86_64-install --bootloader-id=grub --no-floppy --recheck

# create our EFI boot entry
efibootmgr --create --gpt --disk /dev/sda --part 1 --write-signature --label "ARCH LINUX" --loader "\\\\grub\\\\grub.efi"

# copy font for grub2
cp /usr/share/grub/unicode.pf2 /boot/grub

# generate config file
grub-mkconfig -o /boot/grub/grub.cfg

exit
EFI_EOF

# ------------------------------------------------------------------------
# Install EFI using script inside chroot
# ------------------------------------------------------------------------
chroot ${INSTALL_TARGET} /install_efi
rm ${INSTALL_TARGET}/install_efi

# ------------------------------------------------------------------------
# Post install steps
# ------------------------------------------------------------------------
# anything you want to do post install. run the script automatically or
# manually

touch ${INSTALL_TARGET}/post_install
chmod a+x ${INSTALL_TARGET}/post_install
cat > ${INSTALL_TARGET}/post_install <<POST_EOF
set -o errexit
set -o nounset

# functions (these could be a library, but why overcomplicate things
# ------------------------------------------------------------------------
SetValue () { VALUENAME="\$1" NEWVALUE="\$2" FILEPATH="\$3"; sed -i "s+^#\?\(\${VALUENAME}\)=.*\$+\1=\${NEWVALUE}+" "\${FILEPATH}"; }
CommentOutValue () { VALUENAME="\$1" FILEPATH="\$2"; sed -i "s/^\(\${VALUENAME}.*\)\$/#\1/" "\${FILEPATH}"; }
UncommentValue () { VALUENAME="\$1" FILEPATH="\$2"; sed -i "s/^#\(\${VALUENAME}.*\)\$/\1/" "\${FILEPATH}"; }

# root password
# ------------------------------------------------------------------------
echo -e "${HR}\\nNew root user password\\n${HR}"
passwd

# add user
# ------------------------------------------------------------------------
echo -e "${HR}\\nNew non-root user password (username:${USERNAME})\\n${HR}"
groupadd sudo
useradd -m -g users -G audio,lp,optical,storage,video,games,power,scanner,network,sudo,wheel -s /bin/bash ${USERNAME}
passwd ${USERNAME}

# mirror ranking
# ------------------------------------------------------------------------
#echo -e "${HR}\\nRanking Mirrors (this will take a while)\\n${HR}"
#cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.orig
#mv /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.all
#sed -i "s/#S/S/" /etc/pacman.d/mirrorlist.all
#rankmirrors -n 5 /etc/pacman.d/mirrorlist.all > /etc/pacman.d/mirrorlist

# mirrors - all (quick and dirty alternate to ranking)
# ------------------------------------------------------------------------
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.orig
sed -i "s/#S/S/" /etc/pacman.d/mirrorlist

# temporary fix for locale.sh update conflict
# ------------------------------------------------------------------------
mv /etc/profile.d/locale.sh /etc/profile.d/locale.sh.preupdate || true

# additional groups and utilities
# ------------------------------------------------------------------------
pacman --noconfirm -Syu
pacman --noconfirm -S base-devel

# AUR helper
# ------------------------------------------------------------------------
# Note that the AUR helper must support standard pacman syntax
mkdir -p /tmp/build
cd /tmp/build
wget https://aur.archlinux.org/packages/${AURHELPER}/${AURHELPER}.tar.gz
tar -xzvf ${AURHELPER}.tar.gz
cd ${AURHELPER}
makepkg --asroot -si
cd /tmp

# sudo
# ------------------------------------------------------------------------
pacman --noconfirm -S sudo
cp /etc/sudoers /tmp/sudoers.edit
sed -i "s/#\s*\(%wheel\s*ALL=(ALL)\s*ALL.*$\)/\1/" /tmp/sudoers.edit
sed -i "s/#\s*\(%sudo\s*ALL=(ALL)\s*ALL.*$\)/\1/" /tmp/sudoers.edit
visudo -qcsf /tmp/sudoers.edit && cat /tmp/sudoers.edit > /etc/sudoers 

# power
# ------------------------------------------------------------------------
pacman --noconfirm -S acpi acpid acpitool cpufrequtils
${AURHELPER} --noconfirm -S powertop2
sed -i "/^DAEMONS/ s/)/ @acpid)/" /etc/rc.conf
sed -i "/^MODULES/ s/)/ acpi-cpufreq cpufreq_ondemand cpufreq_powersave coretemp)/" /etc/rc.conf
# following requires my acpi handler script
echo "/etc/acpi/handler.sh boot" > /etc/rc.local

# time
# ------------------------------------------------------------------------
pacman --noconfirm -S ntp
sed -i "/^DAEMONS/ s/hwclock /!hwclock @ntpd /" /etc/rc.conf

# wireless (wpa supplicant should already be installed)
# ------------------------------------------------------------------------
pacman --noconfirm -S iw wpa_supplicant rfkill
pacman --noconfirm -S netcfg wpa_actiond ifplugd
mv /etc/wpa_supplicant.conf /etc/wpa_supplicant.conf.orig
echo -e "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=network\nupdate_config=1" > /etc/wpa_supplicant.conf
# make sure to copy /etc/network.d/examples/wireless-wpa-config to /etc/network.d/home and edit
sed -i "/^DAEMONS/ s/)/ @net-auto-wireless @net-auto-wired)/" /etc/rc.conf
sed -i "/^DAEMONS/ s/ network / /" /etc/rc.conf
echo -e "\nWIRELESS_INTERFACE=wlan0" >> /etc/rc.conf
echo -e "WIRED_INTERFACE=eth0" >> /etc/rc.conf
echo "options iwlagn led_mode=2" > /etc/modprobe.d/iwlagn.conf

# sound
# ------------------------------------------------------------------------
pacman --noconfirm -S alsa-utils alsa-plugins
sed -i "/^DAEMONS/ s/)/ @alsa)/" /etc/rc.conf
mv /etc/asound.conf /etc/asound.conf.orig || true
#if alsamixer isn't working, try alsamixer -Dhw and speaker-test -Dhw -c 2

# video
# ------------------------------------------------------------------------
pacman --noconfirm -S base-devel mesa mesa-demos # linux-headers

# x
# ------------------------------------------------------------------------
pacman --noconfirm -S xorg xorg-server xorg-xinit xorg-utils xorg-server-utils xdotool xorg-xlsfonts
${AURHELPER} --noconfirm -S xf86-input-wacom-git

# environment/wm/etc.
# ------------------------------------------------------------------------
#pacman --noconfirm -S xfce4 compiz ccsm
pacman --noconfirm -S xcompmgr xscreensaver hsetroot
pacman --noconfirm -S rxvt-unicode urxvt-url-select
#${AURHELPER} -S rxvt-unicode-cvs # need to manually edit out patch lines
pacman --noconfirm -S urxvt-url-select
pacman --noconfirm -S gtk2
pacman --noconfirm -S ghc alex happy gtk2hs-buildtools cabal-install
${AURHELPER} --noconfirm -S physlock
${AURHELPER} --noconfirm -S unclutter
pacman --noconfirm -S dbus upower
sed -i "/^DAEMONS/ s/)/ @dbus)/" /etc/rc.conf

# TODO: another install script for this
# following as non root user, make sure \$HOME/.cabal/bin is in path
# make sure to nuke existing .ghc and .cabal directories first
#su ${USERNAME}
#cd \$HOME
#rm -rf \$HOME/.ghc \$HOME/.cabal
# TODO: consider adding just .cabal to the path as well
#export PATH=$PATH:\$HOME/.cabal/bin
#cabal update
# # NOT USING following line... alex, happy and gtk2hs-buildtools installed via paman
# # cabal install alex happy xmonad xmonad-contrib gtk2hs-buildtools
#cabal install xmonad xmonad-contrib taffybar
#cabal install c2hs language-c x11-xft xmobar --flags "all-extensions"
pacman --noconfirm -S wireless_tools # don't want it, but xmobar does
#note that I installed xmobar from github instead
#exit

# fonts
# ------------------------------------------------------------------------
pacman --noconfirm -S terminus-font
${AURHELPER} --noconfirm -S webcore-fonts
${AURHELPER} --noconfirm -S libspiro
${AURHELPER} --noconfirm -S fontforge
${AURHELPER} -S freetype2-git-infinality # will prompt for freetype2 replacement
# TODO: sed infinality and change to OSX or OSX2 mode
#	and create the sym link from /etc/fonts/conf.avail to conf.d

# misc apps
# ------------------------------------------------------------------------
pacman --noconfirm -S htop openssh keychain bash-completion git vim
pacman --noconfirm -S chromium flashplugin
pacman --noconfirm -S scrot mypaint bc
${AURHELPER} --noconfirm -S task-git
${AURHELPER} --noconfirm -S stellarium
# googlecl discovery requires the svn googlecl version and google-api-python-client and httplib2, gflags
${AURHELPER} --noconfirm -S googlecl-svn
${AURHELPER} --noconfirm -S googlecl-svn python2-google-api-python-client python2-httplib2 python2-gflags python-simplejson
#${AURHELPER} --noconfirm -S google-talkplugin
${AURHELPER} --noconfirm -S argyll dispcalgui
# TODO: argyll

# extras
# ------------------------------------------------------------------------

${AURHELPER} -S --noconfirm haskell-mtl haskell-hscolour haskell-x11
${AURHELPER} -S --noconfirm xmonad-darcs xmonad-contrib-darcs xmobar-git
${AURHELPER} -S --noconfirm trayer-srg-git
#skype
pacman -S --noconfirm zip # for pent buftabs
#${AURHELPER} -S --noconfirm aurora
#${AURHELPER} -S --noconfirm aurora-pentadactyl-buftabs-git
#${AURHELPER} -S --noconfirm terminus-font-ttf
mkdir -p /home/${USERNAME}/.pentadactyl/plugins && ln -sf /usr/share/aurora-pentadactyl-buftabs/buftabs.js /home/${USERNAME}/.pentadactyl/plugins/buftabs.js

POST_EOF

# ------------------------------------------------------------------------
# Post install in chroot
# ------------------------------------------------------------------------
#echo "chroot and run /post_install"
chroot /install /post_install
mv /install/post_install /.

# ------------------------------------------------------------------------
# NOTES/TODO
# ------------------------------------------------------------------------
