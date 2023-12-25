#!/usr/bin/env bash

while read -r file; do
	# shellcheck source=/dev/null
	source "$file"
done <<< "$(
	for d in general deb-build logging host bsp cli configuration compilation image rootfs main
	do
		find "${SRC}/lib/$d" -name "*.sh"
	done
)"
