#!/bin/zsh
# Tests for gmi. Builds throwaway repos under a temp dir and runs gmi inside them.
# Commits are named by tag: 'mk X' commits a file X on the current branch and tags it X.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/gmi"
FILTER="$1"
pass=0
fail=0
out=""
err=""
rc=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true

# ---- fixture ----
setup() {
	R=$(mktemp -d); R=${R:A}
	git init -q -b main $R/repo
	mk base
}

g() { git -C $R/repo "$@" }
mk() { echo "$1" > $R/repo/$1; g add $1; g commit -qm "$1"; g tag $1 }   # NAME
mg() { g merge -q --no-ff -m "$2" "$1" > /dev/null; g tag "$2" }          # BRANCH TAG: no-ff merge tagged TAG
mours() { g merge -q -s ours --no-ff -m "$2" "$1" > /dev/null; g tag "$2" }

run() {
	set +e
	(cd $R/repo && $SCRIPT "$@" > $R/stdout 2> $R/stderr)
	rc=$?
	set -e
	out=$(<$R/stdout); err=$(<$R/stderr)
	[[ -n "$DEBUG" ]] && { echo "  \$ gmi $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    > /'; print -r -- "$err" | sed 's/^/    | /' }
	return 0
}

expect_rc() { [[ $rc -eq $1 ]] || { echo "    expected rc $1, got $rc"; echo "${out}" | sed 's/^/      > /'; echo "${err}" | sed 's/^/      | /'; return 1; } }
expect_out() { print -r -- "$out" | grep -qE -- "$1" || { echo "    expected output to match: $1"; echo "${out}" | sed 's/^/      > /'; return 1; } }
reject_out() { print -r -- "$out" | grep -qE -- "$1" && { echo "    output must not match: $1"; echo "${out}" | sed 's/^/      > /'; return 1; }; return 0 }
expect_err() { print -r -- "$err" | grep -qE -- "$1" || { echo "    expected stderr to match: $1"; echo "${err}" | sed 's/^/      | /'; return 1; } }
# output has a line for this tag's commit (short sha followed by two spaces)
expect_hop() { expect_out "(^| )$(g rev-parse --short $1)  " || return 1 }
reject_hop() { reject_out "$(g rev-parse --short $1)  " }

t() { print -r -- "$out" | grep -qE -- "$1" || { echo "    expected output to match: $1"; echo "${out}" | sed 's/^/      > /'; return 1; } }
reject_out() { print -r -- "$out" | grep -qE -- "$1" && { echo "    output must not match: $1"; echo "${out}" | sed 's/^/      > /'; return 1; }; return 0 }
expect_err() { print -r -- "$err" | grep -qE -- "$1" || { echo "    expected stderr to match: $1"; echo "${err}" | sed 's/^/      | /'; return 1; } }
# the merge section names the merge commit
expect_merge() { expect_out "== Merged into .* by ==" && expect_out "^commit $(g rev-parse $1)" }

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
t "merged one level deep" '
	g checkout -q -b fix; mk X
	g checkout -q main; mk own; mg fix M1
	run X main; expect_rc 0
	expect_hop M1
	expect_out "^\\* $(g rev-parse --short X)  "
	expect_out "^main  \\* $(g rev-parse --short X)  "
	expect_out "^      +$(g rev-parse --short M1)  "
	reject_out "ours|edited"
'

t "merged two levels deep: a into b, b into main lists both merges, inner first" '
	g checkout -q -b a; mk X
	g checkout -q -b b main; mk bown; mg a MB
	g checkout -q main; mk own; mg b MM
	run X main; expect_rc 0
	expect_hop MB; expect_hop MM
	print -r -- "$out" | grep -n "  MB" | cut -d: -f1 > $R/mb
	print -r -- "$out" | grep -n "  MM" | cut -d: -f1 > $R/mm
	[[ $(<$R/mb) -lt $(<$R/mm) ]]
'

t "merged three levels deep" '
	g checkout -q -b a; mk X
	g checkout -q -b b main; mk bown; mg a MB
	g checkout -q -b c main; mk cown; mg b MC
	g checkout -q main; mk own; mg c MM
	run X main; expect_rc 0
	expect_hop MB; expect_hop MC; expect_hop MM
'

t "later commits and unrelated merges on the path are not listed" '
	g checkout -q -b a; mk X
	g checkout -q -b b main; mk bown; mg a MB; mk blater
	g checkout -q main; mk own; mg b MM; mk after
	g checkout -q -b other main~1; mk oown
	g checkout -q main; mg other M2
	run X main; expect_rc 0
	expect_hop MB; expect_hop MM
	reject_hop M2; reject_hop blater; reject_hop after
'

t "regular commit on the branch own first-parent line" '
	mk X
	g checkout -q -b side; mk S
	g checkout -q main; mg side M1
	run X main; expect_rc 0
	expect_out "^main +\\* $(g rev-parse --short X)  "
	reject_out "^ +[0-9a-f]{7,}  "
	reject_hop M1
'

t "a merge commit that is itself on the first-parent line is a regular commit" '
	g checkout -q -b fix; mk F
	g checkout -q main; mk own; mg fix M1; mk after
	run M1 main; expect_rc 0
	expect_out "^main +\\* $(g rev-parse --short M1)  "
	reject_out "^ +[0-9a-f]{7,}  "
'

t "merged with ours is flagged" '
	g checkout -q -b fix; mk X
	g checkout -q main; mk own; mours fix M1
	run X main; expect_rc 0
	expect_hop M1
	expect_out "ours"
'

t "ours at an inner hop is flagged" '
	g checkout -q -b a; mk X
	g checkout -q -b b main; mk bown; mours a MB
	g checkout -q main; mk own; mg b MM
	run X main; expect_rc 0
	expect_out "MB.*ours"
'

t "a merge that resolved a conflict is flagged edited and its diff is shown" '
	echo base > $R/repo/f; g add f; g commit -qm f
	g checkout -q -b fix; echo fix > $R/repo/f; g add f; g commit -qm X; g tag X
	g checkout -q main; echo main > $R/repo/f; g add f; g commit -qm own
	g merge -q --no-ff fix > /dev/null 2>&1 || true
	echo resolved > $R/repo/f; g add f; g commit -qm M1; g tag M1
	run --full X main; expect_rc 0
	expect_out "M1.*edited"
	expect_out "== edited merge"
	expect_out "resolved"
'

t "a clean merge is not flagged" '
	g checkout -q -b fix; mk X
	g checkout -q main; mk own; mg fix M1
	run X main; expect_rc 0
	reject_out "edited|ours"
'

t "--limit 1 shows only the merge that brought the commit into the branch" '
	g checkout -q -b a; mk X
	g checkout -q -b b main; mk bown; mg a MB
	g checkout -q main; mk own; mg b MM
	run -l 1 X main; expect_rc 0
	expect_hop MM; reject_hop MB
	expect_out "^main  \\* $(g rev-parse --short X)  "
	expect_out "^ +\\.\\.\\.$"
	run -l 0 X main; expect_rc 0
	expect_hop MM; reject_hop MB
	reject_out "\\.\\.\\."
	expect_out "^main +$(g rev-parse --short MM)  "
	reject_out "^main +\\* "
	g branch 1.x X
	run -l 0 X main 1.x; expect_rc 0
	expect_out "^1.x +\\* $(g rev-parse --short X)  "
	run --limit 2 X main; expect_rc 0
	expect_hop MM; expect_hop MB
	reject_out "\\.\\.\\."
	run --limit=5 X main; expect_rc 0
	reject_out "\\.\\.\\."
'

t "--limit only checks the merges shown for ours" '
	g checkout -q -b a; mk X
	g checkout -q -b b main; mk bown; mours a MB
	g checkout -q main; mk own; mg b MM
	run -l 1 X main; expect_rc 0
	reject_hop MB
'

t "--limit errors" '
	run -l X main; expect_rc 2; expect_err "needs a number"
	run X main -l; expect_rc 2; expect_err "needs a number"
'

t "not in any branch: exit 1" '
	g checkout -q -b side; mk X
	g checkout -q main
	run X main; expect_rc 1
	expect_out "not in: main"
'

t "branches that lack the commit are grouped on one line" '
	g checkout -q -b old base
	g checkout -q -b fix main; mk X
	g checkout -q main; mk own; mg fix M1
	g branch 1.x base
	run X main old 1.x; expect_rc 0
	expect_out "^main "
	expect_out "not in: 1.x, old"
'

t "default branch set: main, *.x and embargoed/(frozen|active)/(main|*.x) only" '
	g checkout -q -b fix; mk X
	for b in main 1.x embargoed/frozen/main embargoed/active/2.x feature embargoed/other/main embargoed/frozen/feature nope.y; do
		g branch -q -f $b fix 2>/dev/null || g branch $b fix
	done
	run X; expect_rc 0
	for b in main 1.x embargoed/frozen/main embargoed/active/2.x; do expect_out "^$b "; done
	for b in feature embargoed/other/main embargoed/frozen/feature nope.y fix; do reject_out "^$b "; done
'

t "default branch set includes origin branches without a local branch" '
	g checkout -q -b fix; mk X
	g update-ref refs/remotes/origin/3.x fix
	g update-ref refs/remotes/origin/main fix
	run X; expect_rc 0
	expect_out "^origin/3.x "
	reject_out "^origin/main "
'

t "BRANCH args override the default and may be globs" '
	g checkout -q -b fix; mk X
	g branch 1.x fix; g branch 2.x fix; g branch other fix
	run X "[0-9].x"; expect_rc 0
	expect_out "^1.x "; expect_out "^2.x "
	reject_out "^main |^other "
	run X other; expect_rc 0
	expect_out "^other "
	reject_out "^1.x "
'

t "no default branch exists" '
	g branch -m main trunk
	run base; expect_rc 2; expect_err "No branches named"
	run base "nope.*"; expect_rc 2; expect_err "No branch matches"
'

t "branch can be any ref, such as a tag" '
	g checkout -q -b a; mk X
	g checkout -q main; mk own; mg a M1
	run X M1; expect_rc 0
	expect_hop M1
'

t "errors: unknown commit, usage" '
	run nope main; expect_rc 2; expect_err "Not a commit: nope"
	run; expect_rc 2; expect_err "COMMIT is required"
	run --bogus a b; expect_rc 2; expect_err "Unknown option"
'

t "outside a git repository" '
	set +e; (cd $R && $SCRIPT --dry-run a b > /dev/null 2>&1); local dry=$?
	(cd $R && GIT_DIR=/nonexistent $SCRIPT a b > /dev/null 2>&1); local rcn=$?; set -e
	[[ $dry -eq 0 ]]
	[[ $rcn -eq 2 ]]
'

t "--dry-run prints the commands to stdout and runs nothing" '
	run --dry-run X main; expect_rc 0
	expect_out "git merge-base --is-ancestor"
	expect_out "git rev-list"
	[[ -z "$err" ]]
'

echo ""
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
