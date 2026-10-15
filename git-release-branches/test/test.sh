#!/bin/zsh
# Tests for git-release-branches. Builds throwaway repos (bare 'oss' and
# 'commercial' remotes, a seed repo that pushes to them, and a 'work' clone)
# under a temp dir and asserts exit codes and output.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-release-branches"
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

# Commit on BRANCH in the seed, push it to commercial, and move the work clone's
# local branch to it (what a merge forward followed by a push leaves behind).
advance() {
	commit_on $S $1 ${2:-fix.txt}
	git -C $S push -q commercial $1
	git -C $W fetch -q commercial
	git -C $W branch -q -f $1 commercial/$1
}

# Nothing is fetched by the plugin, so fetch like git-fetch-branches would (unless NOFETCH=1)
run() {
	set +e
	[[ -z "$NOFETCH" ]] && git -C $W fetch -q --all --prune
	out=$(cd $W && $SCRIPT "$@" 2>&1)
	rc=$?
	set -e
	[[ -n "$DEBUG" ]] && { echo "  \$ git-release-branches $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
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
t "args: no args, unknown option, --help" '
	run; expect_rc 1; expect_out "At least one release version"
	run -x 7.0.1; expect_rc 1; expect_out "Unknown option"
	run --releases 7.0.1; expect_rc 1; expect_out "Unknown option"
	run --help; expect_rc 0; expect_out "^Usage: git-release-branches"
'

t "args: release version format and base rules" '
	run 7.0; expect_rc 1; expect_out "Invalid release version"
	run 7.1.1-RC1; expect_rc 1; expect_out "patch 0"
	run 7.0.1,7.0.2; expect_rc 1; expect_out "at most one per base"
	run 7.0.1.1,7.0.2.1; expect_rc 1; expect_out "at most one per base"
	run 7.0.1,7.0.1; expect_rc 1; expect_out "more than once"
'

t "args: versions may be separate arguments" '
	run -n 7.0.1 7.0.1.1; expect_rc 0
	expect_out "Everything is up to date"
'

t "up to date: one-liner, also on a dry run" '
	run 7.0.1,7.0.1.1; expect_rc 0
	[[ "$out" == *"Everything is up to date, nothing to rebase."* ]]
	reject_out "Rebasing"
	run -n 7.0.1; expect_rc 0
	expect_out "Everything is up to date, nothing to rebase."
'

t "rebase: release becomes the disclosure branch plus release-only commits" '
	advance disclosure/frozen/7.0.x
	advance disclosure/active/7.0.x
	local old=$(git -C $W rev-parse commercial/release/7.0.1)
	run 7.0.1,7.0.1.1; expect_rc 0
	for r in release/7.0.1 release/7.0.1.1; do
		has_file $r fix.txt && has_file $r LICENSE || { echo "    $r wrong"; return 1 }
	done
	contains disclosure/frozen/7.0.x release/7.0.1
	contains disclosure/active/7.0.x release/7.0.1.1
	[[ $(git -C $W rev-list --count disclosure/frozen/7.0.x..release/7.0.1) -eq 1 ]]
	expect_out "Rebasing release/7.0.1 onto disclosure/frozen/7.0.x \.\.\. done"
	expect_out "Done\. Push when ready:"
	expect_out "git push --atomic commercial"
	expect_out "\+release/7.0.1 "
	expect_out "--force-with-lease=release/7.0.1:$old"
	[[ $(branch_of $W) == 7.0.x ]]
'

t "rebase: dry run changes nothing and exits 0" '
	advance disclosure/frozen/7.0.x
	local before=$(git -C $W for-each-ref --format="%(refname) %(objectname)")
	run -n 7.0.1; expect_rc 0
	expect_out "release/7.0.1 +on disclosure/frozen/7.0.x +would rebase 1 commit\(s\) \[commercial\]"
	expect_out "Dry run, nothing changed\."
	reject_out "git push"
	[[ "$before" == "$(git -C $W for-each-ref --format="%(refname) %(objectname)")" ]]
	[[ $(branch_of $W) == 7.0.x ]]
'

t "rebase: up to date once the force push happened" '
	advance disclosure/frozen/7.0.x
	run 7.0.1; expect_rc 0
	git -C $W push -q -f commercial release/7.0.1
	run 7.0.1; expect_rc 0
	expect_out "Everything is up to date, nothing to rebase."
'

t "create: missing release is created from its base, pushed plainly" '
	git -C $R/commercial.git branch -q -D release/7.1.0
	run -n 7.1.0; expect_rc 0
	expect_out "release/7.1.0 +on disclosure/frozen/main +would create from commercial/disclosure/frozen/main"
	expect_out "no 7.1.x branch, newest generation"
	run 7.1.0; expect_rc 0
	expect_out "Creating release/7.1.0 from commercial/disclosure/frozen/main \.\.\. done"
	[[ $(git -C $W rev-parse release/7.1.0) == $(git -C $W rev-parse disclosure/frozen/main) ]]
	lacks_file release/7.1.0 LICENSE
	expect_out "git push --atomic commercial"
	expect_out "^    release/7.1.0$"
	reject_out "force-with-lease"
	reject_out "\+release"
	[[ $(branch_of $W) == 7.0.x ]]
'

t "create: a missing release next to a rebuilt one, lease only for the rebuilt one" '
	git -C $R/commercial.git branch -q -D release/7.1.0
	advance disclosure/frozen/7.0.x
	local old=$(git -C $W rev-parse commercial/release/7.0.1)
	run 7.0.1,7.1.0; expect_rc 0
	expect_out "^    \+release/7.0.1 release/7.1.0 --force-with-lease=release/7.0.1:$old$"
	reject_out "force-with-lease=release/7.1.0"
'

t "create: local release without a remote one is an error" '
	git -C $R/commercial.git branch -q -D release/7.1.0
	git -C $W branch -q release/7.1.0 disclosure/frozen/main
	run -n 7.1.0; expect_rc 1
	expect_out "release/7.1.0: exists locally but not on .commercial."
'

t "mapping: main fallback, skips and several newer generations" '
	run -n 7.1.0; expect_rc 0
	run -n 7.2.0; expect_rc 1; expect_out "7.2.0: no disclosure/\*/7.2.x"
	run -n 7.1.0,8.0.0; expect_rc 1; expect_out "several newer generations"
	run -n 6.5.0; expect_rc 1; expect_out "not the generation after the newest"
	run -n 7.1.0-RC1; expect_rc 0
	expect_out "release/7.1.0-RC1 .*would create from commercial/disclosure/frozen/main"
'

t "validation: base branch behind, ahead and missing" '
	commit_on $S disclosure/frozen/7.0.x up.txt; git -C $S push -q commercial disclosure/frozen/7.0.x
	run -n 7.0.1; expect_rc 1
	expect_out "disclosure/frozen/7.0.x: behind commercial/disclosure/frozen/7.0.x by 1"
	expect_out "git-pull-branches"
	git -C $W branch -q -D disclosure/active/7.0.x
	run -n 7.0.1.1; expect_rc 1
	expect_out "disclosure/active/7.0.x: branch does not exist locally"
'

t "validation: base branch ahead of its upstream" '
	commit_on $W disclosure/frozen/7.0.x local.txt
	git -C $W checkout -q 7.0.x
	run -n 7.0.1; expect_rc 1
	expect_out "disclosure/frozen/7.0.x: ahead of commercial/disclosure/frozen/7.0.x by 1 commit\(s\), push it first"
'

t "validation: dirty worktree and missing upstream together" '
	echo y > $W/untracked.txt
	git -C $W branch -q --unset-upstream disclosure/active/7.0.x
	run -n 7.0.1,7.0.1.1; expect_rc 1
	expect_out "problem"
	expect_out "working tree not clean"
	expect_out "disclosure/active/7.0.x: no upstream"
'

t "validation: merge commit among release-only commits is an error" '
	git -C $W checkout -q -b tmp commercial/release/7.0.1
	git -C $W checkout -q -b side
	echo s > $W/s; git -C $W add s; git -C $W commit -qm side
	git -C $W checkout -q tmp
	echo t > $W/t; git -C $W add t; git -C $W commit -qm tip
	git -C $W merge -q --no-ff side -m mergecommit > /dev/null
	git -C $W push -q commercial tmp:release/7.0.1
	git -C $W checkout -q 7.0.x; git -C $W branch -q -D tmp side
	run -n 7.0.1; expect_rc 1
	expect_out "merge commit"
'

t "validation: unexpected local release branch is an error" '
	git -C $W branch -q release/7.0.1 commercial/release/7.0.1
	git -C $W checkout -q release/7.0.1
	commit_on $W release/7.0.1 local.txt
	git -C $W checkout -q 7.0.x
	run -n 7.0.1; expect_rc 1
	expect_out "local branch differs"
'

# A conflict stops at the prompt; resolve it from "another terminal" and press Enter.
t "conflict: prompt appears and resume works" '
	advance disclosure/frozen/7.0.x LICENSE
	# The stdin side waits for the conflict, resolves it, then presses Enter.
	set +e
	out=$( ( for i in {1..150}; do [[ -d $W/.git/rebase-merge || -d $W/.git/rebase-apply ]] && break; sleep 0.2; done
		echo resolved > $W/LICENSE; git -C $W add -A; git -C $W rebase --continue >/dev/null 2>&1; sleep 1; echo; sleep 5 ) | script -q /dev/null zsh -c "cd $W && $SCRIPT 7.0.1" 2>&1 )
	set -e
	expect_out "Rebase of .release/7.0.1. onto .disclosure/frozen/7.0.x. stopped"
	expect_out "Rebase finished"
	expect_out "Done\. Push when ready:"
	[[ "$(git -C $W show release/7.0.1:LICENSE)" == resolved ]]
'

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
