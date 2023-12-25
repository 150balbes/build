#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Let's have unique way of displaying alerts
#-------------------------------------------------------------------------------
display_alert() {
	# log function parameters to separate file.log
	if [[ -n "${LOG_OUTPUT_FILE}" ]]; then
		TARGET_LOG="${LOG_OUTPUT_FILE}"
	elif [[ -n "${DEST}" ]]; then
		TARGET_LOG="${DEST}"/${LOG_SUBPATH}/output.log
	else
		TARGET_LOG="/dev/null"
	fi

	local tmp=""
	[[ -n $2 ]] && tmp="[\e[0;33m $2 \x1B[0m]"

	case $3 in
		err)
			echo -e "[\e[0;31m error \x1B[0m] $1 $tmp"
			echo "[ error ] $1 $2" >> "$TARGET_LOG"
			;;

		wrn)
			echo -e "[\e[0;35m warn \x1B[0m] $1 $tmp"
			echo "[ warn ] $1 $2" >> "$TARGET_LOG"
			;;

		ext)
			echo -e "[\e[0;32m o.k. \x1B[0m] \e[1;32m$1\x1B[0m $tmp"
			echo "[ o.k. ] $1 $2" >> "$TARGET_LOG"
			;;

		info)
			echo -e "[\e[0;32m info \x1B[0m] $1 $tmp"
			echo "[ info ] $1 $2" >> "$TARGET_LOG"
			;;

		line)
			echo -e "  $1 \e[0;33m$2\x1B[0m"
			echo -e "  $1 $2" >> "$TARGET_LOG"
			;;

		*)
			echo -e "[\e[0;32m .... \x1B[0m] $1 $tmp"
			echo "[ .... ] $1 $2" >> "$TARGET_LOG"
			;;
	esac
}

# is a formatted output of the values of variables
# from the list at the place of the function call.
#
# The LOG_OUTPUT_FILE variable must be defined in the calling function
# before calling the `show_checklist_variables` function and unset after.
#
show_checklist_variables() {
	local checklist=$*
	local var pval
	local log_file=${LOG_OUTPUT_FILE:-"${SRC}"/output/${LOG_SUBPATH}/trash.log}
	local _line=${BASH_LINENO[0]}
	local _function=${FUNCNAME[1]}
	local _file=$(basename "${BASH_SOURCE[1]}")

	echo -e "Show variables in function: $_function" "[$_file:$_line]\n" >> $log_file

	for var in $checklist; do
		eval pval=\$$var
		echo -e "\n$var =:" >> $log_file
		if [ $(echo "$pval" | awk -F"/" '{print NF}') -ge 4 ]; then
			printf "%s\n" $pval >> $log_file
		else
			printf "%-30s %-30s %-30s %-30s\n" $pval >> $log_file
		fi
	done
}
