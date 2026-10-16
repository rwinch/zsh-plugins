export PATH=$(dirname $0):${PATH}

alias gbbrtu=git-branches-reset-to-upstream

# gbbrtu with the OSS branches and the releases filled in, extra options are passed on (gbbrtua --undo undoes it)
gbbrtua() {
	git-branches-reset-to-upstream $(spring-versions --type oss --field branch --line) --releases $(ghmr) "$@"
}
