export PATH=$(dirname $0):${PATH}

alias gwwc=git-worktrees-create

# gwwc with the usual branches filled in, extra options are passed on to the first run
gwwca() {
	local rc=0 rc2=0
	git-worktrees-create '[0-9]*.[0-9]*.x' 'disclosure/*' 'release/*' main docs-build "$@" || rc=$?
	git-worktrees-create --remote commercial --name-prefix commercial- --skip-missing-remote docs-build || rc2=$?
	return $(( rc != 0 ? rc : rc2 ))
}
