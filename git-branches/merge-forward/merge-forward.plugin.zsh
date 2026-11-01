export PATH=$(dirname $0):${PATH}

alias gbbmf=git-branches-merge-forward

# gbbmf with the OSS branches and --embargoed filled in, extra options are passed on (--no-embargoed leaves the embargoed branches out).
# On a branch named feature/<branch>/<name> it also infers --feature <name> and starts the chain at <branch>:
# an explicit --feature NAME wins, and only trims the chain when NAME is the name of the current branch.
gbbmfa() {
	local -a embargoed=(--embargoed) no_embargoed feat branches
	local current name base idx
	zparseopts -D -E -- -no-embargoed=no_embargoed -feature:=feat f:=feat
	(( $#no_embargoed )) && embargoed=()
	(( $#feat )) && name=${feat[-1]#=} && feat=(--feature $name)

	branches=($(spring-versions --type oss --field branch --line))

	current=$(git branch --show-current 2>/dev/null)
	if [[ $current == feature/*/* ]]; then
		name=${current##*/}
		base=${current#feature/}
		base=${base%/*}
		if (( ! $#feat )) || [[ ${feat[2]} == $name ]]; then
			idx=${branches[(Ie)$base]}
			if (( idx )); then
				branches=(${branches[idx,-1]})
				(( $#feat )) || feat=(--feature $name)
			else
				print -u2 "gbbmfa: '$base' is not one of the OSS branches, not inferring anything from '$current'"
			fi
		fi
	fi

	git-branches-merge-forward $branches $embargoed $feat "$@"
}
