export PATH=$(dirname $0):${PATH}

alias gbbpl=git-branches-pull

# gbbpl with the OSS branches and --embargoed filled in, extra options are passed on (--no-embargoed leaves the embargoed branches out)
gbbpla() {
	local -a embargoed=(--embargoed) no_embargoed
	zparseopts -D -E -- -no-embargoed=no_embargoed
	(( $#no_embargoed )) && embargoed=()
	git-branches-pull $(spring-versions --type oss --field branch --line) $embargoed "$@"
}
