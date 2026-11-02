#!/bin/zsh
# Tests for git-branches-merge-forward. Builds throwaway repos (bare 'oss' and
# 'commercial' remotes, a seed repo that pushes to them, and a 'work' clone)
# under a temp dir and asserts exit codes and output.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-branches-merge-forward"
PLUGIN="${0:A:h:h}/merge-forward.plugin.zsh"
FILTER="$1"
pass=0
fail=0
out=""
rc=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true

# ---- fixture ----
# $R root, $S seed repo, $W work clone. Branches: 7.0.x main (oss);
# embargoed/{frozen,active}/{7.0.x,main} (commercial).
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
	git -C $S checkout -q main
	git -C $S push -q oss main 7.0.x
	git -C $S push -q commercial 'refs/heads/embargoed/*'
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
	git init -q --bare -b main $R/fork.git
	git -C $W remote add fork $R/fork.git
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

# Runs gbbmfa (the plugin function) in the work clone with a fake spring-versions listing the branches in $OSS
run_a() {
	set +e
	mkdir -p $R/bin
	printf "#!/bin/sh\necho %s\n" "${OSS:-7.0.x main}" > $R/bin/spring-versions
	chmod +x $R/bin/spring-versions
	[[ -z "$NOFETCH" ]] && git -C $W fetch -q --all
	out=$(cd $W && zsh -c "source $PLUGIN; PATH=$R/bin:\$PATH; gbbmfa \"\$@\"" _ "$@" 2>&1)
	rc=$?
	set -e
	[[ -n "$DEBUG" ]] && { echo "  \$ gbbmfa $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
	return 0
}

has_upstream() { [[ -n "$(git -C $W config branch.$1.remote)" ]] }

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
	run main; expect_rc 1; expect_out "single branch needs --embargoed"
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

t "embargoed: 2 generations give the 7 hops of the tutorial" '
	commit_on $W 7.0.x fix.txt
	run -n -e 7.0.x main; expect_rc 0
	expect_out "\(7\) embargoed/active/7.0.x -> embargoed/active/main"
	expect_out "\(2\) 7.0.x +-> embargoed/frozen/7.0.x +down"
	expect_out "\(4\) embargoed/frozen/7.0.x +-> embargoed/frozen/main +across"
	reject_out "\(8\)"
'

t "embargoed: a single generation is allowed" '
	commit_on $W main fix.txt
	run -n -e main; expect_rc 0
	expect_out "main +-> embargoed/frozen/main +down"
	expect_out "embargoed/frozen/main +-> embargoed/active/main +down"
	reject_out "\(3\)"
'

t "embargoed: merges real changes everywhere, prints one push per remote" '
	commit_on $W 7.0.x fix.txt
	run -e 7.0.x main; expect_rc 0
	for b in main embargoed/frozen/7.0.x embargoed/frozen/main embargoed/active/7.0.x embargoed/active/main; do
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

t "ours + embargoed: ours across, real merges down" '
	commit_on $W 7.0.x deps.txt
	run -o -e 7.0.x main; expect_rc 0
	lacks_file main deps.txt
	has_file embargoed/frozen/7.0.x deps.txt
	has_file embargoed/active/7.0.x deps.txt
	lacks_file embargoed/frozen/main deps.txt
	lacks_file embargoed/active/main deps.txt
	contains embargoed/frozen/7.0.x embargoed/active/main
	contains embargoed/active/7.0.x embargoed/active/main
	[[ "$(git -C $W log -1 --format=%s embargoed/active/main)" == "merge(ours): 7.0.x into main" ]]
'

t "embargoed: merge messages name generation branches" '
	commit_on $W 7.0.x fix.txt
	commit_on $W embargoed/frozen/7.0.x own.txt
	commit_on $W embargoed/active/7.0.x own2.txt
	run --allow-ahead -o -e 7.0.x main; expect_rc 0
	[[ "$(git -C $W log -1 --format=%s embargoed/frozen/7.0.x)" == "Merge branch '"'"'7.0.x'"'"' into '"'"'7.0.x'"'"'" ]]
	[[ "$(git -C $W log -1 --format=%s embargoed/active/7.0.x)" == "Merge branch '"'"'7.0.x'"'"' into '"'"'7.0.x'"'"'" ]]
	[[ "$(git -C $W log -1 --format=%s embargoed/frozen/main)" == "merge(ours): 7.0.x into main" ]]
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

# ---------------------------------------------------------------------------
# --feature
t "feature: creates feature/<branch>/FEATURE, merges them, leaves the branches alone" '
	commit_on $W main extra.txt
	commit_on $W 7.0.x fix.txt
	local base70=$(git -C $W rev-parse 7.0.x) basemain=$(git -C $W rev-parse main)
	run --allow-ahead --feature bug1 --fork-remote fork 7.0.x main; expect_rc 0
	has_file feature/7.0.x/bug1 fix.txt
	has_file feature/main/bug1 fix.txt
	[[ "$(git -C $W rev-parse 7.0.x)" == $base70 && "$(git -C $W rev-parse main)" == $basemain ]]
	[[ "$(git -C $W log -1 --format=%s feature/main/bug1)" == "Merge branch '"'"'7.0.x'"'"' into '"'"'main'"'"'" ]]
	contains feature/7.0.x/bug1 feature/main/bug1
	! has_upstream feature/7.0.x/bug1
	! has_upstream feature/main/bug1
	[[ $(branch_of $W) == 7.0.x ]]
	expect_out "Created: feature/7.0.x/bug1, feature/main/bug1"
	expect_out "git push --atomic -u fork"
	expect_out "feature/7.0.x/bug1 feature/main/bug1"
	reject_out "git push --atomic oss"
'

t "feature: dry run prints the feature branches and creates nothing" '
	commit_on $W 7.0.x fix.txt
	local before=$(git -C $W for-each-ref --format="%(refname) %(objectname)")
	run -n -f bug1 --fork-remote fork 7.0.x main; expect_rc 0
	expect_out "feature/7.0.x/bug1 +from 7.0.x"
	expect_out "feature/main/bug1 +from main"
	expect_out "\(1\) feature/7.0.x/bug1 -> feature/main/bug1 +across merge would merge"
	expect_out "base upstream: oss/main"
	expect_out "git push --atomic -u fork"
	[[ "$before" == "$(git -C $W for-each-ref --format="%(refname) %(objectname)")" ]]
'

t "feature: starting on the first feature branch uses it" '
	git -C $W checkout -q -b feature/7.0.x/bug1
	commit_on $W feature/7.0.x/bug1 fix.txt
	run --feature bug1 --fork-remote fork 7.0.x main; expect_rc 0
	expect_out "feature/7.0.x/bug1 +already exists \(current branch\)"
	reject_out "Creating .feature/7.0.x/bug1."
	has_file feature/main/bug1 fix.txt
	lacks_file 7.0.x fix.txt
	[[ $(branch_of $W) == feature/7.0.x/bug1 ]]
	expect_out "Created: feature/main/bug1"
'

t "feature: nothing to merge is judged from the first feature branch when starting on it" '
	git -C $W checkout -q -b feature/7.0.x/bug1
	commit_on $W feature/7.0.x/bug1 fix.txt
	run -n -f bug1 --fork-remote fork 7.0.x main; expect_rc 0
	expect_out "would merge"
	reject_out "Everything is up to date"
'

t "feature: an existing feature branch is a problem, with a hint for the first" '
	git -C $W branch feature/main/bug1 main
	git -C $W branch feature/7.0.x/bug1 7.0.x
	run -f bug1 --fork-remote fork 7.0.x main; expect_rc 1
	expect_out "2 problem"
	expect_out "feature/main/bug1: branch already exists"
	expect_out "feature/7.0.x/bug1: branch already exists \(to start from it, check it out"
	git -C $W rev-parse -q --verify feature/7.0.x/bug1 > /dev/null
'

t "feature: --force only applies with --feature" '
	run --force 7.0.x main; expect_rc 1; expect_out "only applies with --feature"
'

t "feature: --force reuses existing feature branches and creates the missing ones" '
	git -C $W branch feature/7.0.x/bug1 7.0.x
	git -C $W branch feature/main/bug1 main
	commit_on $W feature/7.0.x/bug1 fix.txt
	git -C $W checkout -q 7.0.x
	run --force --feature bug1 --fork-remote fork 7.0.x main; expect_rc 0
	has_file feature/main/bug1 fix.txt
	contains feature/7.0.x/bug1 feature/main/bug1
	not_contains feature/7.0.x/bug1 main
	[[ $(branch_of $W) == 7.0.x ]]
	reject_out "Creating"
	reject_out "Created:"
	expect_out "git push --atomic -u fork"
'

t "feature: --force dry run shows reused and new feature branches" '
	git -C $W branch feature/7.0.x/bug1 7.0.x
	commit_on $W feature/7.0.x/bug1 fix.txt
	git -C $W checkout -q 7.0.x
	run -n --force --feature bug1 --fork-remote fork 7.0.x main; expect_rc 0
	expect_out "existing ones are reused"
	expect_out "feature/7.0.x/bug1 +already exists, used as it is"
	expect_out "feature/main/bug1 +from main"
	expect_out "Plan \\(rerere is on"
	expect_out "\\(1\\) feature/7.0.x/bug1 -> feature/main/bug1 +across merge would merge"
	! git -C $W rev-parse -q --verify feature/main/bug1 > /dev/null
'

t "feature: --force judges hops from the feature branches (already merged is up to date)" '
	git -C $W branch feature/7.0.x/bug1 7.0.x
	git -C $W branch feature/main/bug1 main
	commit_on $W feature/7.0.x/bug1 fix.txt
	git -C $W checkout -q feature/main/bug1
	git -C $W merge -q --no-edit feature/7.0.x/bug1
	git -C $W checkout -q 7.0.x
	run --force --feature bug1 --fork-remote fork 7.0.x main; expect_rc 0
	expect_out "Everything is up to date"
'

t "feature: --force resolves a conflict that was resolved before with rerere" '
	git -C $W branch feature/7.0.x/bug1 7.0.x
	git -C $W branch feature/main/bug1 main
	git -C $W checkout -q feature/7.0.x/bug1
	echo A > $W/f; git -C $W commit -qam "A"
	git -C $W checkout -q feature/main/bug1
	echo M > $W/f; git -C $W commit -qam "M"
	pre=$(git -C $W rev-parse HEAD)
	# the first merge, resolved by hand with rerere recording it
	git -C $W -c rerere.enabled=true merge --no-edit feature/7.0.x/bug1 > /dev/null 2>&1 || true
	echo AM > $W/f; git -C $W add f
	git -C $W -c rerere.enabled=true commit -q --no-edit
	# the merge is thrown away, as if the branches had been rewritten
	git -C $W reset -q --hard $pre
	git -C $W checkout -q 7.0.x
	run --force --feature bug1 --fork-remote fork 7.0.x main; expect_rc 0
	expect_out "rerere: reused a recorded resolution for 1 file"
	expect_out "resolved with rerere"
	[[ "$(git -C $W show feature/main/bug1:f)" == AM ]]
	contains feature/7.0.x/bug1 feature/main/bug1
	[[ -z "$(git -C $W status --porcelain)" ]]
	[[ $(branch_of $W) == 7.0.x ]]
'

t "feature: a branch that is also a directory of the name is a problem" '
	git -C $W branch feature main
	run -f bug1 --fork-remote fork 7.0.x main; expect_rc 1
	expect_out "feature/7.0.x/bug1: .feature. is a branch"
'

t "feature: unknown fork remote and bad names are reported" '
	run -f bug1 --fork-remote nope 7.0.x main; expect_rc 1
	expect_out "remote .nope. \(your fork\) does not exist"
	run -f 7.0.x/bug1 7.0.x main; expect_rc 1; expect_out "must not contain"
	run --feature; expect_rc 1; expect_out "needs a FEATURE name"
	run --fork-remote fork 7.0.x main; expect_rc 1; expect_out "only applies with --feature"
'

t "feature: --embargoed makes feature/embargoed/... and pushes them to the commercial remote" '
	commit_on $W 7.0.x fix.txt
	commit_on $W embargoed/frozen/7.0.x own.txt
	run --allow-ahead -e -f bug1 --fork-remote fork 7.0.x main; expect_rc 0
	for b in feature/main/bug1 feature/embargoed/frozen/7.0.x/bug1 feature/embargoed/frozen/main/bug1 feature/embargoed/active/7.0.x/bug1 feature/embargoed/active/main/bug1; do
		has_file $b fix.txt || { echo "    $b lacks fix.txt"; return 1 }
	done
	lacks_file embargoed/active/main fix.txt
	expect_out "git push --atomic -u fork"
	expect_out "git push --atomic -u commercial"
	expect_out "feature/embargoed/frozen/7.0.x/bug1 feature/embargoed/frozen/main/bug1 feature/embargoed/active/7.0.x/bug1 feature/embargoed/active/main/bug1"
	[[ "$(git -C $W log -1 --format=%s feature/embargoed/frozen/7.0.x/bug1)" == "Merge branch '"'"'7.0.x'"'"' into '"'"'7.0.x'"'"'" ]]
'

t "feature: --ours records across hops with the generation names" '
	commit_on $W 7.0.x deps.txt
	run -o -f bug1 --fork-remote fork 7.0.x main; expect_rc 0
	lacks_file feature/main/bug1 deps.txt
	[[ "$(git -C $W log -1 --format=%s feature/main/bug1)" == "merge(ours): 7.0.x into main" ]]
'

t "feature: worktrees of the base branches move to the feature branches, the run directory is restored" '
	git -C $W worktree add -q $R/wt-main main
	commit_on $W 7.0.x fix.txt
	run -f bug1 --fork-remote fork 7.0.x main; expect_rc 0
	[[ $(branch_of $R/wt-main) == feature/main/bug1 ]]
	[[ $(branch_of $W) == 7.0.x ]]
	expect_out "Worktrees left on a feature branch"
	expect_out "$R/wt-main is on feature/main/bug1"
'

t "feature: a dirty worktree stops everything before any branch is created" '
	git -C $W worktree add -q $R/wt-main main
	echo x >> $R/wt-main/f
	run -f bug1 --fork-remote fork 7.0.x main; expect_rc 1
	expect_out "main: working tree not clean"
	! git -C $W rev-parse -q --verify feature/7.0.x/bug1 > /dev/null
'

# ---------------------------------------------------------------------------
# gbbmfa
add_generation() {
	git -C $S branch 7.1.x main
	git -C $S push -q oss 7.1.x
	git -C $W fetch -q oss
	git -C $W branch -q --track 7.1.x oss/7.1.x
}

t "gbbmfa: infers the feature and starts at the base of the current feature branch" '
	add_generation
	git -C $W checkout -q -b feature/7.0.x/bug1 7.0.x
	commit_on $W feature/7.0.x/bug1 fix.txt
	OSS="7.0.x 7.1.x main" run_a --no-embargoed --fork-remote fork; expect_rc 0
	has_file feature/7.1.x/bug1 fix.txt
	has_file feature/main/bug1 fix.txt
	contains feature/7.1.x/bug1 feature/main/bug1
	expect_out "Created: feature/7.1.x/bug1, feature/main/bug1"
'

t "gbbmfa: drops the older generations when the feature branch is on a newer one" '
	add_generation
	git -C $W checkout -q -b feature/7.1.x/bug1 7.1.x
	commit_on $W feature/7.1.x/bug1 fix.txt
	OSS="7.0.x 7.1.x main" run_a --no-embargoed -n --fork-remote fork; expect_rc 0
	reject_out "feature/7.0.x/bug1"
	expect_out "feature/7.1.x/bug1 +already exists"
	expect_out "feature/main/bug1 +from main"
'

t "gbbmfa: --feature that matches the current branch behaves the same, another name does not trim" '
	add_generation
	git -C $W checkout -q -b feature/7.1.x/bug1 7.1.x
	commit_on $W feature/7.1.x/bug1 fix.txt
	commit_on $W 7.0.x other.txt
	git -C $W checkout -q feature/7.1.x/bug1
	OSS="7.0.x 7.1.x main" run_a --no-embargoed -n --fork-remote fork --feature bug1; expect_rc 0
	reject_out "feature/7.0.x/bug1"
	OSS="7.0.x 7.1.x main" run_a --no-embargoed -n --fork-remote fork -f bug2; expect_rc 0
	expect_out "feature/7.0.x/bug2 +from 7.0.x"
	expect_out "feature/main/bug2 +from main"
'

t "gbbmfa: --feature on another branch uses the full list" '
	commit_on $W 7.0.x fix.txt
	run_a --no-embargoed --feature bug1 --fork-remote fork; expect_rc 0
	has_file feature/main/bug1 fix.txt
'

t "gbbmfa: a base that is not an OSS branch infers nothing" '
	git -C $W checkout -q -b feature/embargoed/frozen/7.0.x/bug1 embargoed/frozen/7.0.x
	run_a --no-embargoed; expect_rc 0
	expect_out "not one of the OSS branches"
	reject_out "feature/7.0.x/bug1"
'

t "gbbmfa: without a feature it behaves as before" '
	commit_on $W 7.0.x fix.txt
	run_a --no-embargoed; expect_rc 0
	contains 7.0.x main
	reject_out "Feature branches"
'

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
