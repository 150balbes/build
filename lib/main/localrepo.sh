#!/usr/bin/env bash
#

# Create a new temporary local repository.
# Add all the collected packages for the target architecture to it.
# Publish the repositories before installing the packages in the image.
create_tmp_local_repo() {
	local files_to_add
	local aptly_root_dir=$(mktemp -d /tmp/aptly-XXXXX)
	trap "rm -rf \"${aptly_root_dir}\" " INT TERM
	local conf=${aptly_root_dir}/aptly.conf

	awk -v dir=\"$aptly_root_dir\", \
		-v dist=\"$DISTRIBUTION\", \
		-v code=\"$RELEASE\", \
		'{ if($1 ~ /"rootDir":/){
				sub($2, dir)
				print $0
			} else if ($1 ~ /"ppaDistributorID":/) {
				sub($2, dist)
				print $0
			} else if ($1 ~ /"ppaCodename":/) {
				sub($2, code)
				print $0
			} else {
				print $0
			}
		}' "${SRC}"/config/aptly-temp.conf > $conf

	display_alert "location of configuration file" "$conf" "info"
	cat $conf >&2 |& tee -a "${DEST}"/${LOG_SUBPATH}/aptly.log

	aptly -config="${conf}" repo create temp |& tee -a "${DEST}"/${LOG_SUBPATH}/aptly.log

	files_to_add="$(
		find "${DEB_STORAGE}/${RELEASE}/" -name '*'$ARCH'*'.deb
		find "${DEB_STORAGE}/" -maxdepth 1 -name '*'all'*'.deb
	)"
	for f in $files_to_add; do
		aptly -config="${conf}" repo add temp "$f" \
			|& tee -a "${DEST}"/${LOG_SUBPATH}/aptly.log
	done

	# -gpg-key="925644A6"
	aptly -keyring="${SRC}/packages/extras-buildpkgs/buildpkg-public.gpg" \
		  -secret-keyring="${SRC}/packages/extras-buildpkgs/buildpkg.gpg" \
		  -batch=true -config="${conf}" \
		  -gpg-key="925644A6" \
		  -passphrase="testkey1234" \
		  -component=temp \
		  -distribution="${RELEASE}" publish repo temp |& tee -a "${DEST}"/${LOG_SUBPATH}/aptly.log

	aptly -config="${conf}" -listen=":8189" serve &
	# # ./jammy [arm64, armhf] publishes {temp: [temp]}
	# deb http://vm-jammy:8189/ jammy temp

	export APTLY_PID_LOCAL=$!
	export APTLY_TMP_DIR=$aptly_root_dir
	echo "APTLY_PID_LOCAL=$APTLY_PID_LOCAL" |& tee -a "${DEST}"/${LOG_SUBPATH}/aptly.log
	echo "APTLY_TMP_DIR=$APTLY_TMP_DIR" |& tee -a "${DEST}"/${LOG_SUBPATH}/aptly.log
	trap "kill $APTLY_PID_LOCAL" INT TERM
}

# Add a local repository to the apt source list.
#
# <release>: bullseye|focal|jammy|kinetic|sid
# <basedir>: path to root directory
add_tmp_local_repo_to_source_list() {
	local release=$1
	local basedir=$2
	[ -d "$basedir" ] || exit_with_error "For the function [$0] bad argument [\$2=$2] folder not found"
	display_alert "Add tmp local repo" "$basedir" "info"
	# apt-key add is getting deprecated
	APT_VERSION=$(chroot "${basedir}" /bin/bash -c "apt -v | awk '{print \$2}'")
	if linux-version compare "${APT_VERSION}" ge 2.4.1; then
		# add buildpkg key
		mkdir -p "${basedir}"/usr/share/keyrings
		# change to binary form
		gpg --dearmor < "${SRC}"/packages/extras-buildpkgs/buildpkg.key > "${basedir}"/usr/share/keyrings/buildpkg.gpg
		SIGNED_BY="[signed-by=/usr/share/keyrings/buildpkg.gpg] "
	else
		# use old method for compatibility reasons
		cp "${SRC}"/packages/extras-buildpkgs/buildpkg.key "${basedir}"/tmp/buildpkg.key
		chroot "${basedir}" /bin/bash -c "cat /tmp/buildpkg.key | apt-key add - > /dev/null 2>&1"
	fi
	cat <<- 'EOF' > "${basedir}"/etc/apt/preferences.d/90-armbian-temp.pref
		Package: *
		Pin: origin "localhost"
		Pin-Priority: 1001
	EOF
	cat <<- EOF > "${basedir}"/etc/apt/sources.list.d/armbian-temp.list
		deb ${SIGNED_BY}http://localhost:8189/ $release temp
	EOF
	chroot "${basedir}" /bin/bash -c "apt update"
}

remove_tmp_local_repo() {
	local basedir=$1
	if [ -d $basedir ]; then
		display_alert "Remove tmp local repo" "$basedir" "info"
		rm "${basedir}"/usr/share/keyrings/buildpkg.gpg
		rm "${basedir}"/etc/apt/sources.list.d/armbian-temp.list 2>/dev/null
		rm "${basedir}"/etc/apt/preferences.d/90-armbian-temp.pref 2>/dev/null
		rm "${basedir}"/tmp/buildpkg.key 2>/dev/null
	else
		display_alert "Do not valid argumen for $0" "Dir not found" "err"
	fi
	if [ -n "$APTLY_PID_LOCAL" ]; then
		kill $APTLY_PID_LOCAL
		rm -rf $APTLY_TMP_DIR
	fi
}


# chroot_installpackages <list pkg>
#
chroot_installpackages() {
	local install_list="$@"
	display_alert "Installing extras-buildpkgs" "$install_list"
	chroot "${SDCARD}" /bin/bash -c "apt-get install $install_list" |& tee -a "${DEST}"/${LOG_SUBPATH}/install.log
}
