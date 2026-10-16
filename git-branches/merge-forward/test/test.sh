#!/bin/zsh
# Tests for git-branches-merge-forward. Builds throwaway repos (bare 'oss' and
# 'commercial' remotes, a seed repo that pushes to them, and a 'work' clone)
# under a temp dir and asserts exit codes and output.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-branches-merge-forward"
FILTER="$1"
pass=0
fail=0
out=""
rc=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true

# ---- fixture ----
# $R root, $S seed repo, $W work clone. Branches: 7.0.x main (oss);
# disclosure/{frozen,active}/{7.0.x,main} (commercial).
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
	git -C $S checkout -q main
	git -C $S push -q oss main 7.0.x
	git -C $S push -q commercial 'refs/heads/disclosure/*'
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

# Nothing is fetched by the plugin, so fetch like git-branches-fetch would (unless NOFETCH=1)
run() {
	set +e
	[[ -z "$NOFETCH" ]] && git -C $W fetch -q --all
	out=$(cd $W && $SCRIPT "$@" 2>&1)
	rc=$?
	set -e
	[[ -n "$DEBUG" ]] && { echo "  \$ git-branches-merge-forward $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
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
t "args: no args, single branch, unknown option, duplicates" '
	run; expect_rc 1
	run main; expect_rc 1; expect_out "single branch needs --disclosures"
	run -x a b; expect_rc 1; expect_out "Unknown option"
	run a a; expect_rc 1; expect_out "more than once"
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

t "behind fails" '
	commit_on $S main up.txt; git -C $S push -q oss main
	commit_on $W 7.0.x fix.txt
	run 7.0.x main; expect_rc 1; expect_out "main: behind oss/main by 1"
'

t "refs are not fetched or pulled" '
	commit_on $S main up.txt; git -C $S push -q oss main
	commit_on $W 7.0.x fix.txt
	NOFETCH=1 run -n 7.0.x main; expect_rc 0
	reject_out "Fetching"
	run 7.0.x main; expect_rc 1; expect_out "main: behind oss/main by 1"
	run --pull 7.0.x main; expect_rc 1; expect_out "Unknown option"
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
	[[ "$(git -C $W log -1 --format=%s disclosure/active/main)" == "merge(ours): 7.0.x into main" ]]
'

t "disclosures: merge messages name generation branches" '
	commit_on $W 7.0.x fix.txt
	commit_on $W disclosure/frozen/7.0.x own.txt
	commit_on $W disclosure/active/7.0.x own2.txt
	run --allow-ahead -o -d 7.0.x main; expect_rc 0
	[[ "$(git -C $W log -1 --format=%s disclosure/frozen/7.0.x)" == "Merge branch '"'"'7.0.x'"'"' into '"'"'7.0.x'"'"'" ]]
	[[ "$(git -C $W log -1 --format=%s disclosure/active/7.0.x)" == "Merge branch '"'"'7.0.x'"'"' into '"'"'7.0.x'"'"'" ]]
	[[ "$(git -C $W log -1 --format=%s disclosure/frozen/main)" == "merge(ours): 7.0.x into main" ]]
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
