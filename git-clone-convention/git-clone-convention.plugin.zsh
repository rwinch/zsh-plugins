export PATH=$(dirname $0):${PATH}

# A function, not a script, so the cd (and the wd shortcuts) happen in the current shell.
# git-clone-convention does the work and prints the directory to change into on the first
# line of stdout, then one 'wd<TAB>NAME<TAB>PATH' line per wd shortcut to add.
clone() {
	local out wd_available=""
	(( $+functions[wd] || $+commands[wd] || $+aliases[wd] )) && wd_available=1
	out=$(GIT_CLONE_CONVENTION_WD=$wd_available git-clone-convention "$@") || return $?
	[[ -n $out ]] || return 0

	local lines=("${(@f)out}") line parts
	cd "${lines[1]}" || return 1
	print -u2 "Changed directory to ${PWD/#$HOME/~}"
	for line in "${(@)lines[2,-1]}"; do
		parts=("${(@ps:\t:)line}")
		[[ ${parts[1]} == wd ]] && wd addcd "${parts[3]}" "${parts[2]}" &> /dev/null
	done
	return 0
}
