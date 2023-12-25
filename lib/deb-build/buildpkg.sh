#!/usr/bin/env bash


build_packages_per_release_arch() {
	local target_release="bullseye bookworm focal jammy lunar sid"
	local target_arch="armhf arm64 amd64"
	local release arch

	for release in $target_release; do
		for arch in $target_arch; do
			chroot_build_packages release=$release arch=$arch
		done
	done
}

# chroot_build_packages
#
chroot_build_packages() {
	local built_ok=()
	local failed=()
	while [[ "${1}" == *=* ]]; do
		p=${1%%=*}
		v=${1##*=}
		shift
		eval "local $p=\"$v\""
	done
	local selected_packages=$@
	mkdir -p ${SRC}/cache/buildpkg

	local release="${release:-$RELEASE}"
	local arch="${arch:-$ARCH}"

	display_alert "Starting package building process" "$release/$arch" "info"
	if [[ -n "$selected_packages" ]]; then
		display_alert "Selected packages for chroot: " "$selected_packages" "info"
	else
		exit_with_error "No packages selected"
	fi

	local t_name=${release}-${arch}-${CHROOT_CACHE_VERSION}

	if [ "$(findmnt -n -o FSTYPE --target /tmp)"  == "tmpfs" ]; then
	   tmpsyze=$(($(findmnt -n -b -o AVAIL --target /tmp) / (1024 * 1024)))
	   display_alert "Size /tmp as tmpfs" "$tmpsyze M" "ext"
	   [[ $tmpsyze -ge 8000 ]] && TMPBASEDIR="/tmp"
	else
	   TMPBASEDIR="${SRC}/.tmp"
	fi

	# Create a clean environment archive if it does not exist.
	if [ ! -f "${SRC}/cache/buildpkg/${t_name}.tar.xz" ]; then
		create_clean_environment_archive $release $arch ${CHROOT_CACHE_VERSION}
	fi

	# Unpack the clean environment archive, if it exists.
	if [ -f "${SRC}/cache/buildpkg/${t_name}.tar.xz" ]; then
		local tmp_dir=$(mktemp -d ${TMPBASEDIR}/build-XXXXX)
		(
			cd $tmp_dir
			display_alert "Unpack the clean environment" "${t_name}.tar.xz" "info"
			tar -xJf "${SRC}/cache/buildpkg/${t_name}.tar.xz" ||
				exit_with_error "Is not extracted" "${SRC}/cache/buildpkg/${t_name}.tar.xz"
		)
		build_dir="$tmp_dir/${t_name}"
	else
		exit_with_error "Creating chroot failed" "${release}/${arch}"
	fi

	[[ -f /var/run/distcc/"${release}-${arch}".pid ]] &&
		kill "$(< "/var/run/distcc/${release}-${arch}.pid")" > /dev/null 2>&1

	if distcc_build_implement ; then
		preparing_distccd "${release}" "${arch}"
		local distcc_bindaddr="127.0.0.2"
		# DISTCC_TCP_DEFER_ACCEPT=0
		DISTCC_CMDLIST=/tmp/distcc/${release}-${arch}/cmdlist \
				TMPDIR=/tmp/distcc distccd --daemon \
				--pid-file "/var/run/distcc/${release}-${arch}.pid" \
				--listen $distcc_bindaddr --allow 127.0.0.0/24 \
				--log-file "/tmp/distcc/${release}-${arch}.log" --user distccd
	fi

	[[ -d $build_dir ]] ||
		exit_with_error "Clean Environment is not visible" "$build_dir"

	local t=$build_dir/root/.update-timestamp
	if [[ ! -f ${t} || $((($(date +%s) - $(< "${t}")) / 86400)) -gt 7 ]]; then
		display_alert "Upgrading packages" "$release/$arch" "info"
		systemd-nspawn -a -q \
			-D "${build_dir}" \
			/bin/bash -c "apt-get -q update; apt-get -q -y upgrade; apt-get clean"
		date +%s > "${t}"
		display_alert "Repack a clean Environment archive after upgrading" "${t_name}.tar.xz" "info"
		rm "${SRC}/cache/buildpkg/${t_name}.tar.xz"
		(
			tar -cp --directory="${tmp_dir}/" ${t_name} |
				pv -p -b -r -s "$(du -sb "${tmp_dir}/${t_name}" | cut -f1)" |
				pixz -4 > "${SRC}/cache/buildpkg/${t_name}.tar.xz"
		)
		# create list of installed packages
		rm "${SRC}/cache/buildpkg/${t_name}.list"
		chroot "${tmp_dir}/${t_name}" /bin/bash -c \
			"dpkg -l | awk '/^ii/ { print \$2\",\"\$3 }'" > \
			"${SRC}/cache/buildpkg/${t_name}.list" 2>&1
	fi

	local config_for_packages=""
	local src_dir
	local work_dir=${WORK_DIR:-${USERPATCHES_PATH}}/packages/deb-build

	for package_name in $selected_packages; do

		unset package_repo package_ref package_builddeps \
			  package_install_chroot package_install_target \
			  package_version package_upstream_version pkg_target_dir \
			  package_component "package_builddeps_${release}" \
			  change_custom_release

		local pkg_target_dir="${DEB_STORAGE}/${release}/${package_name}"
		mkdir -p "${pkg_target_dir}"

		# Processing variables for several variants of the build scenario.
		if [ -f "${work_dir}"/${package_name}/config ]; then
			source "${work_dir}"/${package_name}/config
		elif [ -f "${SRC}"/packages/deb-build/${package_name}/config ]; then
			source "${SRC}"/packages/deb-build/${package_name}/config
			sudo --user="$SUDOUSER" --group=sudo {
			mkdir -p "${work_dir}"/${package_name}
			cp -r "${SRC}"/packages/deb-build/${package_name}/config "${work_dir}"/${package_name}/}
		fi

		processing_build_scenario

		# check if needs building
		if [[ -f $(find "${pkg_target_dir}/" -name ${package_name}_${package_version}*${arch}.deb) ]]; then
			display_alert "Packages are up to date" "$package_name $release/$arch" "info"
			continue
		fi

		# Delete the environment if there was a build in it.
		# And unpack the clean environment again.
		if [[ -f "${build_dir}"/root/build.sh ]] &&
		   [[ -d $tmp_dir ]] && [[ "${CHROOT_CACHE_VERSION}" == clean ]]; then
			rm -rf $tmp_dir
			local tmp_dir=$(mktemp -d ${TMPBASEDIR}/build-XXXXX)
			(
				cd $tmp_dir
				display_alert "Unpack the clean environment" "${t_name}.tar.xz" "info"
				tar -xJf "${SRC}/cache/buildpkg/${t_name}.tar.xz" ||
					exit_with_error "Is not extracted" "${SRC}/cache/buildpkg/${t_name}.tar.xz"
			)
			local build_dir="$tmp_dir/${t_name}"
		fi

		display_alert "Building packages" "$package_name $release/$arch" "ext"
		local ts=$(date +%s)
		local dist_builddeps_name="package_builddeps_${release}"
		[[ -v $dist_builddeps_name ]] && package_builddeps="${package_builddeps} ${!dist_builddeps_name}"

		local pkg_linux_libcdev
		if ! pkg_linux_libcdev="$(
				find ${DEB_STORAGE}/${release}/linux-${BRANCH}/ \
						-name 'linux-libc-dev*' 2>/dev/null)"; then
			display_alert "Used system pkg:" " linux-libc-dev " "info"
		elif [ $(echo -e "$pkg_linux_libcdev" | wc -l) -gt 1 ]; then
			display_alert "An ambiguous situation." "Multiple linux-libc-dev files found" "wrn"
			display_alert "Used system pkg:" " linux-libc-dev " "info"
		else
			display_alert "Used pkg:" " $pkg_linux_libcdev " "info"
			cp $pkg_linux_libcdev "${build_dir}"/root/
			file_linux_libcdev="/root/$(basename $pkg_linux_libcdev)"
		fi

		# create build script
		LOG_OUTPUT_FILE=/root/build-"${package_name}".log
		create_build_script
		unset LOG_OUTPUT_FILE

		if [ "$CMDLINE" != "" ]; then
			command_line='/bin/bash'
		else
			command_line='/bin/bash -c \"/root/build.sh\"'
		fi

		eval systemd-nspawn -a -q \
				--capability=CAP_MKNOD -D "${build_dir}" \
				--tmpfs=/root/build \
				--tmpfs=/tmp:mode=777 \
				--bind "${work_dir}"/:/root/overlay \
				--bind "${pkg_target_dir}"/:/root/output \
				--bind-ro "${SRC}"/cache/sources/:/root/sources \
				$command_line \
				${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/${LOG_SUBPATH}/buildpkg.log'} 2>&1 \
				';EVALPIPE=(${PIPESTATUS[@]})'

		if [[ ${EVALPIPE[0]} -ne 0 ]]; then
			failed+=("$package_name:$release/$arch")
		else
			built_ok+=("$package_name:$release/$arch")
			#mv "${build_dir}"/root/{*.deb,*.changes,*.buildinfo} "${pkg_target_dir}/"
		fi

		mv "${build_dir}"/root/build.sh "$DEST/${LOG_SUBPATH}/${package_name}-build.sh.log"
		mv "${build_dir}"/root/*.log "$DEST/${LOG_SUBPATH}/"

		local te=$(date +%s)
		local runtime_secs=$((te - ts))
		local runtime_m_s="$(printf "%dm:%02ds" $((runtime_secs / 60)) $((runtime_secs % 60)))"
		display_alert "Build time $package_name " "$runtime_m_s" "info"
	done

	# Delete a temporary directory
	if [ -d $tmp_dir ]; then rm -rf $tmp_dir; fi

	# cleanup for distcc
	if [ -f /var/run/distcc/${release}-${arch}.pid ]; then
		kill $(< /var/run/distcc/${release}-${arch}.pid)
	fi

	if [[ ${#built_ok[@]} -gt 0 ]]; then
		display_alert "Following packages were built without errors" "" "info"
		for p in ${built_ok[@]}; do
			display_alert "$p"
		done
	fi

	if [[ ${#failed[@]} -gt 0 ]]; then
		display_alert "Following packages failed to build" "" "wrn"
		for p in ${failed[@]}; do
			display_alert "$p"
		done
	fi
}

# Check the debian build version
# depends: devscripts
#   "$1" - Full path to the pkgname/debian directory
#   "$2" - Full path to target build directory
check_debian_build_version() {
	local src_dir="$1"
	local user_work_dir="${2:-${src_dir}/..}"

	for n in $(
		cd $src_dir
		uscan -v --destdir "$user_work_dir" | \
		awk '$1 ~ /^version|^package|newversion/{sub(/\$/,"",$1); print $1 $2 $3}'
		)
	do
		eval "local $n"
	done

	local tarball=$(find ${user_work_dir}/ -name ${package}_${version}.orig.tar'*')
	if [ "$tarball" == "" ]; then
		$(
			cd $src_dir
			uscan --download-current-version --destdir "$user_work_dir"  2>/dev/null
		)
		tarball=$(find ${user_work_dir}/ -name ${package}_${version}.orig.tar'*')
	fi

	display_alert "package=:" "${package}" "line"
	display_alert "version=:" "${version}" "line"
	display_alert "tarball=:" "${tarball}" "line"
	if [ -v newversion ] && [ "${version}" != "$newversion" ];then
		local newtarball=$(find ${user_work_dir}/ -name ${package}_${newversion}.orig.tar'*')
		display_alert "newversion=:" "$newversion" "line"
		display_alert "newtarball=:" "${newtarball}" "line"
	fi
	PKG_SRC_FILE="${tarball}"
	PKG_ORIG_VERSION="$version"

} # apt-cache show devscripts



# Processing variables for several variants of the build scenario.
# The "packages/deb-build/${package_name}" folder must contain at least
# two archives:
#              ${package_name}_${version}.orig.tar.xz
#              ${package_name}_${version}-${localversion}.debian.tar.xz
# and a        ${package_name}_${version}-${localversion}.dsc           file
#
# package_version=${version}-${localversion}
#
processing_build_scenario() {
	# awk '/^Version:/ {gsub(/[1-9]:||-.*/, "");print $2}' *.dsc
	# GNU Awk 4.2.1, API: 2.0
	if package_version=$(
		awk '/^Version:/ {sub(/[1-9]:/, "");print $2}' \
			${work_dir}/${package_name}/*.dsc 2>/dev/null
		) && \
		[ -f ${work_dir}/${package_name}/${package_name}_${package_version}.debian.tar.* ] && \
		[ -f ${work_dir}/${package_name}/${package_name}_${package_version%-*}.orig.tar.* ]; then
		# local version=${package_version%-*}
		# local localversion=${package_version#*-}
		method="dsc"

	elif [ -n "${package_repo}" ] && [ -n "$package_ref" ]; then
		method="git"
		waiter_local_git url="$package_repo" name=origin dir=${package_name} "$package_ref"
		if ! $(declare -f prebuild 1>&2>/dev/null) ; then
			echo "# TODO function < prebuild >"
		fi
		# Exclude the epoch and the local version so that the original archive
		# can be created.
		if package_version=$(
			dpkg-parsechangelog -S Version \
				-l "${SRC}"/cache/sources/${package_name}/debian/changelog | \
				awk '{gsub(/[1-9]:/, "", $0);print $0}' 2>/dev/null
			)
		then
			PKG_ORIG_VERSION=${package_version%-*}
		fi
		#DEBUG
		#display_alert "package_version=" "$package_version" "warn"
		#display_alert "PKG_ORIG_VERSION=" "$PKG_ORIG_VERSION" "warn"

	elif package_version=$(
			dpkg-parsechangelog -S Version \
				-l "${work_dir}"/${package_name}/${package_name}-*/debian/changelog 2>/dev/null
			) && [ -f "${work_dir}"/${package_name}/${package_name}-${package_version%-*}/debian/watch ]; then
		method="watch"
		check_debian_build_version "${work_dir}/${package_name}/${package_name}-${package_version%-*}"

	elif [ -f "${SRC}"/packages/deb-build/${package_name}/debian/watch ] &&
		package_version=$(
			dpkg-parsechangelog -S Version -l "${SRC}"/packages/deb-build/${package_name}/debian/changelog 2>/dev/null
			) && [ ! -d "${work_dir}"/${package_name}/${package_name}-${package_version%-*}/debian ]; then
		mkdir -p -m 775 "${work_dir}"/${package_name}
		check_debian_build_version "${SRC}/packages/deb-build/${package_name}" "${work_dir}/${package_name}"
# TODO		$(cd "${work_dir}/${package_name}"; sudo --user=$SUDOUSER --group=sudo tar -xaf $PKG_SRC_FILE)
		sudo --user=$SUDOUSER --group=sudo \
		rsync -aq "${SRC}"/packages/deb-build/${package_name}/debian \
			"${work_dir}"/${package_name}/${package_name}-${package_version%-*}/
		# version=$PKG_ORIG_VERSION
		method="watch"

	else
		display_alert "Attempt to rebuild the system package" "${package_name}" "info"
		method="src"
	fi

	display_alert "method=:" "${method}" "ext"
}

# create build script
create_build_script() {
	cat <<-EOF > "${build_dir}"/root/build.sh
	#!/bin/bash
	export PATH="/usr/lib/ccache:\$PATH"
	export HOME="/root"
	export DEBIAN_FRONTEND="noninteractive"
	export DEB_BUILD_OPTIONS="nocheck noautodbgsym"
	export DEBFULLNAME="$MAINTAINER"
	export DEBEMAIL="$MAINTAINERMAIL"

	LOG_OUTPUT_FILE=$LOG_OUTPUT_FILE
	$(declare -f display_alert)

	$(declare -f install_pkg_deb)
	EOF

	if $(declare -f prebuild 1>&2>/dev/null) ; then
		cat <<-EOF >> "${build_dir}"/root/build.sh

		$(declare -f prebuild)
		EOF
	fi

	# distcc is disabled to prevent compilation issues due
	# to different host and cross toolchain configurations
	if distcc_build_implement ; then
		cat <<-EOF >> "${build_dir}"/root/build.sh

		export DISTCC_HOSTS="$distcc_bindaddr"
		export CCACHE_PREFIX="distcc"
		# uncomment for debug
		#export CCACHE_RECACHE="true"
		#export CCACHE_DISABLE="true"
		EOF
	fi

	case $method in
		dsc)
		cat <<EOF>> "${build_dir}"/root/build.sh

cd /root/overlay/${package_name}
dpkg-source --extract ${package_name}_${package_version}.dsc /root/build/${package_name}-${package_version%-*}
cd /root/build/${package_name}-${package_version%-*}
EOF
		;;
		src)
		# When the source package has a different name than the binary one,
		# extract the name and version from the source file.
		cat <<EOF>> "${build_dir}"/root/build.sh

cd /root/build
display_alert "Get source for package" "${package_name}" "info"
apt-get source ${package_name}
for p in \$(
	awk '/^Version:/{
			sub(/[1-9]:/, "", \$2)
			print "package_version=" \$2}
		/^Source:/{print "source=" \$2}' *.dsc
	)
do
	eval \$p
done

display_alert "Install build dependencies" "\${source} (\${package_version%-*})" "info"
apt-get build-dep -y \${source} 2>> \$LOG_OUTPUT_FILE

cd \${source}-\${package_version%-*}
EOF
		;;
		watch)
		cat <<EOF>> "${build_dir}"/root/build.sh

if tarball=\$(find /root/overlay/${package_name}/ -name ${package_name}_${PKG_ORIG_VERSION}.orig.tar.'*') &&
	[ -d /root/overlay/${package_name}/${package_name}-${PKG_ORIG_VERSION}/debian ]; then
		cd /root/build/
		tar -xaf \$tarball
		rsync -aq /root/overlay/${package_name}/${package_name}-${PKG_ORIG_VERSION}/debian \
			${package_name}-${PKG_ORIG_VERSION}/
		#dpkg-source --build ${package_name}-${PKG_ORIG_VERSION}
		cd /root/build/${package_name}-${PKG_ORIG_VERSION}
else
	display_alert "Failed find sourse" "tarball=\$tarball"
	display_alert "Or failed find sourse" "${package_name}/${package_name}-${PKG_ORIG_VERSION}/debian"
	exit 1
fi
EOF
		;;
		git)
		cat <<EOF>> "${build_dir}"/root/build.sh

if [ -d /root/sources/${package_name}/.git ] && [ "${PKG_ORIG_VERSION}" != "" ]; then
	display_alert "Copying sources git to" "/root/build/${package_name}-${PKG_ORIG_VERSION}/" "info"
	mkdir -p /root/build/${package_name}-${PKG_ORIG_VERSION}
	rsync -aq /root/sources/"${package_name}/" /root/build/${package_name}-${PKG_ORIG_VERSION}/
else
	display_alert "Failed find sourse" "/root/sources/${package_name}/.git" "err"
	exit 1
fi

if \$(declare -f prebuild 1>&2>/dev/null) ; then
	cd /root/build/${package_name}-${PKG_ORIG_VERSION}
	prebuild || exit 1
fi
#cd /root/build/
#dpkg-source --build ${package_name}-${PKG_ORIG_VERSION}
cd /root/build/${package_name}-${PKG_ORIG_VERSION}
EOF
		;;
	esac

	cat <<EOF>> "${build_dir}"/root/build.sh

package_builddeps="$package_builddeps"
if [ -z "\$package_builddeps" ]; then
	# Calculate build dependencies by a standard dpkg function
	#echo "\$(dpkg-checkbuilddeps)" >&2
	package_builddeps="\$(dpkg-checkbuilddeps |& awk -F'dependencies:' '{print \$2}')"
fi

if [[ -n "\${package_builddeps} sudo" ]]; then
	echo "install_pkg_deb verbose \${package_builddeps} sudo" >&2
	install_pkg_deb verbose \${package_builddeps} ${file_linux_libcdev} sudo
fi

# set upstream version
[[ -n "${package_upstream_version}" ]] && \\
	debchange --preserve --newversion "${package_upstream_version}" "Import from upstream"

# set local version
if ${change_custom_release:-false}; then
	debchange -l~${VENDOR}2+ "Custom $VENDOR release"
fi
package_version=\$(dpkg-parsechangelog -S Version -l debian/changelog)

display_alert "Building package ${package_name}" "\$package_version" "info"
# Set the number of build threads and certainly send
# the standard error stream to the log file.
dpkg-buildpackage -b -us -j${NCPU_CHROOT:-2} 2>>\$LOG_OUTPUT_FILE
exit_status=\$?

if [[ \$exit_status -eq 0 ]]; then
	display_alert "Done building source:\${source}" "$package_name (\${package_version#*:}) $release/$arch" "ext"

	result=\$(
		find ../ -maxdepth 1 -mindepth 1 -type f
		)
	display_alert "Move files:\n" "\$result" "line"
	sudo --group=sudo mv \$result /root/output/ #2>/dev/null
	exit 0
else
	display_alert "Failed building" "$package_name $release/$arch" "err"
	exit 2
fi
EOF

	chmod +x "${build_dir}"/root/build.sh
}
