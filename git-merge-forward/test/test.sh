#!/bin/zsh
# Tests for git-merge-forward. Builds throwaway repos (bare 'oss' and
# 'commercial' remotes, a seed repo that pushes to them, and a 'work' clone)
# under a temp dir and asserts exit codes and output.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-merge-forward"
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
	[[ -n "$DEBUG" ]] && { echo "  \$ git-merge-forward $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
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
t "args: no args, single branch, unknown option, dry-run+pull, duplicates" '
	run; expect_rc 1
	run main; expect_rc 1; expect_out "single branch needs --disclosures"
	run -x a b; expect_rc 1; expect_out "Unknown option"
	run -r; expect_rc 1
	run a a; expect_rc 1; expect_out "more than once"
'

t "args: release version format and base rules" '
	run -r 7.0; expect_rc 1; expect_out "Invalid release version"
	run -r 7.1.1-RC1; expect_rc 1; expect_out "patch 0"
	run -r 7.0.1,7.0.2; expect_rc 1; expect_out "at most one per base"
	run -r 7.0.1.1,7.0.2.1; expect_rc 1; expect_out "at most one per base"
	run -r 7.0.1,7.0.1; expect_rc 1; expect_out "more than once"
'

t "plain chain merges across worktrees (target in another worktree)" '
	git -C $W worktree add -q $R/wt-main main
	commit_on $W 7.0.x fix.txt
	run 7.0.x main; expect_rc 0
	expect_out "Merging .7.0.x. -> .main. \(dir: $R/wt-main\)"
	contains 7.0.x main
	[[ $(branch_of $R/wt-main) == main ]]
	expect_out "git push --atomic oss"
'

t "no worktree for target: switches, then restores the original branch" '
	commit_on $W 7.0.x fix.txt
	run 7.0.x main; expect_rc 0
	contains 7.0.x main
	[[ $(branch_of $W) == 7.0.x ]]
	expect_out "Restored .7.0.x."
'

t "validation reports every problem together (dirty, untracked, missing)" '
	git -C $W worktree add -q $R/wt-main main
	echo x >> $R/wt-main/f
	echo y > $W/untracked.txt
	run 7.0.x main nope; expect_rc 1
	expect_out "3 problem"
	expect_out "main: working tree not clean"
	expect_out "7.0.x: working tree not clean"
	expect_out "nope: branch does not exist locally"
'

t "validation: missing upstream" '
	git -C $W branch nofollow main
	run 7.0.x nofollow; expect_rc 1
	expect_out "nofollow: no upstream"
	expect_out "set-upstream-to"
'

t "validation: in-progress merge fails" '
	commit_on $W main f
	commit_on $W 7.0.x f
	git -C $W merge main > /dev/null 2>&1 || true
	run 7.0.x main; expect_rc 1
	expect_out "merge is in progress"
'

t "behind fails, --pull fast-forwards it" '
	commit_on $S main up.txt; git -C $S push -q oss main
	commit_on $W 7.0.x fix.txt
	run 7.0.x main; expect_rc 1; expect_out "main: behind oss/main by 1"
	run --pull 7.0.x main; expect_rc 0
	has_file main up.txt
	contains 7.0.x main
'

t "dry run with --pull only pulls, then prints the plan" '
	commit_on $S main up.txt; git -C $S push -q oss main
	commit_on $W 7.0.x fix.txt
	run -n 7.0.x main; expect_rc 1; expect_out "main: behind oss/main by 1"
	run -n -p 7.0.x main; expect_rc 0
	expect_out "Pulling .main."
	expect_out "Dry run: nothing was merged \\(1 branch\\(es\\) were fast-forwarded"
	has_file main up.txt
	not_contains 7.0.x main
'

t "diverged fails" '
	commit_on $S main up.txt; git -C $S push -q oss main
	commit_on $W main local.txt
	git -C $W checkout -q 7.0.x
	run 7.0.x main; expect_rc 1
	expect_out "main: diverged from oss/main \(1 ahead, 1 behind\)"
'

t "ahead: first branch ok, other branch fails, --allow-ahead allows it" '
	commit_on $W main extra.txt
	commit_on $W 7.0.x fix.txt
	run 7.0.x main; expect_rc 1; expect_out "main: ahead of oss/main by 1"
	run --allow-ahead 7.0.x main; expect_rc 0
	contains 7.0.x main
'

t "up to date: one-liner, also on a dry run" '
	run 7.0.x main; expect_rc 0
	[[ "$out" == *"Everything is up to date, nothing to merge."* ]]
	reject_out "Merging"
	run -n 7.0.x main; expect_rc 0
	expect_out "Everything is up to date, nothing to merge."
'

t "dry run changes nothing and exits 0" '
	commit_on $W 7.0.x fix.txt
	local before=$(git -C $W for-each-ref --format="%(refname) %(objectname)")
	run -n 7.0.x main; expect_rc 0
	expect_out "would merge"
	expect_out "Dry run: nothing was changed"
	[[ "$before" == "$(git -C $W for-each-ref --format="%(refname) %(objectname)")" ]]
	[[ $(branch_of $W) == 7.0.x ]]
'

t "disclosures: 2 generations give the 7 hops of the tutorial" '
	commit_on $W 7.0.x fix.txt
	run -n -d 7.0.x main; expect_rc 0
	expect_out "\(7\) disclosure/active/7.0.x -> disclosure/active/main"
	expect_out "\(2\) 7.0.x +-> disclosure/frozen/7.0.x +down"
	expect_out "\(4\) disclosure/frozen/7.0.x +-> disclosure/frozen/main +across"
	reject_out "\(8\)"
'

t "disclosures: a single generation is allowed" '
	commit_on $W main fix.txt
	run -n -d main; expect_rc 0
	expect_out "main +-> disclosure/frozen/main +down"
	expect_out "disclosure/frozen/main +-> disclosure/active/main +down"
	reject_out "\(3\)"
'

t "disclosures: merges real changes everywhere, prints one push per remote" '
	commit_on $W 7.0.x fix.txt
	run -d 7.0.x main; expect_rc 0
	for b in main disclosure/frozen/7.0.x disclosure/frozen/main disclosure/active/7.0.x disclosure/active/main; do
		has_file $b fix.txt || { echo "    $b lacks fix.txt"; return 1 }
	done
	expect_out "git push --atomic oss"
	expect_out "git push --atomic commercial"
'

t "ours: across hops carry nothing, message is merge(ours)" '
	commit_on $W 7.0.x deps.txt
	run -o 7.0.x main; expect_rc 0
	contains 7.0.x main
	lacks_file main deps.txt
	[[ "$(git -C $W log -1 --format=%s main)" == "merge(ours): 7.0.x into main" ]]
	[[ $(git -C $W rev-list --parents -1 main | wc -w) -eq 3 ]]
'

t "ours + disclosures: ours across, real merges down" '
	commit_on $W 7.0.x deps.txt
	run -o -d 7.0.x main; expect_rc 0
	lacks_file main deps.txt
	has_file disclosure/frozen/7.0.x deps.txt
	has_file disclosure/active/7.0.x deps.txt
	lacks_file disclosure/frozen/main deps.txt
	lacks_file disclosure/active/main deps.txt
	contains disclosure/frozen/7.0.x disclosure/active/main
	contains disclosure/active/7.0.x disclosure/active/main
	[[ "$(git -C $W log -1 --format=%s disclosure/active/main)" == merge\(ours\):* ]]
'

t "releases: rebuilt on the disclosure branch plus release-only commits" '
	commit_on $W 7.0.x fix.txt
	local old=$(git -C $W rev-parse commercial/release/7.0.1)
	run -d 7.0.x main -r 7.0.1,7.0.1.1; expect_rc 0
	for r in release/7.0.1 release/7.0.1.1; do
		has_file $r fix.txt && has_file $r LICENSE || { echo "    $r wrong"; return 1 }
	done
	contains disclosure/frozen/7.0.x release/7.0.1
	contains disclosure/active/7.0.x release/7.0.1.1
	[[ $(git -C $W rev-list --count disclosure/frozen/7.0.x..release/7.0.1) -eq 1 ]]
	expect_out "\+release/7.0.1 "
	expect_out "--force-with-lease=release/7.0.1:$old"
	[[ $(branch_of $W) == 7.0.x ]]
'

t "releases alone: dry run, rewrite, then up to date once pushed" '
	commit_on $W 7.0.x fix.txt
	run -d 7.0.x main; expect_rc 0
	git -C $W push -q oss 7.0.x main
	git -C $W push -q commercial disclosure/frozen/7.0.x disclosure/frozen/main disclosure/active/7.0.x disclosure/active/main
	run -n -r 7.0.1; expect_rc 0; expect_out "release/7.0.1 on disclosure/frozen/7.0.x: would rebase 1 commit"
	run -r 7.0.1; expect_rc 0
	contains disclosure/frozen/7.0.x release/7.0.1
	git -C $W push -q -f commercial release/7.0.1
	run -r 7.0.1; expect_rc 0
	expect_out "Everything is up to date, nothing to merge."
'

t "releases: main fallback, skips and several newer generations" '
	commit_on $W disclosure/frozen/main fm.txt
	git -C $W push -q commercial disclosure/frozen/main
	git -C $W checkout -q 7.0.x
	run -n -r 7.1.0; expect_rc 0
	expect_out "release/7.1.0 on disclosure/frozen/main"
	expect_out "no 7.1.x branch, newest generation"
	run -n -r 7.2.0; expect_rc 1; expect_out "7.2.0: no disclosure/\*/7.2.x"
	run -n -r 7.1.0,8.0.0; expect_rc 1; expect_out "several newer generations"
	run -n -r 6.5.0; expect_rc 1; expect_out "not the generation after the newest"
	run -n -r 7.1.0-RC1; expect_rc 1
	expect_out "does not exist on"
'

t "releases: merge commit among release-only commits is an error" '
	git -C $W checkout -q -b tmp commercial/release/7.0.1
	git -C $W checkout -q -b side
	echo s > $W/s; git -C $W add s; git -C $W commit -qm side
	git -C $W checkout -q tmp
	echo t > $W/t; git -C $W add t; git -C $W commit -qm tip
	git -C $W merge -q --no-ff side -m mergecommit > /dev/null
	git -C $W push -q commercial tmp:release/7.0.1
	git -C $W checkout -q 7.0.x; git -C $W branch -q -D tmp side
	run -n -r 7.0.1; expect_rc 1
	expect_out "merge commit"
'

t "releases: unexpected local release branch is an error" '
	git -C $W branch -q release/7.0.1 commercial/release/7.0.1
	git -C $W checkout -q release/7.0.1
	commit_on $W release/7.0.1 local.txt
	git -C $W checkout -q 7.0.x
	run -n -r 7.0.1; expect_rc 1
	expect_out "local branch differs"
'

# A conflict stops at the prompt; resolve it from "another terminal" and press Enter.
t "conflict: prompt appears and resume works" '
	commit_on $W main f
	git -C $W push -q oss main
	commit_on $W 7.0.x f
	# The stdin side waits for the conflict, resolves it, then presses Enter.
	set +e
	out=$( ( for i in {1..150}; do git -C $W rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && break; sleep 0.2; done
		git -C $W add -A; git -C $W commit -q --no-edit; sleep 1; echo; sleep 5 ) | script -q /dev/null zsh -c "cd $W && $SCRIPT --allow-ahead 7.0.x main" 2>&1 )
	set -e
	expect_out "Merge conflict merging"
	expect_out "Merge conflict resolved"
	expect_out "Done!"
'

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
