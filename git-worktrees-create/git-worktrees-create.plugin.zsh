export PATH=$(dirname $0):${PATH}

alias gwwc=git-worktrees-create

# gwwc with the usual branches filled in, the only option is --dry-run
gwwca() {
	local -a opts
	if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --dry-run ) ]]; then
		echo "Usage: gwwca [--dry-run]" >&2
		return 1
	fi
	opts=("$@")
	local rc=0 rc2=0
	git-worktrees-create $opts '[0-9]*.[0-9]*.x' 'disclosure/*' 'release/*' main docs-build || rc=$?
	git-worktrees-create $opts --remote commercial --name-prefix commercial- --skip-missing-remote docs-build || rc2=$?
	return $(( rc != 0 ? rc : rc2 ))
}
