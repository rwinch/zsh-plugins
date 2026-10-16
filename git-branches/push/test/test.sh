#!/bin/zsh
# Tests for git-branches-push. Builds throwaway repos (bare 'oss' and
# 'commercial' remotes, a seed repo that pushes to them, and a 'work' clone)
# under a temp dir and asserts exit codes and output.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-branches-push"
FILTER="$1"
pass=0
fail=0
out=""
rc=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true

# ---- fixture ----
# $R root, $S seed repo, $W work clone. Branches: 7.0.x main (oss);
# disclosure/{frozen,active}/{7.0.x,main}, release/7.0.1, release/7.1.0 (commercial).
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
	for rel in "release/7.0.1 disclosure/frozen/7.0.x" "release/7.1.0 disclosure/frozen/main"; do
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
	for rel in release/7.0.1 release/7.1.0; do
		git -C $W branch -q --track $rel commercial/$rel
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

# Nothing is fetched by the plugin, so fetch like git-branches-fetch would
run() {
	set +e
	git -C $W fetch -q --all --prune
	out=$(cd $W && $SCRIPT "$@" 2>&1)
	rc=$?
	set -e
	[[ -n "$DEBUG" ]] && { echo "  \$ git-branches-push $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
	return 0
}

expect_rc() { [[ $rc -eq $1 ]] || { echo "    expected rc $1, got $rc"; echo "${out}" | sed 's/^/      | /'; return 1; } }
expect_out() { print -r -- "$out" | grep -qE -- "$1" || { echo "    expected output to match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; } }
reject_out() { print -r -- "$out" | grep -qE -- "$1" && { echo "    output must not match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; }; return 0 }
remote_sha() { git -C $R/$1.git rev-parse "refs/heads/$2" }
local_sha() { git -C $W rev-parse "refs/heads/$1" }

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
t "args: no args, unknown option, missing list, --help" '
	run; expect_rc 1; expect_out "At least one branch or --releases"
	run -x 7.0.x; expect_rc 1; expect_out "Unknown option"
	run --releases; expect_rc 1; expect_out "needs a comma separated list"
	run -d --releases 7.0.1; expect_rc 1; expect_out "--disclosures needs at least one generation"
	run 7.0.x 7.0.x; expect_rc 1; expect_out "more than once"
	run --help; expect_rc 0; expect_out "^Usage: git-branches-push"
'

t "args: release version format" '
	run -r 7.0; expect_rc 1; expect_out "Invalid release version"
	run -r 7.1.1-RC1; expect_rc 1; expect_out "patch 0"
	run -r 7.0.1,7.0.1; expect_rc 1; expect_out "more than once"
'

t "up to date: one-liner" '
	run 7.0.x main; expect_rc 0
	[[ "$out" == *"Everything is up to date, nothing to push."* ]]
'

t "push: ahead branch is pushed" '
	commit_on $W 7.0.x a.txt
	local sha=$(local_sha 7.0.x)
	run 7.0.x main; expect_rc 0
	expect_out "ahead 1"
	expect_out "Pushing oss \.\.\. done"
	expect_out "Done\. Pushed 1 branch\(es\) and 0 release\(s\)\."
	[[ $(remote_sha oss 7.0.x) == $sha ]]
'

t "push: one atomic push per remote" '
	commit_on $W 7.0.x a.txt
	commit_on $W disclosure/frozen/7.0.x b.txt
	git -C $W checkout -q 7.0.x
	run -d 7.0.x; expect_rc 0
	expect_out "Pushing oss \.\.\. done"
	expect_out "Pushing commercial \.\.\. done"
	[[ $(remote_sha oss 7.0.x) == $(local_sha 7.0.x) ]]
	[[ $(remote_sha commercial disclosure/frozen/7.0.x) == $(local_sha disclosure/frozen/7.0.x) ]]
'

t "dry run: prints the commands, pushes nothing" '
	commit_on $W 7.0.x a.txt
	git -C $W checkout -q 7.0.x
	local before=$(remote_sha oss 7.0.x)
	run -n 7.0.x; expect_rc 0
	expect_out "Dry run, nothing pushed\. Would run:"
	expect_out "git push --atomic oss"
	reject_out "Pushing"
	[[ $(remote_sha oss 7.0.x) == $before ]]
'

t "validation: behind and diverged branches are problems" '
	commit_on $S 7.0.x up.txt; git -C $S push -q oss 7.0.x
	run 7.0.x; expect_rc 1
	expect_out "7.0.x: behind oss/7.0.x by 1"
	expect_out "Nothing was pushed"
	commit_on $W 7.0.x local.txt
	run 7.0.x; expect_rc 1
	expect_out "7.0.x: diverged from oss/7.0.x \(1 ahead, 1 behind\)"
'

t "validation: missing branch, missing upstream, gone upstream" '
	git -C $W branch -q -D disclosure/active/7.0.x
	git -C $W branch -q --unset-upstream disclosure/frozen/7.0.x
	run 7.0.x disclosure/frozen/7.0.x disclosure/active/7.0.x; expect_rc 1
	expect_out "disclosure/active/7.0.x: branch does not exist locally"
	expect_out "disclosure/frozen/7.0.x: no upstream"
	git -C $W branch -q --set-upstream-to=commercial/disclosure/frozen/7.0.x disclosure/frozen/7.0.x
	git -C $R/oss.git branch -q -D 7.0.x
	run 7.0.x; expect_rc 1
	expect_out "7.0.x: upstream .oss/7.0.x. no longer exists"
'

t "releases: ahead release is a plain push" '
	commit_on $W release/7.0.1 r.txt
	git -C $W checkout -q 7.0.x
	run -r 7.0.1; expect_rc 0
	expect_out "ahead 1"
	reject_out "force"
	expect_out "Done\. Pushed 0 branch\(es\) and 1 release\(s\)\."
	[[ $(remote_sha commercial release/7.0.1) == $(local_sha release/7.0.1) ]]
'

t "releases: diverged release is forced with a lease" '
	local old=$(remote_sha commercial release/7.0.1)
	git -C $W checkout -q release/7.0.1
	git -C $W reset -q --hard HEAD~1
	commit_on $W release/7.0.1 rebuilt.txt
	git -C $W checkout -q 7.0.x
	run -n -r 7.0.1; expect_rc 0
	expect_out "diverged, forced \(force-with-lease ${old:0:7}\)"
	expect_out "release/7.0.1 --force-with-lease=release/7.0.1:$old"
	run -r 7.0.1; expect_rc 0
	expect_out "Pushing commercial \.\.\. done"
	[[ $(remote_sha commercial release/7.0.1) == $(local_sha release/7.0.1) ]]
'

t "releases: behind release is a problem" '
	commit_on $S release/7.1.0 r.txt; git -C $S push -q commercial release/7.1.0
	run -r 7.1.0; expect_rc 1
	expect_out "release/7.1.0: behind commercial/release/7.1.0 by 1"
'

t "push failure: lease rejected reports what was and was not pushed" '
	commit_on $W 7.0.x a.txt
	git -C $W checkout -q release/7.0.1
	git -C $W reset -q --hard HEAD~1
	commit_on $W release/7.0.1 rebuilt.txt
	git -C $W checkout -q 7.0.x
	set +e
	git -C $W fetch -q --all --prune
	# somebody else moves the release after our fetch
	commit_on $S release/7.0.1 other.txt; git -C $S push -q commercial release/7.0.1
	out=$(cd $W && $SCRIPT 7.0.x -r 7.0.1 2>&1); rc=$?
	set -e
	expect_rc 1
	expect_out "Pushing oss \.\.\. done"
	expect_out "Pushing commercial \.\.\. failed"
	expect_out "Pushed: oss\. Not pushed: commercial"
	expect_out "stale info"
'

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
