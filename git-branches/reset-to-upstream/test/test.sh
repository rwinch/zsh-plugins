#!/bin/zsh
# Tests for git-branches-reset-to-upstream. Builds throwaway repos (bare 'oss' and
# 'commercial' remotes, a seed repo that pushes to them, and a 'work' clone)
# under a temp dir and asserts exit codes and output.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-branches-reset-to-upstream"
FILTER="$1"
pass=0
fail=0
out=""
rc=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true

# ---- fixture ----
# $R root, $S seed repo, $W work clone. Branches: 7.0.x main (oss);
# embargoed/{frozen,active}/{7.0.x,main}, release/7.0.1, release/7.0.1.1,
# release/7.1.0 (commercial). Each release has one release-only LICENSE commit.
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
	local g role
	for g in 7.0.x main; do
		for role in frozen active; do git -C $S branch embargoed/$role/$g $g; done
	done
	local rel from
	for rel in "release/7.0.1 embargoed/frozen/7.0.x" "release/7.0.1.1 embargoed/active/7.0.x" "release/7.1.0 embargoed/frozen/main"; do
		set -- ${=rel}
		git -C $S checkout -q -b $1 $2
		echo lic > $S/LICENSE; git -C $S add LICENSE; git -C $S commit -qm "license $1"
	done
	git -C $S checkout -q main
	git -C $S push -q oss main 7.0.x
	git -C $S push -q commercial 'refs/heads/embargoed/*' 'refs/heads/release/*'
	git clone -q -o oss $R/oss.git $W 2>/dev/null
	git -C $W remote add commercial $R/commercial.git
	git -C $W fetch -q commercial
	git -C $W branch -q --track 7.0.x oss/7.0.x
	for g in 7.0.x main; do
		for role in frozen active; do
			git -C $W branch -q --track embargoed/$role/$g commercial/embargoed/$role/$g
		done
	done
	git -C $W checkout -q 7.0.x
}

# commit FILE on BRANCH in dir DIR (checks the branch out there)
commit_on() {
	git -C $1 checkout -q $2
	echo "$2 $RANDOM" >> $1/$3
	git -C $1 add $3
	git -C $1 commit -qm "change $3 on $2"
}

run() {
	set +e
	out=$(cd $W && $SCRIPT "$@" 2>&1)
	rc=$?
	set -e
	[[ -n "$DEBUG" ]] && { echo "  \$ git-branches-reset-to-upstream $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
	return 0
}

expect_rc() { [[ $rc -eq $1 ]] || { echo "    expected rc $1, got $rc"; echo "${out}" | sed 's/^/      | /'; return 1; } }
expect_out() { print -r -- "$out" | grep -qE -- "$1" || { echo "    expected output to match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; } }
reject_out() { print -r -- "$out" | grep -qE -- "$1" && { echo "    output must not match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; }; return 0 }
lacks_file() { ! git -C $W show "$1:$2" > /dev/null 2>&1 }
has_file() { git -C $W show "$1:$2" > /dev/null 2>&1 }
not_contains() { ! git -C $W merge-base --is-ancestor "$1" "$2" }
contains() { git -C $W merge-base --is-ancestor "$1" "$2" }
branch_of() { git -C $1 rev-parse --abbrev-ref HEAD }

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
sha() { git -C $W rev-parse "$1" }

t "args: none, unknown option, duplicates, --releases is gone" '
	run; expect_rc 1
	run -x a; expect_rc 1; expect_out "Unknown option"
	run a a; expect_rc 1; expect_out "more than once"
	run --releases 7.0.1; expect_rc 1; expect_out "Unknown option"
	run -r 7.0.1; expect_rc 1; expect_out "Unknown option"
'

t "up to date: nothing to reset" '
	run 7.0.x; expect_rc 0; expect_out "Everything is up to date"
'

t "resets an ahead branch in its worktree and lists discarded sha" '
	commit_on $W 7.0.x fix.txt
	local before=$(sha 7.0.x)
	run 7.0.x; expect_rc 0
	expect_out "1 local commit discarded"
	[[ $(sha 7.0.x) == $(sha oss/7.0.x) ]]
	expect_out "${before[1,7]}"
	lacks_file 7.0.x fix.txt
'

t "dry-run changes nothing" '
	commit_on $W 7.0.x fix.txt
	local before=$(sha 7.0.x)
	run -n 7.0.x; expect_rc 0
	expect_out "Dry run"
	[[ $(sha 7.0.x) == $before ]]
'

t "branch not checked out is moved with branch -f" '
	git -C $W branch -q --track main oss/main 2>/dev/null || true
	commit_on $W main fix.txt
	git -C $W checkout -q 7.0.x
	run main; expect_rc 0
	expect_out "not checked out"
	[[ $(sha main) == $(sha oss/main) ]]
	[[ $(branch_of $W) == 7.0.x ]]
'

t "diverged branch is reset" '
	git -C $W branch -q --track main oss/main 2>/dev/null || true
	commit_on $W main local.txt
	git -C $W checkout -q 7.0.x
	git -C $S checkout -q main
	echo up >> $S/up.txt; git -C $S add up.txt; git -C $S commit -qm up
	git -C $S push -q oss main
	git -C $W fetch -q oss
	run main; expect_rc 0
	expect_out "diverged"
	[[ $(sha main) == $(sha oss/main) ]]
'

t "embargoed branches are expanded" '
	commit_on $W embargoed/frozen/7.0.x a.txt
	git -C $W checkout -q 7.0.x
	run -e 7.0.x; expect_rc 0
	expect_out "embargoed/active/7.0.x"
	[[ $(sha embargoed/frozen/7.0.x) == $(sha commercial/embargoed/frozen/7.0.x) ]]
'

t "dirty worktree and missing branch are rejected together" '
	echo x > $W/untracked
	run 7.0.x nope; expect_rc 1
	expect_out "working tree not clean"
	expect_out "does not exist locally"
	expect_out "Nothing was reset"
'

t "no upstream is rejected" '
	git -C $W branch -q loose 7.0.x
	run loose; expect_rc 1; expect_out "no upstream"
'

t "undo: restores a worktree branch and a moved branch" '
	git -C $W checkout -q main
	commit_on $W main m.txt
	commit_on $W 7.0.x a.txt
	local a=$(sha 7.0.x) m=$(sha main)
	git -C $W checkout -q 7.0.x
	run 7.0.x main; expect_rc 0
	[[ $(sha 7.0.x) == $(sha oss/7.0.x) ]]
	[[ $(sha main) == $(sha oss/main) ]]
	run --undo 7.0.x main; expect_rc 0
	expect_out "Restoring 7.0.x in"
	expect_out "Restoring main \(not checked out"
	expect_out "Restored 2 branch"
	[[ $(sha 7.0.x) == $a ]]
	[[ $(sha main) == $m ]]
	has_file 7.0.x a.txt
	[[ -z $(git -C $W status --porcelain) ]]
'

t "undo: dry run prints the plan and changes nothing" '
	commit_on $W 7.0.x a.txt
	local a=$(sha 7.0.x)
	run 7.0.x; expect_rc 0
	run --undo --dry-run 7.0.x; expect_rc 0
	expect_out "Would undo"
	expect_out "was ${a[1,7]} before the reset \(1 commit restored\)"
	expect_out "Dry run, nothing was undone"
	[[ $(sha 7.0.x) == $(sha oss/7.0.x) ]]
	run -n -u 7.0.x; expect_rc 0; expect_out "Dry run, nothing was undone"
	run --undo 7.0.x; expect_rc 0
	[[ $(sha 7.0.x) == $a ]]
'

t "undo: a branch that moved since the reset is a problem unless forced" '
	commit_on $W 7.0.x a.txt
	local a=$(sha 7.0.x)
	run 7.0.x; expect_rc 0
	commit_on $W 7.0.x later.txt
	local later=$(sha 7.0.x)
	run --undo 7.0.x; expect_rc 1
	expect_out "7.0.x: has moved since the reset"
	expect_out "Nothing was undone"
	[[ $(sha 7.0.x) == $later ]]
	run --undo --dry-run 7.0.x; expect_rc 1
	run --force-undo 7.0.x; expect_rc 0
	[[ $(sha 7.0.x) == $a ]]
	lacks_file 7.0.x later.txt
'

t "undo: no reset in the reflog is skipped, a second undo is a no-op" '
	commit_on $W 7.0.x a.txt
	local a=$(sha 7.0.x)
	run 7.0.x; expect_rc 0
	run --undo 7.0.x main; expect_rc 0
	[[ $(sha 7.0.x) == $a ]]
	run --undo 7.0.x; expect_rc 0
	expect_out "already at ${a[1,7]}, nothing to undo"
	expect_out "Nothing to undo"
	run --undo main; expect_rc 0
	expect_out "no reset found in the reflog, skipped"
	expect_out "Nothing to undo"
'

t "undo: dirty worktree and missing branch are rejected together" '
	commit_on $W 7.0.x a.txt
	run 7.0.x; expect_rc 0
	echo x > $W/untracked
	run --undo 7.0.x nope; expect_rc 1
	expect_out "working tree not clean"
	expect_out "does not exist locally"
	expect_out "Nothing was undone"
'

t "undo: --embargoed is expanded" '
	commit_on $W 7.0.x a.txt
	git -C $W checkout -q -b feat 7.0.x
	commit_on $W embargoed/frozen/7.0.x r.txt
	local r=$(sha embargoed/frozen/7.0.x)
	git -C $W checkout -q 7.0.x
	run -e 7.0.x; expect_rc 0
	run -u -e 7.0.x; expect_rc 0
	expect_out "embargoed/frozen/7.0.x .*was ${r[1,7]} before the reset"
	[[ $(sha embargoed/frozen/7.0.x) == $r ]]
'

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
