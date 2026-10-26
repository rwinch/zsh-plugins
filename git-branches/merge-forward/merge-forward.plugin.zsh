export PATH=$(dirname $0):${PATH}

alias gbbmf=git-branches-merge-forward

# gbbmf with the OSS branches and --embargoed filled in, extra options are passed on (--no-embargoed leaves the embargoed branches out)
gbbmfa() {
	local -a embargoed=(--embargoed) no_embargoed
	zparseopts -D -E -- -no-embargoed=no_embargoed
	(( $#no_embargoed )) && embargoed=()
	git-branches-merge-forward $(spring-versions --type oss --field branch --line) $embargoed "$@"
}
