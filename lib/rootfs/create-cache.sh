#!/usr/bin/env bash

# get_package_list_hash
#
# returns md5 hash for current package list and rootfs cache version
#
get_package_list_hash() {
	local package_arr exclude_arr
	local list_content
	read -ra package_arr <<< "${DEBOOTSTRAP_LIST} ${PACKAGE_LIST}"
	read -ra exclude_arr <<< "${PACKAGE_LIST_EXCLUDE}"
	(
		printf "%s\n" "${package_arr[@]}"
		printf -- "-%s\n" "${exclude_arr[@]}"
	) | sort -u | md5sum | cut -d' ' -f 1
}

# Check the reachability of the download. If returned empty we do nothing.
check_reachability_rootfs_download() {
	local cache_type=$1
	local packages_hash=$2

	curl --silent --fail -L "https://api.github.com/repos/armbian/cache/releases?per_page=1" | \
		jq '.[] | .assets[] | .browser_download_url' | \
		grep "${ARCH}-${RELEASE}-${cache_type}-${packages_hash}" | grep -v '.torrent'
}

# pack the rootfs
pack_rootfs() {
	local cache_fname=$1
	local cache_name=$(basename $cache_fname)
	local rootfs_dir="$2"

	tar cp --xattrs \
		   --directory=$rootfs_dir/ \
		   --exclude='./dev/*' \
		   --exclude='./proc/*' \
		   --exclude='./run/*' \
		   --exclude='./tmp/*' \
		   --exclude='./sys/*' \
		   --exclude='./home/*' \
		   --exclude='./root/*' . | \
		   pv -p -b -r -s $(du -sb $rootfs_dir/ | cut -f1) -N "$cache_name" | \
		   zstdmt -"${K_ZST:-9}" -c > $cache_fname

	# sign rootfs cache archive that it can be used for web cache once. Internal purposes
	if [[ -n "${GPG_PASS}" && "${SUDO_USER}" ]]; then
		[[ -n ${SUDO_USER} ]] && sudo chown -R ${SUDO_USER}:${SUDO_USER} "${DEST}"/images/
		echo "${GPG_PASS}" | \
		sudo -H -u ${SUDO_USER} \
		bash -c "gpg --passphrase-fd 0 \
				--armor \
				--detach-sign \
				--pinentry-mode loopback \
				--batch --yes ${cache_fname}" || exit 1
	fi

}

# upgrade packages
#
upgrade_packages() {
	local apt_extra_progress="--show-progress -o DPKG::Progress-Fancy=1"

	# stage: update packages list
	display_alert "Updating package list" "$RELEASE" "info"
	eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -e -c "apt-get -q -y update"' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/debootstrap.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Updating package lists..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'} ';EVALPIPE=(${PIPESTATUS[@]})'

	[[ ${EVALPIPE[0]} -eq 0 ]] || display_alert "Updating package lists" "failed" "wrn"

	# stage: upgrade base packages from xxx-updates and xxx-backports repository branches
	display_alert "Upgrading base packages" "$RELEASE" "info"
	eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -e -c "DEBIAN_FRONTEND=noninteractive apt-get -y -q \
		$apt_extra_progress upgrade"' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/debootstrap.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Upgrading base packages..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'} ';EVALPIPE=(${PIPESTATUS[@]})'

	[[ ${EVALPIPE[0]} -eq 0 ]] || display_alert "Upgrading base packages" "failed" "wrn"
}

# prepare_basic_rootfs
#
# prepare basic rootfs: unpack cache or create from scratch for $RELEASE
#
prepare_basic_rootfs() {
	local packages_hash=$(get_package_list_hash)
	local packages_hash=${packages_hash:0:8}
	# trap for unmounting content in case of error/interruption manually
	trap - INT TERM EXIT

	local cache_type="cli"
	[[ ${BUILD_DESKTOP} == yes ]] && local cache_type="xfce-desktop"
	[[ -n ${DESKTOP_ENVIRONMENT} ]] && local cache_type="${DESKTOP_ENVIRONMENT}"
	[[ ${BUILD_MINIMAL} == yes ]] && local cache_type="minimal"

	display_alert "Checking cache" "${ARCH}-${RELEASE}-${cache_type}-${packages_hash}-'*'.tar.zst" "info"

	# check the availability of the local rootfs file
	local cache_fname=$(
		find ${SRC}/cache/rootfs/ -name "${ARCH}-${RELEASE}-${cache_type}-${packages_hash}"-'*'.tar.zst
	)

	[[ ! -f $cache_fname ]] && [[ "$DOWNLOAD_ROOTFS" == "yes" ]] && {
		# check the reachability of the rootfs download after we have received
		# the local hash of the list and its type (packages_hash, cache_type)
		local download_lisl_url=$(check_reachability_rootfs_download "$cache_type" "$packages_hash")

		if [ "$download_lisl_url" != "" ]; then
			display_alert "Downloading rootfs from servers"
			for uri in $download_lisl_url; do
				eval "local url=$uri"
				echo "Download: $(basename $url)" >> "${DEST}/${LOG_SUBPATH}/output.log"
				wget -q --show-progress -P "${SRC}/cache/rootfs"  -c $url
			done
			cache_fname=$(
				find ${SRC}/cache/rootfs/ -name "${ARCH}-${RELEASE}-${cache_type}-${packages_hash}"-'*'.tar.zst
			)

			gpg --homedir "${SRC}"/cache/.gpg --no-permission-warning --trust-model always \
				-q --verify ${cache_fname}.asc >> "${DEST}/${LOG_SUBPATH}/output.log" 2>&1
			[[ ${PIPESTATUS[0]} -eq 0 ]] || display_alert "Verification ${cache_fname}" "failed" "wrn"
		fi
	}

	if [[ -f $cache_fname ]]; then

		cache_name=$(basename $cache_fname)
		local date_diff=$((($(date +%s) - $(stat -c %Y $cache_fname)) / 86400))
		display_alert "Extracting $cache_name" "$date_diff days old" "info"
		pv -p -b -r -c -N "[ .... ] $cache_name" "$cache_fname" | zstdmt -dc | tar xp --xattrs -C $SDCARD/
		[[ $? -ne 0 ]] && rm $cache_fname && exit_with_error "Cache $cache_fname is corrupted and was deleted. Restart."

		rm $SDCARD/etc/resolv.conf
		echo "nameserver $NAMESERVER" >> $SDCARD/etc/resolv.conf

		create_sources_list "$RELEASE" "$SDCARD"
		# Add Armbian repo if ADD_ARMBIAN_REPO=yes
		if [[ "${ADD_ARMBIAN_REPO}" == "yes" ]]; then
			display_alert "Adding Armbian repo" "${ARCH}-${RELEASE}" "wrn"
			add_armbian_sources_list "$RELEASE" "$SDCARD"
		fi

		[[ $date_diff -ge 7 ]] && {
			mount_chroot "$SDCARD"
			upgrade_packages
			if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
				# stage: remove downloaded packages
				chroot $SDCARD /bin/bash -c "apt-get -y autoremove; apt-get clean"
				umount_chroot "$SDCARD"
				display_alert "Repack rootfs"
				pack_rootfs "$cache_fname" "$SDCARD"
			else
				display_alert "upgrade_packages returned" "${PIPESTATUS[0]}" "wrn"
			fi
		}
	else
		create_rootfs_cache
	fi

	# used for internal purposes. Faster rootfs cache rebuilding
	if [[ "$ROOT_FS_CREATE_ONLY" == "yes" ]]; then
		umount --lazy "$SDCARD"
		rm -rf $SDCARD
		# remove exit trap
		trap - INT TERM EXIT
		exit
	fi

	mount_chroot "$SDCARD"
}

create_rootfs_cache() {
	local ROOT_FS_LOCAL_VERSION=${ROOTFSCACHE_VERSION:-7007}
	local cache_name=${ARCH}-${RELEASE}-${cache_type}-${packages_hash}-${ROOT_FS_LOCAL_VERSION}.tar.zst
	local cache_fname=${SRC}/cache/rootfs/${cache_name}

	display_alert "Creating new rootfs cache for" "$RELEASE" "info"
	# trap for unmounting content in case of error/interruption manually
	trap - INT TERM EXIT

	# stage: debootstrap base system
	local apt_mirror="http://$APT_MIRROR"

	# fancy progress bars
	[[ -z $OUTPUT_DIALOG ]] &&
	local apt_extra_progress="--show-progress -o DPKG::Progress-Fancy=1"

	# That is because eval itself is considered a single command, no matter how
	# many pipes you put in there, you'll get a single value, the return code of
	# the LAST pipe. Export the value of the pipe inside eval so we know outside
	# what happened:
	# eval 'bash -e -c "echo value" | grep -q eulav' ';EVALPIPE=(${PIPESTATUS[@]})'
	# echo ${EVALPIPE[*]}

	display_alert "Installing base system" "Stage 1/2" "info"
	cd $SDCARD # this will prevent error sh: 0: getcwd() failed
	eval 'debootstrap --variant=minbase \
		--include=${DEBOOTSTRAP_LIST// /,} \
		${PACKAGE_LIST_EXCLUDE:+ --exclude=${PACKAGE_LIST_EXCLUDE// /,}} \
		--arch=$ARCH \
		--components=${DEBOOTSTRAP_COMPONENTS} \
		$DEBOOTSTRAP_OPTION --foreign $RELEASE $SDCARD/ $apt_mirror' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/debootstrap.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Debootstrap (stage 1/2)..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'} ';EVALPIPE=(${PIPESTATUS[@]})'

	[[ ${EVALPIPE[0]} -ne 0 || ! -f $SDCARD/debootstrap/debootstrap ]] &&
	exit_with_error "Debootstrap base system for ${BRANCH} ${BOARD} ${RELEASE} ${DESKTOP_APPGROUPS_SELECTED} ${DESKTOP_ENVIRONMENT} ${BUILD_MINIMAL} first stage failed"

	cp /usr/bin/$QEMU_BINARY $SDCARD/usr/bin/

	mkdir -p $SDCARD/usr/share/keyrings/
	cp /usr/share/keyrings/*-archive-keyring.gpg $SDCARD/usr/share/keyrings/

	display_alert "Installing base system" "Stage 2/2" "info"
	eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -e -c "/debootstrap/debootstrap --second-stage"' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/debootstrap.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Debootstrap (stage 2/2)..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'} ';EVALPIPE=(${PIPESTATUS[@]})'

	[[ ${EVALPIPE[0]} -ne 0 || ! -f $SDCARD/bin/bash ]] &&
	exit_with_error "Debootstrap base system for ${BRANCH} ${BOARD} ${RELEASE} ${DESKTOP_APPGROUPS_SELECTED} ${DESKTOP_ENVIRONMENT} ${BUILD_MINIMAL} second stage failed"

	mount_chroot "$SDCARD"

	display_alert "Diverting" "initctl/start-stop-daemon" "info"
	# policy-rc.d script prevents starting or reloading services during image creation
	printf '#!/bin/sh\nexit 101' > $SDCARD/usr/sbin/policy-rc.d
	LC_ALL=C LANG=C chroot $SDCARD /bin/bash -c "dpkg-divert --quiet --local --rename --add /sbin/initctl" &> /dev/null
	LC_ALL=C LANG=C chroot $SDCARD /bin/bash -c "dpkg-divert --quiet --local --rename --add /sbin/start-stop-daemon" &> /dev/null
	printf '#!/bin/sh\necho "Warning: Fake start-stop-daemon called, doing nothing"' > $SDCARD/sbin/start-stop-daemon
	printf '#!/bin/sh\necho "Warning: Fake initctl called, doing nothing"' > $SDCARD/sbin/initctl
	chmod 755 $SDCARD/usr/sbin/policy-rc.d
	chmod 755 $SDCARD/sbin/initctl
	chmod 755 $SDCARD/sbin/start-stop-daemon

	# stage: configure language and locales
	display_alert "Generatining default locale" "info"
	if [[ -f $SDCARD/etc/locale.gen ]]; then
		sed -i '/ C.UTF-8/s/^# //g' $SDCARD/etc/locale.gen
		sed -i '/en_US.UTF-8/s/^# //g' $SDCARD/etc/locale.gen
	fi
	eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -c "locale-gen"' ${OUTPUT_VERYSILENT:+' >/dev/null 2>&1'}
	eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -c "update-locale --reset LANG=en_US.UTF-8"' \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>&1'}

	if [[ -f $SDCARD/etc/default/console-setup ]]; then
		sed -e 's/CHARMAP=.*/CHARMAP="UTF-8"/' -e 's/FONTSIZE=.*/FONTSIZE="8x16"/' \
			-e 's/CODESET=.*/CODESET="guess"/' -i $SDCARD/etc/default/console-setup
		eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -c "setupcon --save --force"'
	fi

	# stage: create apt-get sources list
	create_sources_list "$RELEASE" "$SDCARD"

	# Add Armbian repo if ADD_ARMBIAN_REPO=yes
	if [[ "${ADD_ARMBIAN_REPO}" == "yes" ]]; then
		display_alert "Adding Armbian repo" "${ARCH}-${RELEASE}" "wrn"
		add_armbian_sources_list "$RELEASE" "$SDCARD"
	fi

	# add armhf arhitecture to arm64, unless configured not to do so.
	if [[ "a${ARMHF_ARCH}" != "askip" ]]; then
		[[ $ARCH == arm64 ]] && eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -c "dpkg --add-architecture armhf"'
	fi

	# this should fix resolvconf installation failure in some cases
	chroot $SDCARD /bin/bash -c 'echo "resolvconf resolvconf/linkify-resolvconf boolean false" | debconf-set-selections'

	# TODO change name of the function from "desktop" and move to appropriate location
	add_desktop_package_sources

	# upgrade base packages
	upgrade_packages

	# stage: install additional packages
	display_alert "Installing the main packages for" "${RELEASE}" "info"
	eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -e -c "DEBIAN_FRONTEND=noninteractive apt-get -y -q \
		$apt_extra $apt_extra_progress --no-install-recommends install $PACKAGE_MAIN_LIST"' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/debootstrap.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Installing ${RELEASE} main packages..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'} ';EVALPIPE=(${PIPESTATUS[@]})'

	[[ ${EVALPIPE[0]} -ne 0 ]] &&
	exit_with_error "Installation of ${RELEASE} main packages for ${BRANCH} ${BOARD} ${DESKTOP_APPGROUPS_SELECTED} ${DESKTOP_ENVIRONMENT} ${BUILD_MINIMAL} failed"

	if [[ $BUILD_DESKTOP == "yes" ]]; then

		local apt_desktop_install_flags=""
		if [[ ! -z ${DESKTOP_APT_FLAGS_SELECTED+x} ]]; then
			for flag in ${DESKTOP_APT_FLAGS_SELECTED}; do
				apt_desktop_install_flags+=" --install-${flag}"
			done
		else
			# Myy : Using the previous default option, if the variable isn't defined
			# And ONLY if it's not defined !
			apt_desktop_install_flags+=" --no-install-recommends"
		fi

		display_alert "Installing the desktop packages for" "${RELEASE}" "info"
		eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -e -c "DEBIAN_FRONTEND=noninteractive apt-get -y -q \
			$apt_extra $apt_extra_progress install ${apt_desktop_install_flags} $PACKAGE_LIST_DESKTOP"' \
			${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/debootstrap.log'} \
			${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Installing ${RELEASE} desktop packages..." $TTY_Y $TTY_X'} \
			${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'} ';EVALPIPE=(${PIPESTATUS[@]})'

		[[ ${EVALPIPE[0]} -ne 0 ]] &&
		exit_with_error "Installation of ${RELEASE} desktop packages for ${BRANCH} ${BOARD} ${DESKTOP_APPGROUPS_SELECTED} ${DESKTOP_ENVIRONMENT} ${BUILD_MINIMAL} failed"
	fi

	# stage: check md5 sum of installed packages. Just in case.
	display_alert "Checking MD5 sum of installed packages" "debsums" "info"
	chroot $SDCARD /bin/bash -e -c "debsums -s"
	[[ $? -ne 0 ]] && exit_with_error "MD5 sums check of installed packages failed"

	# Remove packages from packages.uninstall
	display_alert "Uninstall packages" "$PACKAGE_LIST_UNINSTALL" "info"
	eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -e -c "DEBIAN_FRONTEND=noninteractive apt-get -y -qq \
		$apt_extra $apt_extra_progress purge $PACKAGE_LIST_UNINSTALL"' \
		${PROGRESS_LOG_TO_FILE:+' >> $DEST/${LOG_SUBPATH}/debootstrap.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Removing packages.uninstall packages..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'} ';EVALPIPE=(${PIPESTATUS[@]})'

	[[ ${EVALPIPE[0]} -ne 0 ]] && exit_with_error "Uninstall of ${RELEASE} packages failed"

	# stage: purge residual packages
	display_alert "Purging residual packages for" "${RELEASE}" "info"
	PURGINGPACKAGES=$(chroot $SDCARD /bin/bash -c "dpkg -l | awk '/^rc/ {print \$2}' | tr \"\n\" \" \"")
	eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -e -c "DEBIAN_FRONTEND=noninteractive apt-get -y -q \
		$apt_extra $apt_extra_progress remove --purge $PURGINGPACKAGES"' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/debootstrap.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Purging residual ${RELEASE} packages..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'} ';EVALPIPE=(${PIPESTATUS[@]})'

	[[ ${EVALPIPE[0]} -ne 0 ]] && exit_with_error "Purging of residual ${RELEASE} packages failed"

	# stage: remove downloaded packages
	chroot $SDCARD /bin/bash -c "apt-get -y autoremove; apt-get clean"

	# DEBUG: print free space
	local freespace=$(LC_ALL=C df -h)
	echo -e "$freespace" >> $DEST/${LOG_SUBPATH}/debootstrap.log
	display_alert "Free SD cache" "$(echo -e "$freespace" | awk -v mp="${SDCARD}" '$6==mp {print $5}')" "info"
	display_alert "Mount point" "$(echo -e "$freespace" | awk -v mp="${MOUNT}" '$6==mp {print $5}')" "info"

	# create list of installed packages for debug purposes
	chroot $SDCARD /bin/bash -c "dpkg -l | awk '/^ii/ { print \$2\",\"\$3 }'" > ${cache_fname}.list 2>&1

	# creating xapian index that synaptic runs faster
	if [[ $BUILD_DESKTOP == yes ]]; then
		display_alert "Recreating Synaptic search index" "Please wait" "info"
		chroot $SDCARD /bin/bash -c "[[ -f /usr/sbin/update-apt-xapian-index ]] && /usr/sbin/update-apt-xapian-index -u"
	fi

	# this is needed for the build process later since resolvconf generated file in /run is not saved
	rm $SDCARD/etc/resolv.conf
	echo "nameserver $NAMESERVER" >> $SDCARD/etc/resolv.conf

	# Remove `machine-id` (https://www.freedesktop.org/software/systemd/man/machine-id.html)
	# Note: This will mark machine `firstboot`
	echo "uninitialized" > "${SDCARD}/etc/machine-id"
	rm "${SDCARD}/var/lib/dbus/machine-id"

	# Mask `systemd-firstboot.service` which will prompt locale, timezone and root-password too early.
	# `armbian-first-run` will do the same thing later
	chroot $SDCARD /bin/bash -c "systemctl mask systemd-firstboot.service >/dev/null 2>&1"

	# stage: make rootfs cache archive
	display_alert "Ending debootstrap process and preparing cache" "$RELEASE" "info"
	sync
	# the only reason to unmount here is compression progress display
	# based on rootfs size calculation
	umount_chroot "$SDCARD"

	pack_rootfs "$cache_fname" "$SDCARD"
}
