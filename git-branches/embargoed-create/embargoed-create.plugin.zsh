export PATH=$(dirname $0):${PATH}

alias gbbec=git-branches-embargoed-create

# gbbec with the OSS branches filled in, extra options are passed on
gbbeca() {
	git-branches-embargoed-create $(spring-versions --type oss --field branch --line) "$@"
}
