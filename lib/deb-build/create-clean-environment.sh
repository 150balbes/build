#!/usr/bin/env bash
#
# create_chroot <target_dir> <release> <arch>
#
create_chroot() {
	local target_dir="$1"
	local release=$2
	local arch=$3
	declare -A qemu_binary apt_mirror components
	qemu_binary['armhf']='qemu-arm-static'
	qemu_binary['arm64']='qemu-aarch64-static'
	apt_mirror['buster']="$DEBIAN_MIRROR"
	apt_mirror['bullseye']="$DEBIAN_MIRROR"
	apt_mirror['bookworm']="$DEBIAN_MIRROR"
	apt_mirror['focal']="$UBUNTU_MIRROR"
	apt_mirror['jammy']="$UBUNTU_MIRROR"
	apt_mirror['kinetic']="$UBUNTU_MIRROR"
	apt_mirror['lunar']="$UBUNTU_MIRROR"
	components['buster']='main,contrib'
	components['bullseye']='main,contrib'
	components['bookworm']='main,contrib'
	components['sid']='main,contrib'
	components['focal']='main,universe,multiverse'
	components['jammy']='main,universe,multiverse'
	components['lunar']='main,universe,multiverse'
	components['kinetic']='main,universe,multiverse'
	display_alert "Creating build chroot" "$release/$arch" "info"
	local includes="ccache,locales,git,ca-certificates,libfile-fcntllock-perl,rsync,python3,distcc,apt-utils"

	# perhaps a temporally workaround
	case $release in
		bullseye | bookworm | sid | focal | jammy | kinetic | lunar)
			includes=${includes}",perl-openssl-defaults,libnet-ssleay-perl"
			;;
	esac

	if [[ $NO_APT_CACHER != yes ]]; then
		local mirror_addr="http://localhost:3142/${apt_mirror[${release}]}"
	else
		local mirror_addr="http://${apt_mirror[${release}]}"
	fi

	mkdir -p "${target_dir}"
	cd "${target_dir}"
	debootstrap --variant=buildd \
		--components="${components[${release}]}" \
		--arch="${arch}" $DEBOOTSTRAP_OPTION \
		--foreign \
		--include="${includes}" "${release}" "${target_dir}" "${mirror_addr}"

	[[ $? -ne 0 || ! -f "${target_dir}"/debootstrap/debootstrap ]] &&
		exit_with_error "Create chroot first stage failed"

	cp /usr/bin/${qemu_binary[$arch]} "${target_dir}"/usr/bin/
	[[ ! -f "${target_dir}"/usr/share/keyrings/debian-archive-keyring.gpg ]] &&
		mkdir -p "${target_dir}"/usr/share/keyrings/ &&
		cp /usr/share/keyrings/debian-archive-keyring.gpg "${target_dir}"/usr/share/keyrings/

	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "/debootstrap/debootstrap --second-stage"'
	[[ $? -ne 0 || ! -f "${target_dir}"/bin/bash ]] && \
		exit_with_error "Create chroot second stage failed"

	[[ -f "${target_dir}"/etc/locale.gen ]] &&
		sed -i '/en_US.UTF-8/s/^# //g' "${target_dir}"/etc/locale.gen
	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "locale-gen; update-locale --reset LANG=en_US.UTF-8"'

	create_sources_list "$release" "${target_dir}"
	[[ $NO_APT_CACHER != yes ]] &&
		echo 'Acquire::http { Proxy "http://localhost:3142"; };' > "${target_dir}"/etc/apt/apt.conf.d/02proxy
	cat <<- EOF > "${target_dir}"/etc/apt/apt.conf.d/71-no-recommends
		APT::Install-Recommends "0";
		APT::Install-Suggests "0";
	EOF

	printf '#!/bin/sh\nexit 101' > "${target_dir}"/usr/sbin/policy-rc.d
	chmod 755 "${target_dir}"/usr/sbin/policy-rc.d
	rm "${target_dir}"/etc/resolv.conf 2> /dev/null
	echo "nameserver $NAMESERVER" > "${target_dir}"/etc/resolv.conf
	rm "${target_dir}"/etc/hosts 2> /dev/null
	echo "127.0.0.1 localhost" > "${target_dir}"/etc/hosts
	mkdir -p "${target_dir}"/root/{build,overlay,sources,output} "${target_dir}"/selinux
	if [[ -L "${target_dir}"/var/lock ]]; then
		rm -rf "${target_dir}"/var/lock 2> /dev/null
		mkdir -p "${target_dir}"/var/lock
	fi
	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "/usr/sbin/update-ccache-symlinks"'

	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "sed -i s/#deb-src/deb-src/g /etc/apt/sources.list"'

	display_alert "Upgrading packages in" "${target_dir}" "info"
	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "apt-get -q update; apt-get -q -y upgrade; apt-get clean"'
	date +%s > "$target_dir/root/.update-timestamp"

	# Install some packages with a large list of dependencies after the update.
	# This optimizes the process and eliminates looping when calculating
	# dependencies. Choose between a clean build environment and a full
	# development environment.
	case ${CHROOT_CACHE_VERSION} in
		clean) list="debhelper devscripts pkg-config lsb-release gawk sudo debian-keyring"
		;;
		devel) list="debhelper devscripts pkg-config udev lsb-release intltool-debian \
		autoconf autoconf-archive automake m4 dh-autoreconf dh-python dh-make \
		python3-dev dh-sequence-python3 python3-lxml python3-xlib \
		asciidoc asciidoc-dblatex doxygen graphviz docbook-to-man docbook-utils \
		docbook-xsl help2man po4a dblatex \
		gettext gettext-base texlive-xetex texlive-extra-utils texlive-font-utils \
		texlive-latex-recommended texlive-fonts-recommended texlive-lang-cyrillic \
		texlive-lang-european texlive-lang-french texlive-lang-german \
		texlive-lang-polish texlive-lang-spanish fonts-dejavu yapps2 patchutils \
		gpg fakeroot tree mc nano vim gawk sudo debian-keyring"
		;;
	esac

	eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
		/bin/bash -c "apt-get install \
		-q -y --no-install-recommends $list"'

	# Many packages require the PYTHON=/usr/bin/python3 variable to resolve
	# paths correctly.
	case ${CHROOT_CACHE_VERSION} in
		devel)
			eval 'LC_ALL=C LANG=C chroot "${target_dir}" \
			/bin/bash -c "apt-get install python-is-python3"'
			;;
	esac

	touch "${target_dir}"/root/.debootstrap-complete
	display_alert "Debootstrap complete" "${release}/${arch}" "info"
}

# Create a clean environment archive if it does not exist.
#
#	$1: $RELEASE
#	$2: $ARCH
#	$3: ${CHROOT_CACHE_VERSION}
#
create_clean_environment_archive() {
	local release=$1
	local arch=$2
	local t_name=${release}-${arch}-${3}
	local tmp_dir=$(mktemp -d ${TMPBASEDIR}/debootstrap-XXXXX)

	create_chroot "${tmp_dir}/${t_name}" "${release}" "${arch}"
	# create list of installed packages
	chroot "${tmp_dir}/${t_name}" /bin/bash -c \
		"dpkg -l | awk '/^ii/ { print \$2\",\"\$3 }'" > \
		"${SRC}/cache/buildpkg/${t_name}.list" 2>&1

	display_alert "Create a ${3} Environment archive" "${t_name}.tar.xz" "info"
	(
		tar -cp --directory="${tmp_dir}/" ${t_name} |
			pv -p -b -r -s "$(du -sb "${tmp_dir}/${t_name}" | cut -f1)" |
			pixz -4 > "${SRC}/cache/buildpkg/${t_name}.tar.xz"
	)
	rm -rf $tmp_dir
}
