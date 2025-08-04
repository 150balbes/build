# Rockchip RK3588 SoC octa core 4-16GB SoC 2x1GBe eMMC USB3 NVMe SATA WiFi/BT HDMI DP HDMI-In RS232 RS485
declare -g BOARD_NAME="Mekotronics R58-HD"
declare -g BOARDFAMILY="rockchip-rk3588"
declare -g BOARD_MAINTAINER=""
declare -g KERNEL_TARGET="vendor"
declare -g BOOTCONFIG="mekotronics_r58x-rk3588_defconfig"               # vendor u-boot; with NVMe and a DTS
declare -g BOOT_FDT_FILE="rockchip/rk3588-r58-hd.dtb" 			# Specific to this board
declare -g UEFI_EDK2_BOARD_ID="r58x"                                    # This _only_ used for uefi-edk2-rk3588 extension

# Source vendor-specific configuration
source "${SRC}/config/sources/vendors/mekotronics/mekotronics-rk3588.conf.sh"


function post_family_config_branch_vendor__mekotronics-r58-4x4_use_kernel() {
	display_alert "$BOARD" " Mekotronics kernel overrides for $BOARD / $BRANCH" "info"
	declare -g KERNEL_MAJOR_MINOR="6.1"    # Major and minor versions of this kernel.
	declare -g KERNELSOURCE='https://github.com/armbian/linux-rockchip.git'
	declare -g KERNELBRANCH='branch:rk-6.1-rkr5.1'
	declare -g LINUXFAMILY="media-rk-6.1-rkr5.1"
	declare -g LINUXCONFIG="linux-media-rk-6.1-rkr5.1"
}
