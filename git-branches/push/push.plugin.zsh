export PATH=$(dirname $0):${PATH}

alias gbbph=git-branches-push

# gbbph with the OSS branches and the releases filled in, extra options are passed on
gbbpha() {
	git-branches-push $(spring-versions --type oss --field branch --line) --releases $(ghmr) "$@"
}
