export PATH=$(dirname $0):${PATH}

alias gbbmf=git-branches-merge-forward

# gbbmf with the OSS branches filled in, extra options are passed on
gbbmfa() {
	git-branches-merge-forward $(spring-versions --type oss --field branch --line) "$@"
}
