export PATH=$(dirname $0):${PATH}

alias gbbr=git-branches-release

# gbbr rebase with this month's releases filled in, extra options are passed on
gbbra() {
	git-branches-release rebase $(ghmr) "$@"
}
