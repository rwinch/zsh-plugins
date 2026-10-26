export PATH=$(dirname $0):${PATH}

alias gbbf=git-branches-fetch

# gbbf with the OSS branches and --embargoed filled in, extra options are passed on (--no-embargoed leaves the embargoed branches out)
gbbfa() {
	local -a embargoed=(--embargoed) no_embargoed
	zparseopts -D -E -- -no-embargoed=no_embargoed
	(( $#no_embargoed )) && embargoed=()
	git-branches-fetch $(spring-versions --type oss --field branch --line) $embargoed "$@"
}
