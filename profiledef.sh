#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="flowbit"
iso_label="FLOWBIT_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="flowbit OS"
iso_application="flowbit OS — Bootable IT Toolkit"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="kit"
buildmodes=('iso')
bootmodes=('bios.syslinux'
           'uefi.grub')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19')
bootstrap_tarball_compression=(zstd -c -T0 --long -19)
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/opt/kit/kit.sh"]="0:0:755"
  ["/opt/kit/modules/wiper.sh"]="0:0:755"
  ["/opt/kit/modules/sysinfo.sh"]="0:0:755"
  ["/opt/kit/modules/network.sh"]="0:0:755"
  ["/opt/kit/modules/hwtest.sh"]="0:0:755"
  ["/opt/kit/modules/biostools.sh"]="0:0:755"
  ["/opt/kit/modules/backup.sh"]="0:0:755"
  ["/opt/kit/modules/common.sh"]="0:0:755"
  ["/usr/local/bin/kit-automount.sh"]="0:0:755"
  ["/usr/local/bin/kit-usb-mount.sh"]="0:0:755"
  ["/opt/kit/boot.sh"]="0:0:755"
)
