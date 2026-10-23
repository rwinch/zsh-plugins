export PATH=$(dirname $0):${PATH}

alias gbbcm=git-branches-check-merged

# gbbcm with the OSS branches filled in, extra options are passed on
gbbcma() {
	git-branches-check-merged $(spring-versions --type oss --field branch --line) "$@"
}
