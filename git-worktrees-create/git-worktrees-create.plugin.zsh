export PATH=$(dirname $0):${PATH}

alias gwwc=git-worktrees-create

# gwwc with the usual branches filled in. Commercial runs first, so a .x branch
# that exists on both remotes comes from commercial and the oss run skips it.
gwwca() {
	local oss=oss commercial=commercial dry=()
	while [[ $# -gt 0 ]]; do
		case $1 in
			--oss-remote) [[ -n "$2" ]] || { echo "Error: --oss-remote requires a value" >&2; return 1 }; oss=$2; shift 2 ;;
			--commercial-remote) [[ -n "$2" ]] || { echo "Error: --commercial-remote requires a value" >&2; return 1 }; commercial=$2; shift 2 ;;
			--dry-run) dry=(--dry-run); shift ;;
			*)
				echo "Usage: gwwca [--oss-remote REMOTE] [--commercial-remote REMOTE] [--dry-run]" >&2
				return 1
				;;
		esac
	done
	local rc=0 rc2=0
	git-worktrees-create --remote $commercial --skip-missing-remote $dry '[0-9]*.[0-9]*.x' 'embargoed/*' 'release/*' || rc=$?
	git-worktrees-create --remote $oss $dry '[0-9]*.[0-9]*.x' main docs-build || rc2=$?
	return $(( rc != 0 ? rc : rc2 ))
}
