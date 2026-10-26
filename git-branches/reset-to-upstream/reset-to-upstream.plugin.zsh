export PATH=$(dirname $0):${PATH}

alias gbbrtu=git-branches-reset-to-upstream

# gbbrtu with the OSS branches and --embargoed filled in, extra options are passed on (gbbrtua --undo undoes it) (--no-embargoed leaves the embargoed branches out)
gbbrtua() {
	local -a embargoed=(--embargoed) no_embargoed
	zparseopts -D -E -- -no-embargoed=no_embargoed
	(( $#no_embargoed )) && embargoed=()
	git-branches-reset-to-upstream $(spring-versions --type oss --field branch --line) $embargoed "$@"
}
