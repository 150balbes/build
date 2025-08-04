# Rockchip RK3576 SoC octa core 8-64GB SoC 2*GBe eMMC USB3 NvME WIFI
BOARD_NAME="Mekotronics R57"
BOARDFAMILY="rk35xx"
BOOTCONFIG="none"
KERNEL_TARGET="vendor"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_SCENARIO="spl-blobs"
IMAGE_PARTITION_TABLE="gpt"
BOARD_MAINTAINER=""
SRC_EXTLINUX="yes"

function post_family_tweaks__mekotronics-r57_naming_audios() {
	display_alert "$BOARD" "Renaming mekotronics r57 audios" "info"

	mkdir -p $SDCARD/etc/udev/rules.d/
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmi0-sound", ENV{SOUND_DESCRIPTION}="HDMI0 Audio"' > $SDCARD/etc/udev/rules.d/90-naming-audios.rules
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-dp0-sound", ENV{SOUND_DESCRIPTION}="DP0 Audio"' >> $SDCARD/etc/udev/rules.d/90-naming-audios.rules
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-es8316-sound", ENV{SOUND_DESCRIPTION}="ES8316 Audio"' >> $SDCARD/etc/udev/rules.d/90-naming-audios.rules

	return 0
}


function post_family_config_branch_vendor__mekotronics-r57_use_kernel() {
	display_alert "$BOARD" " Mekotronics kernel overrides for $BOARD / $BRANCH" "info"

	declare -g KERNEL_MAJOR_MINOR="6.1"    # Major and minor versions of this kernel.
	declare -g KERNELSOURCE='https://github.com/armbian/linux-rockchip.git'
	declare -g KERNELBRANCH='branch:rk-6.1-rkr5.1'
	declare -g LINUXFAMILY="media-rk-6.1-rkr5.1"
	declare -g LINUXCONFIG="linux-media-rk-6.1-rkr5.1"
}
