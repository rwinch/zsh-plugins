export PATH=$(dirname $0):${PATH}

alias gbbdc=git-branches-disclosure-create

# gbbdc with the OSS branches filled in, extra options are passed on
gbbdca() {
	git-branches-disclosure-create $(spring-versions --type oss --field branch --line) "$@"
}
