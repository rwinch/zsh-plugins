#!/bin/zsh
# Tests for git-fetch-branches. Builds throwaway repos (bare 'oss' and
# 'commercial' remotes, a seed repo that pushes to them, and a 'work' clone)
# under a temp dir and asserts exit codes and output.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-fetch-branches"
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
	[[ -n "$DEBUG" ]] && { echo "  \$ git-fetch-branches $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
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

# push a new commit to REMOTE's BRANCH via the seed repo (without fetching in work)
publish() {
	git -C $S checkout -q $2
	echo "up $RANDOM" >> $S/up.txt; git -C $S add up.txt; git -C $S commit -qm "up on $2"
	git -C $S push -q $1 $2
}

t "args: none, unknown option, duplicates, bad release" '
	run; expect_rc 1
	run -x a; expect_rc 1; expect_out "Unknown option"
	run a a; expect_rc 1; expect_out "more than once"
	run -r 7.0; expect_rc 1; expect_out "Invalid release version"
'

t "up to date" '
	run 7.0.x; expect_rc 0
	expect_out "Fetching .oss."
	expect_out "7.0.x +oss/7.0.x +up to date"
	expect_out "Fetched 1 remote\(s\), 1 branch\(es\): 0 behind, 0 ahead, 0 diverged, 1 up to date"
'

t "fetches and reports behind, changes no local branch" '
	publish oss 7.0.x
	local before=$(sha 7.0.x)
	run 7.0.x; expect_rc 0
	expect_out "7.0.x +oss/7.0.x +behind 1"
	[[ $(sha 7.0.x) == $before ]]
	[[ $(sha oss/7.0.x) != $before ]]
'

t "reports ahead and diverged without failing" '
	commit_on $W 7.0.x a.txt
	run 7.0.x; expect_rc 0; expect_out "ahead 1"
	publish oss 7.0.x
	run 7.0.x; expect_rc 0
	expect_out "diverged \(1 local, 1 upstream\)"
	expect_out "1 diverged"
'

t "dirty worktree is not a problem" '
	echo x > $W/untracked
	run 7.0.x; expect_rc 0
'

t "disclosures and releases fetch each remote once" '
	git -C $W branch -q --track release/7.0.1 commercial/release/7.0.1
	run -d 7.0.x main -r 7.0.1; expect_rc 0
	expect_out "disclosure/frozen/7.0.x"
	expect_out "disclosure/active/main"
	expect_out "release/7.0.1 "
	expect_out "2 remote\(s\), 7 branch\(es\)"
	[[ $(print -r -- "$out" | grep -c "^Fetching .oss.") -eq 1 ]]
'

t "upstream deleted on the remote is reported as gone" '
	git -C $R/oss.git branch -q 7.1.x main
	git -C $W fetch -q oss
	git -C $W branch -q --track 7.1.x oss/7.1.x
	git -C $R/oss.git branch -q -D 7.1.x
	run 7.1.x; expect_rc 0
	expect_out "7.1.x +oss/7.1.x +gone"
	expect_out "1 gone"
'

t "problems are all reported before any fetch" '
	git -C $W branch -q loose 7.0.x
	run loose nope; expect_rc 1
	expect_out "no upstream"
	expect_out "does not exist locally"
	reject_out "Fetching"
'

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
