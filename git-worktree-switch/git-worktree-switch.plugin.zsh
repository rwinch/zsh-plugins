# git-worktree-switch is a function (not a script on PATH) because it needs to
# cd the calling shell into the worktree.

_git_worktree_switch_usage() {
	cat <<USAGE
Usage: git-worktree-switch <branch>
       git-worktree-switch (-c|-C) <new-branch> [<start-point>]

Like 'git switch', but cd's into the worktree for the branch.

  - If a worktree for <branch> exists, cd into it
  - Else if <branch> exists locally, create a worktree at ../<branch> and cd into it
  - Else if <branch> exists on exactly one remote, create a tracking branch and
    a worktree at ../<branch> and cd into it
  - With -c, create <new-branch> from <start-point> (default HEAD) and a
    worktree at ../<new-branch>, then cd into it
  - With -C, same as -c but resets <new-branch> if it already exists

Worktrees are siblings of the current worktree (same layout as git-worktrees-create).
USAGE
}

git-worktree-switch() {
	local create="" branch="" start=""

	while [[ $# -gt 0 ]]; do
		case $1 in
			-c|-C)
				if [[ -z "$2" ]]; then
					echo "fatal: switch '${1#-}' requires a value" >&2
					return 1
				fi
				create="$1"; branch="$2"; shift 2
				;;
			-h|--help)
				_git_worktree_switch_usage
				return 0
				;;
			-*)
				echo "fatal: unknown option: $1" >&2
				_git_worktree_switch_usage >&2
				return 1
				;;
			*)
				if [[ -z "$branch" ]]; then
					branch="$1"
				elif [[ -n "$create" && -z "$start" ]]; then
					start="$1"
				else
					echo "fatal: unexpected argument: $1" >&2
					return 1
				fi
				shift
				;;
		esac
	done

	if [[ -z "$branch" ]]; then
		_git_worktree_switch_usage >&2
		return 1
	fi

	local root
	if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
		echo "fatal: not a git repository" >&2
		return 1
	fi

	# Worktrees for slashed branches (release/1.0) live one or more levels deeper,
	# so strip the current branch name from the root when it matches.
	local cur base
	cur=$(git symbolic-ref --short -q HEAD)
	if [[ -n "$cur" && "$root" == */"$cur" ]]; then
		base="${root%/$cur}"
	else
		base="${root:h}"
	fi
	local target="${base}/${branch}"
	local existing=""

	# Is the branch already checked out in some worktree?
	local line wt=""
	while IFS= read -r line; do
		case $line in
			"worktree "*) wt="${line#worktree }" ;;
			"branch refs/heads/${branch}") existing="$wt"; break ;;
		esac
	done < <(git worktree list --porcelain)

	if [[ -z "$create" ]]; then
		if [[ -z "$existing" && -d "$target" ]] && git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
			existing="$target"
		fi
		if [[ -n "$existing" ]]; then
			cd "$existing" || return 1
			echo "Switched to worktree $PWD (branch $branch)"
			return 0
		fi

		if git show-ref --verify --quiet "refs/heads/$branch"; then
			echo "Creating worktree ../$branch"
			git worktree add "$target" "$branch" || return 1
		else
			local -a candidates
			candidates=(${(f)"$(git for-each-ref --format='%(refname:short)' "refs/remotes/*/$branch")"})
			if (( ${#candidates} == 0 )); then
				echo "fatal: invalid reference: $branch" >&2
				return 1
			elif (( ${#candidates} > 1 )); then
				echo "fatal: '$branch' matches multiple remotes: ${candidates[*]}" >&2
				return 1
			fi
			echo "Creating worktree ../$branch tracking ${candidates[1]}"
			git worktree add --track -b "$branch" "$target" "${candidates[1]}" || return 1
		fi
	else
		if [[ -n "$existing" && "$create" == "-c" ]]; then
			echo "fatal: a branch named '$branch' already exists" >&2
			return 1
		fi
		if [[ "$create" == "-c" ]] && git show-ref --verify --quiet "refs/heads/$branch"; then
			echo "fatal: a branch named '$branch' already exists" >&2
			return 1
		fi
		if [[ -n "$existing" ]]; then
			echo "fatal: '$branch' is checked out at $existing" >&2
			return 1
		fi
		echo "Creating branch '$branch' from '${start:-HEAD}'"
		echo "Creating worktree ../$branch"
		local flag="-b"; [[ "$create" == "-C" ]] && flag="-B"
		git worktree add "$flag" "$branch" "$target" ${start:+"$start"} || return 1
	fi

	cd "$target" || return 1
	echo "Switched to worktree $PWD (branch $branch)"
}

alias gws=git-worktree-switch
