export PATH=$(dirname $0):${PATH}

alias gbbpl=git-branches-pull

# gbbpl with the OSS branches filled in, extra options are passed on
gbbpla() {
	git-branches-pull $(spring-versions --type oss --field branch --line) "$@"
}
