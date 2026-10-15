#!/bin/zsh
# Tests for git-check-merged. Builds throwaway repos (bare 'oss' and
# 'commercial' remotes, a seed repo that pushes to them, and a 'work' clone)
# under a temp dir and asserts exit codes and output.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-check-merged"
FILTER="$1"
pass=0
fail=0
out=""
rc=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true

# ---- fixture ----
# $R root, $S seed repo, $W work clone. Branches: 7.0.x main (oss);
# disclosure/{frozen,active}/{7.0.x,main}, release/7.0.1, release/7.0.1.1,
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
		for role in frozen active; do git -C $S branch disclosure/$role/$g $g; done
	done
	local rel from
	for rel in "release/7.0.1 disclosure/frozen/7.0.x" "release/7.0.1.1 disclosure/active/7.0.x" "release/7.1.0 disclosure/frozen/main"; do
		set -- ${=rel}
		git -C $S checkout -q -b $1 $2
		echo lic > $S/LICENSE; git -C $S add LICENSE; git -C $S commit -qm "license $1"
	done
	git -C $S checkout -q main
	git -C $S push -q oss main 7.0.x
	git -C $S push -q commercial 'refs/heads/disclosure/*' 'refs/heads/release/*'
	git clone -q -o oss $R/oss.git $W 2>/dev/null
	git -C $W remote add commercial $R/commercial.git
	git -C $W fetch -q commercial
	git -C $W branch -q --track 7.0.x oss/7.0.x
	for g in 7.0.x main; do
		for role in frozen active; do
			git -C $W branch -q --track disclosure/$role/$g commercial/disclosure/$role/$g
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
	[[ -n "$DEBUG" ]] && { echo "  \$ git-check-merged $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
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
t "args: no args, single branch, unknown option, duplicates, release format" '
	run; expect_rc 1
	run main; expect_rc 1; expect_out "single branch needs --disclosures"
	run -x a b; expect_rc 1; expect_out "Unknown option"
	run a a; expect_rc 1; expect_out "more than once"
	run -r 7.0; expect_rc 1; expect_out "Invalid release version"
'

t "local: merged chain exits 0, changes nothing, ignores dirty worktree" '
	echo dirty > $W/untracked.txt
	local before=$(git -C $W for-each-ref --format="%(refname) %(objectname)")
	run 7.0.x main; expect_rc 0
	expect_out "Checking local branches"
	expect_out "\(1\) 7.0.x -> main +merged"
	expect_out "All branches are merged properly \(local\)"
	[[ "$before" == "$(git -C $W for-each-ref --format="%(refname) %(objectname)")" ]]
'

t "local: unmerged commits are listed, exit 1" '
	commit_on $W 7.0.x fix.txt
	run 7.0.x main; expect_rc 1
	expect_out "7.0.x -> main +NOT MERGED, 1 commit"
	expect_out "git log --oneline main..7.0.x"
	expect_out "change fix.txt on 7.0.x"
	expect_out "1 of 1 check\(s\) not merged \(local\)"
'

t "remote: uses upstream refs without fetching" '
	commit_on $S 7.0.x up.txt; git -C $S push -q oss 7.0.x
	run -R 7.0.x main; expect_rc 0
	reject_out "Fetching"
	git -C $W fetch -q oss
	run -R 7.0.x main; expect_rc 1
	expect_out "Checking remote branches"
	expect_out "oss/7.0.x -> oss/main +NOT MERGED, 1 commit"
	run 7.0.x main; expect_rc 0
'

t "local and remote together, the error counts both" '
	commit_on $W 7.0.x fix.txt
	git -C $W push -q oss 7.0.x
	git -C $W fetch -q oss
	run -l -R 7.0.x main; expect_rc 1
	expect_out "Checking local branches"
	expect_out "Checking remote branches"
	expect_out "2 of 2 check\(s\) not merged \(local, remote\)"
'

t "disclosures and releases" '
	git -C $W branch -q release/7.0.1.1 commercial/release/7.0.1.1
	run -d 7.0.x main -r 7.0.1.1; expect_rc 0
	expect_out "\\(4\\) disclosure/frozen/7.0.x -> disclosure/frozen/main +merged"
	expect_out "release/7.0.1.1 contains disclosure/active/7.0.x +merged"
	run -R -d 7.0.x main -r 7.0.1; expect_rc 0
	expect_out "commercial/release/7.0.1 contains commercial/disclosure/frozen/7.0.x +merged"
	commit_on $W disclosure/frozen/7.0.x fz.txt
	git -C $W push -q commercial disclosure/frozen/7.0.x
	run -R -r 7.0.1; expect_rc 1
	expect_out "commercial/release/7.0.1 contains commercial/disclosure/frozen/7.0.x +NOT MERGED, 1 commit"
'

t "problems are reported together (missing branch, missing upstream, missing release)" '
	git -C $W branch nofollow main
	run 7.0.x nope nofollow; expect_rc 1; expect_out "nope: branch does not exist locally"
	run -l 7.0.x nofollow; expect_rc 0
	run -R 7.0.x nofollow; expect_rc 1; expect_out "nofollow: no upstream"
	run -l -r 7.0.1; expect_rc 1; expect_out "release/7.0.1: branch does not exist locally"
'

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
