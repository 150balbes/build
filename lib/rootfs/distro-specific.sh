#!/usr/bin/env bash
install_distribution_specific() {

	display_alert "Applying distribution specific tweaks for" "$RELEASE" "info"

	# disable broken service
	# the problem is in default misconfiguration
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload disable smartmontools.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload disable smartd.service >/dev/null 2>&1"

	# disable hostapd as it needs to be configured
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload disable hostapd.service  >/dev/null 2>&1"

	case $RELEASE in

		focal | jammy | kinetic | lunar )

			# by using default lz4 initrd compression leads to corruption, go back to proven method
			sed -i "s/^COMPRESS=.*/COMPRESS=gzip/" "${SDCARD}"/etc/initramfs-tools/initramfs.conf

			rm -f "${SDCARD}"/etc/update-motd.d/{10-uname,10-help-text,50-motd-news,80-esm,80-livepatch,90-updates-available,91-release-upgrade,95-hwe-eol}

			if [ -d "${SDCARD}"/etc/NetworkManager ]; then
				local RENDERER=NetworkManager
			else
				local RENDERER=networkd
			fi

			# DNS fix
			if [ -n "$NAMESERVER" ]; then
				sed -i "s/#DNS=.*/DNS=$NAMESERVER/g" "${SDCARD}"/etc/systemd/resolved.conf
			fi

			# Journal service adjustements
			sed -i "s/#Storage=.*/Storage=volatile/g" "${SDCARD}"/etc/systemd/journald.conf
			sed -i "s/#Compress=.*/Compress=yes/g" "${SDCARD}"/etc/systemd/journald.conf
			sed -i "s/#RateLimitIntervalSec=.*/RateLimitIntervalSec=30s/g" "${SDCARD}"/etc/systemd/journald.conf
			sed -i "s/#RateLimitBurst=.*/RateLimitBurst=10000/g" "${SDCARD}"/etc/systemd/journald.conf

			# Chrony temporal fix https://bugs.launchpad.net/ubuntu/+source/chrony/+bug/1878005
			if [ -f "${SDCARD}"/etc/default/chrony ]; then
				sed -i '/DAEMON_OPTS=/s/"-F -1"/"-F 0"/' "${SDCARD}"/etc/default/chrony
			fi

			# disable conflicting services
			chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload mask ondemand.service >/dev/null 2>&1"

			;;

	esac

	# configure language and locales
	display_alert "Configuring locales" "$DEST_LANG" "info"
	if [[ -f $SDCARD/etc/locale.gen ]]; then
		[ -n "$DEST_LANG" ] && sed -i "s/^# $DEST_LANG/$DEST_LANG/" $SDCARD/etc/locale.gen
		sed -i '/ C.UTF-8/s/^# //g' $SDCARD/etc/locale.gen
		sed -i '/en_US.UTF-8/s/^# //g' $SDCARD/etc/locale.gen
	fi
	eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -c "locale-gen"' ${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}
	[ -n "$DEST_LANG" ] && eval 'LC_ALL=C LANG=C chroot $SDCARD /bin/bash -c \
	"update-locale --reset LANG=$DEST_LANG LANGUAGE=$DEST_LANG LC_ALL=$DEST_LANG"' ${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}

	# Basic Netplan config. Let NetworkManager/networkd manage all devices on this system
	[[ -d "${SDCARD}"/etc/netplan ]] && cat <<- EOF > "${SDCARD}"/etc/netplan/armbian-default.yaml
		network:
			  version: 2
			  renderer: $RENDERER
	EOF

	# cleanup motd services and related files
	chroot "${SDCARD}" /bin/bash -c "systemctl disable motd-news.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl disable motd-news.timer >/dev/null 2>&1"

	# remove motd news from motd.ubuntu.com
	[[ -f "${SDCARD}"/etc/default/motd-news ]] && sed -i "s/^ENABLED=.*/ENABLED=0/" "${SDCARD}"/etc/default/motd-news

	# remove doubled uname from motd
	[[ -f "${SDCARD}"/etc/update-motd.d/10-uname ]] && rm "${SDCARD}"/etc/update-motd.d/10-uname

	# rc.local is not existing but one might need it
	install_rclocal

	# use list modules INITRAMFS
	if [ -f "${SRC}"/config/modules/"${MODULES_INITRD}" ]; then
		display_alert "Use file list modules INITRAMFS" "${MODULES_INITRD}"
		sed -i "s/^MODULES=.*/MODULES=list/" "${SDCARD}"/etc/initramfs-tools/initramfs.conf
		cat "${SRC}"/config/modules/"${MODULES_INITRD}" >> "${SDCARD}"/etc/initramfs-tools/modules
	fi
}

# create_sources_list <release> <basedir>
#
# <release>: bullseye|bookworm|sid|focal|jammy|kinetic|lunar
# <basedir>: path to root directory
#
create_sources_list() {
	local release=$1
	local basedir=$2
	[[ -z $basedir ]] && exit_with_error "No basedir passed to create_sources_list"

	display_alert "Create sources list for" "$release" "info"

	case $release in
		buster)
			cat <<- EOF > "${basedir}"/etc/apt/sources.list
				deb http://${DEBIAN_MIRROR} $release main contrib non-free
				#deb-src http://${DEBIAN_MIRROR} $release main contrib non-free

				deb http://${DEBIAN_MIRROR} ${release}-updates main contrib non-free
				#deb-src http://${DEBIAN_MIRROR} ${release}-updates main contrib non-free

				deb http://${DEBIAN_MIRROR} ${release}-backports main contrib non-free
				#deb-src http://${DEBIAN_MIRROR} ${release}-backports main contrib non-free

				deb http://${DEBIAN_SECURTY} ${release}/updates main contrib non-free
				#deb-src http://${DEBIAN_SECURTY} ${release}/updates main contrib non-free
			EOF
			;;

		bullseye | trixie)
			cat <<- EOF > "${basedir}"/etc/apt/sources.list
				deb http://${DEBIAN_MIRROR} $release main contrib non-free
				#deb-src http://${DEBIAN_MIRROR} $release main contrib non-free

				deb http://${DEBIAN_MIRROR} ${release}-updates main contrib non-free
				#deb-src http://${DEBIAN_MIRROR} ${release}-updates main contrib non-free

				deb http://${DEBIAN_MIRROR} ${release}-backports main contrib non-free
				#deb-src http://${DEBIAN_MIRROR} ${release}-backports main contrib non-free

				deb http://${DEBIAN_SECURTY} ${release}-security main contrib non-free
				#deb-src http://${DEBIAN_SECURTY} ${release}-security main contrib non-free
			EOF
			;;

		bookworm)
			cat <<- EOF > "${basedir}"/etc/apt/sources.list
				deb http://${DEBIAN_MIRROR} $release main contrib non-free non-free-firmware
				#deb-src http://${DEBIAN_MIRROR} $release main contrib non-free non-free-firmware

				deb http://${DEBIAN_MIRROR} ${release}-updates main contrib non-free non-free-firmware
				#deb-src http://${DEBIAN_MIRROR} ${release}-updates main contrib non-free non-free-firmware

				deb http://${DEBIAN_MIRROR} ${release}-backports main contrib non-free non-free-firmware
				#deb-src http://${DEBIAN_MIRROR} ${release}-backports main contrib non-free non-free-firmware

				deb http://${DEBIAN_SECURTY} ${release}-security main contrib non-free non-free-firmware
				#deb-src http://${DEBIAN_SECURTY} ${release}-security main contrib non-free non-free-firmware
			EOF
			;;

		sid) # sid is permanent unstable development and has no such thing as updates or security
			cat <<- EOF > "${basedir}"/etc/apt/sources.list
				deb http://${DEBIAN_MIRROR} $release main contrib non-free
				#deb-src http://${DEBIAN_MIRROR} $release main contrib non-free
			EOF
			;;

		focal | jammy | kinetic | lunar)
			cat <<- EOF > "${basedir}"/etc/apt/sources.list
				deb http://${UBUNTU_MIRROR} $release main restricted universe multiverse
				#deb-src http://${UBUNTU_MIRROR} $release main restricted universe multiverse

				deb http://${UBUNTU_MIRROR} ${release}-security main restricted universe multiverse
				#deb-src http://${UBUNTU_MIRROR} ${release}-security main restricted universe multiverse

				deb http://${UBUNTU_MIRROR} ${release}-updates main restricted universe multiverse
				#deb-src http://${UBUNTU_MIRROR} ${release}-updates main restricted universe multiverse

				deb http://${UBUNTU_MIRROR} ${release}-backports main restricted universe multiverse
				#deb-src http://${UBUNTU_MIRROR} ${release}-backports main restricted universe multiverse
			EOF
			;;
	esac
}

# Adding Vendor sources list to /etc/apt/sources.list.d/ and authentication key
#
add_armbian_sources_list() {
	local release=$1
	local basedir=$2
	[[ -z $basedir ]] && exit_with_error "No basedir passed to create_sources_list"

	display_alert "Adding Armbian repository and authentication key" "/etc/apt/sources.list.d/armbian.list" "info"

	# apt-key add is getting deprecated
	APT_VERSION=$(chroot "${basedir}" /bin/bash -c "apt --version | cut -d\" \" -f2")
	if linux-version compare "${APT_VERSION}" ge 2.4.1; then
		# add armbian key
		mkdir -p "${basedir}"/usr/share/keyrings
		# change to binary form
		gpg --dearmor < "${SRC}"/config/armbian.key > "${basedir}"/usr/share/keyrings/armbian.gpg
		SIGNED_BY="[signed-by=/usr/share/keyrings/armbian.gpg] "
	else
		# use old method for compatibility reasons
		cp "${SRC}"/config/armbian.key "${basedir}"
		chroot "${basedir}" /bin/bash -c "cat armbian.key | apt-key add - > /dev/null 2>&1"
	fi

	# stage: add armbian repository and install key
	local ARMBIAN_MIRROR
	if [[ $DOWNLOAD_MIRROR == "china" ]]; then
		ARMBIAN_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/armbian"
	elif [[ $DOWNLOAD_MIRROR == "bfsu" ]]; then
		ARMBIAN_MIRROR="http://mirrors.bfsu.edu.cn/armbian"
	elif [[ -n $LOCAL_MIRROR ]]; then
		# local package server if defined. Suitable for development
		ARMBIAN_MIRROR=$LOCAL_MIRROR
	else
		ARMBIAN_MIRROR="http://"$([[ $BETA == yes ]] && echo "beta" || echo "apt")".armbian.com"
	fi

	cat <<- EOF > "${basedir}"/etc/apt/sources.list.d/armbian.list
		deb ${SIGNED_BY}${ARMBIAN_MIRROR} $release main ${release}-utils ${release}-desktop
	EOF

	# Packages available locally from the list have the highest priority of 999
	# All packages from the external Armbian repository have a very low priority
	# and can only be installed if this repository is specified, not automatically.
	cat <<- 'EOF' > "${basedir}"/etc/apt/preferences.d/10-armbian.pref
		Package: armbian-* linux-image-* linux-headers-* linux-libc-dev linux-u-boot-*
		Pin: origin ""
		Pin-Priority: 999

		Package: *
		Pin: release o=armbian
		Pin-Priority: -10
	EOF

}
