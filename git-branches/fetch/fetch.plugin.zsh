export PATH=$(dirname $0):${PATH}

alias gbbf=git-branches-fetch

# gbbf with the OSS branches and the releases filled in, extra options are passed on
gbbfa() {
	git-branches-fetch $(spring-versions --type oss --field branch --line) --releases $(ghmr) "$@"
}
