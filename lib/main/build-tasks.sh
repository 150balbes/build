#!/usr/bin/env bash

###############################################################################

build_get_boot_sources() {
	if [[ -n $BOOTSOURCE ]]; then
		fetch_from_repo "$BOOTSOURCE" "$BOOTDIR" "$BOOTBRANCH" "yes"
	fi
	if [[ -n $ATFSOURCE ]]; then
		fetch_from_repo "$ATFSOURCE" "$ATFDIR" "$ATFBRANCH" "yes"
	fi
}

build_get_kernel_sources() {
	if [[ -n $KERNELSOURCE ]]; then
		if $(declare -f var_origin_kernel > /dev/null); then
			unset LINUXSOURCEDIR
			LINUXSOURCEDIR="linux-mainline/$KERNEL_VERSION_LEVEL"
			VAR_SHALLOW_ORIGINAL=var_origin_kernel
			waiter_local_git "url=$KERNELSOURCE $KERNELSOURCENAME $KERNELBRANCH dir=$LINUXSOURCEDIR $KERNELSWITCHOBJ"
			unset VAR_SHALLOW_ORIGINAL
		else
			fetch_from_repo "$KERNELSOURCE" "$KERNELDIR" "$KERNELBRANCH" "yes"
		fi
	fi
}

build_uboot() {
	# Don't build at all if the BOOTCONFIG is 'none'.
	[[ "${BOOTCONFIG}" != "none" ]] && {
		# Compile u-boot if packed .deb does not exist or use the one from repository
		if [[ ! -f "${DEB_STORAGE}"/${RELEASE}/linux-u-boot/${CHOSEN_UBOOT}_*_${ARCH}.deb ]]; then
			if [[ -n "${ATFSOURCE}" ]]; then
				compile_atf
			fi
			compile_uboot
		fi
	}
}

build_kernel() {
	# CHOSEN_KERNEL=linux-image-${BRANCH}-${LINUXFAMILY}
	# filename = pkgname_pkgversion_arch.deb
	# Compile kernel if packed .deb does not exist or use the one from repository
	if [[ ! -f ${DEB_STORAGE}/${RELEASE}/linux-${BRANCH}/${CHOSEN_KERNEL}_*_${ARCH}.deb ]]; then

		KDEB_CHANGELOG_DIST=$RELEASE
		[[ -n $KERNELSOURCE ]] && compile_kernel

	fi
}

build_armbian-config() {
	# Compile armbian-config if packed .deb does not exist or use the one from repository
	if [[ ! -f ${DEB_STORAGE}/armbian-config_${REVISION}_all.deb ]]; then

		compile_armbian-config

	fi
}

build_armbian-zsh() {
	# Compile armbian-zsh if packed .deb does not exist or use the one from repository
	if [[ ! -f ${DEB_STORAGE}/armbian-zsh_${REVISION}_all.deb ]]; then

		compile_armbian-zsh

	fi
}

build_plymouth-theme-armbian() {
	# Compile plymouth-theme-armbian if packed .deb does not exist or use the one from repository
	if [[ ! -f ${DEB_STORAGE}/plymouth-theme-armbian_${REVISION}_all.deb ]]; then

		compile_plymouth-theme-armbian

	fi
}

build_armbian-firmware() {
	# Compile armbian-firmware if packed .deb does not exist or use the one from repository
	if ! ls "${DEB_STORAGE}/armbian-firmware_${REVISION}_all.deb" 1> /dev/null 2>&1 || ! ls "${DEB_STORAGE}/armbian-firmware-full_${REVISION}_all.deb" 1> /dev/null 2>&1; then

			 # Build firmware by default.
			[[ "${INSTALL_ARMBIAN_FIRMWARE:-yes}" == "yes" ]] && {
				FULL=""
				REPLACE="-full"
				compile_firmware
				FULL="-full"
				REPLACE=""
				compile_firmware
			}

	fi
}

build_armbian-bsp-cli() {
	# create board support package
	[[ -n "${RELEASE}" && \
		! -f "${DEB_STORAGE}/${BSP_CLI_PACKAGE_FULLNAME}.deb" ]] && \
		create_board_package
}

build_armbian-desktop() {
	# create desktop package
	[[ -n "${RELEASE}" && \
		"${DESKTOP_ENVIRONMENT}" && \
		! -f "${DEB_STORAGE}/$RELEASE/${CHOSEN_DESKTOP}_${REVISION}_all.deb" ]] && \
		create_desktop_package
}

build_armbian-bsp-desktop() {
	[[ -n "${RELEASE}" && \
		"${DESKTOP_ENVIRONMENT}" && \
		! -f "${DEB_STORAGE}/${RELEASE}/${BSP_DESKTOP_PACKAGE_FULLNAME}.deb" ]] && \
		create_bsp_desktop_package
}

build_chroot() {
	# build additional packages
	chroot_build_packages $EXTERNAL_NEW
}

build_bootstrap() {
	debootstrap_ng
}

################################################################################
#
# build_main()
#
# Builds all artifacts or the filtered ones only based on BUILD_ONLY.
# Ensures that any build pre-requisite is met.
#
# BUILD_ONLY: optional comma separated list of artifacts to build only.
#      If this list is empty or not set, then all build tasks will be performed.
#      The following build task names are supported for filtering build tasks:
#      u-boot, kernel, armbian-config, armbian-zsh, plymouth-theme-armbian,
#      armbian-firmware, armbian-bsp, chroot, bootstrap
#
# Note: The list of all valid BUILD_ONLY task names is to be maintained
#       in function build_validate_buildOnly() above as local variable _all_valid_buildOnly.
#
build_main() {

	start=$(date +%s)

	# Check and install dependencies, directory structure and settings
	# The OFFLINE_WORK variable inside the function
	prepare_host

	[[ "${JUST_INIT}" == "yes" ]] && exit 0

	[[ $CLEAN_LEVEL == *sources* ]] && cleaning "sources"

	for option in $(tr ',' ' ' <<< "$CLEAN_LEVEL"); do
		[[ $option != sources ]] && cleaning "$option"
	done

	build_task_is_enabled "chroot" && build_chroot

	build_task_is_enabled "u-boot" && {
		build_get_boot_sources

		call_extension_method "fetch_sources_tools" <<- 'FETCH_SOURCES_TOOLS'
		*fetch host-side sources needed for tools and build*
		Run early to fetch_from_repo or otherwise obtain sources for needed tools.
		FETCH_SOURCES_TOOLS

		call_extension_method "build_host_tools" <<- 'BUILD_HOST_TOOLS'
		*build needed tools for the build, host-side*
		After sources are fetched, build host-side tools needed for the build.
		BUILD_HOST_TOOLS

		build_uboot
	}

	build_task_is_enabled "kernel" && {

		build_get_kernel_sources

		build_kernel
	}

	build_task_is_enabled "armbian-config" && build_armbian-config

	build_task_is_enabled "armbian-zsh" && build_armbian-zsh

	build_task_is_enabled "plymouth-theme-armbian" && build_plymouth-theme-armbian

	build_task_is_enabled "armbian-firmware" && build_armbian-firmware

	overlayfs_wrapper "cleanup"

	build_task_is_enabled "armbian-bsp-cli" && build_armbian-bsp-cli

	build_task_is_enabled "armbian-desktop" && build_armbian-desktop

	build_task_is_enabled "armbian-bsp-desktop" && build_armbian-bsp-desktop

	build_task_is_enabled "bootstrap" && build_bootstrap

	display_alert "Build done" "@host" "info"
	display_alert "Target directory" "${DEB_STORAGE}/${RELEASE}" "info"

	call_extension_method "run_after_build" << 'RUN_AFTER_BUILD'
*hook for function to run after build, i.e. to change owner of `$SRC`*
Really one of the last hooks ever called. The build has ended. Congratulations.
- *NOTE:* this will run only if there were no errors during build process.
RUN_AFTER_BUILD

	end=$(date +%s)
	runtime_secs=$((end - start))
	display_alert "Runtime" "$(printf "%dm:%02ds" $((runtime_secs / 60)) $((runtime_secs % 60)))" "info"

	# Make it easy to repeat build by displaying build options used
	[ "$(systemd-detect-virt)" == 'docker' ] && BUILD_CONFIG='docker'
	display_alert "Repeat Build Options" "./compile.sh ${BUILD_CONFIG} BOARD=${BOARD} BRANCH=${BRANCH} \
$([[ -n $RELEASE ]] && echo "RELEASE=${RELEASE} ")\
$([[ -n $BUILD_MINIMAL ]] && echo "BUILD_MINIMAL=${BUILD_MINIMAL} ")\
$([[ -n $BUILD_DESKTOP ]] && echo "BUILD_DESKTOP=${BUILD_DESKTOP} ")\
$([[ -n $BUILD_ONLY ]] && echo "BUILD_ONLY=${BUILD_ONLY} ")\
$([[ -n $KERNEL_ONLY ]] && echo "KERNEL_ONLY=${KERNEL_ONLY} ")\
$([[ -n $KERNEL_CONFIGURE ]] && echo "KERNEL_CONFIGURE=${KERNEL_CONFIGURE} ")\
$([[ -n $DESKTOP_ENVIRONMENT ]] && echo "DESKTOP_ENVIRONMENT=${DESKTOP_ENVIRONMENT} ")\
$([[ -n $DESKTOP_ENVIRONMENT_CONFIG_NAME ]] && echo "DESKTOP_ENVIRONMENT_CONFIG_NAME=${DESKTOP_ENVIRONMENT_CONFIG_NAME} ")\
$([[ -n $DESKTOP_APPGROUPS_SELECTED ]] && echo "DESKTOP_APPGROUPS_SELECTED=\"${DESKTOP_APPGROUPS_SELECTED}\" ")\
$([[ -n $DESKTOP_APT_FLAGS_SELECTED ]] && echo "DESKTOP_APT_FLAGS_SELECTED=\"${DESKTOP_APT_FLAGS_SELECTED}\" ")\
$([[ -n $COMPRESS_OUTPUTIMAGE ]] && echo "COMPRESS_OUTPUTIMAGE=${COMPRESS_OUTPUTIMAGE} ")\
" "ext"

}
