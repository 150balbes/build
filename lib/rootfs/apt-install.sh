#!/usr/bin/env bash
install_deb_chroot() {

	local name=$1
	local desc=" from repository"

	local version=$(
		chroot "${SDCARD}" /bin/bash -c "apt-cache policy $name | \
			awk '/Candidate:/{print \$2}'"
		)
	if [ "$version" == "" ]; then
		display_alert "The package is missing" "${name}" "wrn"
		echo "The package [${name}] is missing" >> "${DEST}"/${LOG_SUBPATH}/install.log
		return 0
	elif [ "$version" == "(none)" ];then
		display_alert "The package cannot be installed" "${name}" "wrn"
		echo "The package [${name}] cannot be installed" >> "${DEST}"/${LOG_SUBPATH}/install.log
		return 0
	fi
	desc+=" $(
		chroot "${SDCARD}" /bin/bash -c "apt-cache madison $name | \
			awk -v v="$version" '{if(\$3 ~ v) print \$5}'"
	)"
	display_alert "Installing${desc}" "${name/\/root\//} ($version)"

	[[ $NO_APT_CACHER != yes ]] && \
	local apt_extra="-o Acquire::http::Proxy=\"http://${APT_PROXY_ADDR:-localhost:3142}\" -o Acquire::http::Proxy::localhost=\"DIRECT\""

	eval 'chroot "${SDCARD}" /bin/bash -c \
		"DEBIAN_FRONTEND=noninteractive apt-get -yq $apt_extra \
		--no-install-recommends install $name" ;EVALPIPE=(${PIPESTATUS[@]})' >> \
		"${DEST}"/${LOG_SUBPATH}/install.log 2>&1

	[[ ${EVALPIPE[0]} -ne 0 ]] &&
	exit_with_error "Installation of $name failed" "${BOARD} ${RELEASE} ${LINUXFAMILY}
	${CHOSEN_ROOTFS} ${CHOSEN_DESKTOP}"

	RET_VERSION=$version
}
