#!/bin/zsh
# Tests for git-branches-disclosure-create. Builds throwaway repos (bare 'oss' and
# 'commercial' remotes, a seed repo and a 'work' clone) under a temp dir and asserts
# exit codes and output.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-branches-disclosure-create"
FILTER="$1"
pass=0
fail=0
out=""
rc=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true

# $R root, $S seed repo, $W work clone. Branches 7.0.x 7.1.x main on oss, nothing
# disclosure related anywhere.
setup() {
	R=$(mktemp -d); R=${R:A}
	S=$R/seed; W=$R/work
	git init -q --bare -b main $R/oss.git
	git init -q --bare -b main $R/commercial.git
	git init -q -b main $S
	git -C $S remote add oss $R/oss.git
	git -C $S remote add commercial $R/commercial.git
	echo base > $S/f; git -C $S add f; git -C $S commit -qm base
	git -C $S branch 7.0.x
	echo more > $S/g; git -C $S add g; git -C $S commit -qm more
	git -C $S branch 7.1.x
	git -C $S push -q oss main 7.0.x 7.1.x
	git clone -q -o oss $R/oss.git $W 2>/dev/null
	git -C $W remote add commercial $R/commercial.git
	git -C $W fetch -q commercial
}

run() {
	set +e
	out=$(cd $W && $SCRIPT "$@" 2>&1)
	rc=$?
	set -e
	[[ -n "$DEBUG" ]] && { echo "  \$ git-branches-disclosure-create $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
	return 0
}

expect_rc() { [[ $rc -eq $1 ]] || { echo "    expected rc $1, got $rc"; echo "${out}" | sed 's/^/      | /'; return 1; } }
expect_out() { print -r -- "$out" | grep -qE -- "$1" || { echo "    expected output to match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; } }
cfg() { git -C $W config "branch.$1.$2" }
has_branch() { git -C $W show-ref --verify --quiet "refs/heads/$1" }

t() {
	local name="$1"
	[[ -n "$FILTER" && "$name" != *$FILTER* ]] && return
	setup
	( set -e; [[ -n "$TRACE" ]] && set -x; eval "$2" )
	if [[ $? -eq 0 ]]; then
		echo "ok   $name"; (( pass++ ))
	else
		echo "FAIL $name"; (( fail++ ))
	fi
	rm -rf $R
}

# ---------------------------------------------------------------------------
t "args: no args, unknown option, missing value, duplicate, --help" '
	run; expect_rc 1; expect_out "At least one generation"
	run -x 7.0.x; expect_rc 1; expect_out "Unknown option"
	run --oss-remote; expect_rc 1; expect_out "requires a remote name"
	run 7.0.x 7.0.x; expect_rc 1; expect_out "more than once"
	run --help; expect_rc 0; expect_out "^Usage: git-branches-disclosure-create"
'

t "creates frozen and active at the oss sha with the commercial upstream" '
	run 7.0.x main; expect_rc 0
	expect_out "Created 4 branch"
	expect_out "git push --atomic commercial disclosure/frozen/7.0.x disclosure/active/7.0.x disclosure/frozen/main disclosure/active/main"
	local b
	for b in disclosure/frozen/7.0.x disclosure/active/7.0.x; do
		[[ $(git -C $W rev-parse $b) == $(git -C $W rev-parse oss/7.0.x) ]]
		[[ $(cfg $b remote) == commercial ]]
		[[ $(cfg $b merge) == refs/heads/$b ]]
	done
	[[ $(git -C $W rev-parse disclosure/active/main) == $(git -C $W rev-parse oss/main) ]]
'

t "the printed push command works and leaves the branch in sync with its upstream" '
	run 7.0.x; expect_rc 0
	git -C $W push -q --atomic commercial disclosure/frozen/7.0.x disclosure/active/7.0.x
	git -C $W fetch -q commercial
	[[ -z $(git -C $W rev-list --left-right "commercial/disclosure/frozen/7.0.x...disclosure/frozen/7.0.x") ]]
'

t "dry run creates nothing" '
	run --dry-run 7.0.x; expect_rc 0
	expect_out "Would create"
	expect_out "upstream commercial/disclosure/frozen/7.0.x"
	! has_branch disclosure/frozen/7.0.x
'

t "custom remote names" '
	git -C $W remote rename oss upstream
	git -C $W remote rename commercial private
	run --oss-remote upstream --commercial-remote private 7.0.x; expect_rc 0
	[[ $(cfg disclosure/frozen/7.0.x remote) == private ]]
'

t "problems: missing oss branch and existing local branch are reported together" '
	git -C $W branch disclosure/frozen/7.0.x oss/7.0.x
	run 7.0.x 7.9.x; expect_rc 1
	expect_out "2 problem"
	expect_out "oss/7.9.x: does not exist"
	expect_out "disclosure/frozen/7.0.x: already exists locally"
	! has_branch disclosure/active/7.0.x
'

t "problems: missing commercial remote" '
	git -C $W remote remove commercial
	run 7.0.x; expect_rc 1; expect_out "remote .commercial. does not exist"
	! has_branch disclosure/frozen/7.0.x
'

t "problems: branch already on commercial points at git branch --track" '
	git -C $S push -q commercial 7.0.x:refs/heads/disclosure/active/7.0.x
	git -C $W fetch -q commercial
	run 7.0.x; expect_rc 1
	expect_out "disclosure/active/7.0.x: already exists on commercial"
	expect_out "git branch --track disclosure/active/7.0.x commercial/disclosure/active/7.0.x"
	! has_branch disclosure/frozen/7.0.x
'

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
