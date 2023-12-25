#!/usr/bin/env bash

# chroot_prepare_distccd <release> <arch>
#
preparing_distccd() {
	local release=$1
	local arch=$2
	local dest=/tmp/distcc/${release}-${arch}
	declare -A gcc_version gcc_type
	gcc_version['buster']='8.3'
	gcc_version['bullseye']='9.2'
	gcc_version['bookworm']='10.2'
	gcc_version['sid']='10.2'
	gcc_version['bionic']='5.4'
	gcc_version['focal']='9.2'
	gcc_version['hirsute']='10.2'
	gcc_version['jammy']='12'
	gcc_version['kinetic']='12'
	gcc_version['lunar']='12'
	gcc_type['armhf']='arm-linux-gnueabihf-'
	gcc_type['arm64']='aarch64-linux-gnu-'
	rm -f "${dest}"/cmdlist
	mkdir -p "${dest}"
	local toolchain_path
	toolchain_path=$(find_toolchain "${gcc_type[${arch}]}" "== ${gcc_version[${release}]}")
	ln -sf "${toolchain_path}/${gcc_type[${arch}]}gcc" "${dest}"/cc
	echo "${dest}/cc" >> "${dest}"/cmdlist
	for compiler in gcc cpp g++ c++; do
		echo "${dest}/$compiler" >> "${dest}"/cmdlist
		echo "${dest}/${gcc_type[$arch]}${compiler}" >> "${dest}"/cmdlist
		ln -sf "${toolchain_path}/${gcc_type[${arch}]}${compiler}" "${dest}/${compiler}"
		ln -sf "${toolchain_path}/${gcc_type[${arch}]}${compiler}" "${dest}/${gcc_type[${arch}]}${compiler}"
	done
	mkdir -p /var/run/distcc/
	touch /var/run/distcc/"${release}-${arch}".pid
	chown -R distccd /var/run/distcc/
	chown -R distccd /tmp/distcc
}

# distcc_build_implement
#
# When we build only locally, we don't need "distcc". When we use a parallel
# network-distributed assembly, we must clearly define who is the server and
# who are the clients for the target architecture\distribution in this function.
# It returns true when it analyzes or initializes the necessary variables.
#
distcc_build_implement() {
	false
}
