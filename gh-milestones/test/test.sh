#!/bin/zsh
# Tests for gh-milestones. Puts a stub 'gh' first on PATH that serves canned
# milestones from files under $R/data and records write calls in $R/calls.log,
# and builds a throwaway git repo with oss/commercial/origin remotes.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/gh-milestones"
FILTER="$1"
pass=0
fail=0
out=""
rc=0
M=$(date +%Y-%m)
NM=$(date -v+1m +%Y-%m 2>/dev/null || date -d "$(date +%Y-%m-01) +1 month" +%Y-%m)

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# ---- fixture ----
# $R root, $W git repo with remotes oss (ssh url), commercial (https url), origin.
# Data rows are number, title, state, due_on, open, closed (tab separated).
setup() {
	R=$(mktemp -d); R=${R:A}
	W=$R/work
	mkdir -p $R/data $R/bin $W
	export CALLS=$R/calls.log FIX=$R/data
	: > $CALLS
	cat > $R/bin/gh <<'STUB'
#!/bin/zsh
p=""
for a in "$@"; do [[ $a == repos/* ]] && p=$a; done
if [[ $p == *"/milestones?state="* ]]; then
	repo=${${p#repos/}%%/milestones*}
	st=${${p#*state=}%%&*}
	[[ -e $FIX/fail_${repo//\//_} ]] && { echo "gh: HTTP 404" >&2; exit 1 }
	f=$FIX/${repo//\//_}.tsv
	[[ -e $f ]] && awk -F'\t' -v st=$st 'st=="all" || $3==st' $f
	exit 0
fi
echo "$*" >> $CALLS
STUB
	chmod +x $R/bin/gh
	export PATH=$R/bin:$PATH
	local tab=$'\t'
	print -r -- "1${tab}7.0.1${tab}open${tab}${M}-20T07:00:00Z${tab}4${tab}9
2${tab}7.1.0-M1${tab}open${tab}2099-10-27T07:00:00Z${tab}12${tab}2
3${tab}6.5.5${tab}closed${tab}2026-09-15T07:00:00Z${tab}0${tab}31
4${tab}7.2.0${tab}open${tab}${tab}0${tab}0" > $FIX/acme_proj.tsv
	print -r -- "5${tab}7.0.1${tab}open${tab}${M}-20T07:00:00Z${tab}1${tab}3
6${tab}7.0.0${tab}closed${tab}2026-01-10T07:00:00Z${tab}0${tab}5" > $FIX/acme_proj-commercial.tsv
	git init -q $W
	git -C $W remote add oss git@github.com:acme/proj.git
	git -C $W remote add commercial https://github.com/acme/proj-commercial.git
	git -C $W remote add origin https://github.com/someone/fork.git
}

run() {
	set +e
	out=$(cd $W && $SCRIPT "$@" 2>&1)
	rc=$?
	set -e
	[[ -n "$DEBUG" ]] && { echo "  \$ gh-milestones $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
	return 0
}
# like run, but stdout only (what $(...) would capture)
run_stdout() {
	set +e
	out=$(cd $W && $SCRIPT "$@" 2>/dev/null)
	rc=$?
	set -e
	return 0
}

expect_rc() { [[ $rc -eq $1 ]] || { echo "    expected rc $1, got $rc"; echo "${out}" | sed 's/^/      | /'; return 1; } }
expect_out() { print -r -- "$out" | grep -qE -- "$1" || { echo "    expected output to match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; } }
reject_out() { print -r -- "$out" | grep -qE -- "$1" && { echo "    output must not match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; }; return 0 }
expect_eq() { [[ "$out" == "$1" ]] || { echo "    expected: $1"; echo "    got:      $out"; return 1; } }
no_writes() { [[ ! -s $CALLS ]] || { echo "    unexpected writes:"; sed 's/^/      | /' $CALLS; return 1; } }
calls() { [[ $(wc -l < $CALLS | tr -d ' ') -eq $1 ]] || { echo "    expected $1 write calls:"; sed 's/^/      | /' $CALLS; return 1; } }
called() { grep -qF -- "$1" $CALLS || { echo "    expected call: $1"; sed 's/^/      | /' $CALLS; return 1; } }

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
t "args: --help, unknown option, bad values" '
	run --help; expect_rc 0; expect_out "^Usage: gh-milestones"
	run -x; expect_rc 1; expect_out "Unknown option"
	run list extra; expect_rc 1; expect_out "Unexpected argument"
	run --state bogus; expect_rc 1; expect_out "--state must be"
	run --dry-run; expect_rc 1; expect_out "only valid with create"
	run create --oneline; expect_rc 1; expect_out "only valid with list"
	run --oss-repo; expect_rc 1; expect_out "requires a value"
'

t "repos: oss remote and commercial remote" '
	run
	expect_out "oss: acme/proj \(remote oss\)"
	expect_out "commercial: acme/proj-commercial \(remote commercial\)"
'

t "repos: oss falls back to origin, commercial to oss name + -commercial" '
	git -C $W remote remove oss; git -C $W remote remove commercial
	run
	expect_out "oss: someone/fork \(remote origin\)"
	expect_out "commercial: someone/fork-commercial \(oss repository \+ -commercial\)"
'

t "repos: commercial remote used even without --oss-repo, name fallback when absent" '
	git -C $W remote remove commercial
	run
	expect_out "commercial: acme/proj-commercial \(oss repository \+ -commercial\)"
'

t "repos: --oss-repo derives commercial and ignores the commercial remote" '
	git -C $W remote set-url commercial https://github.com/other/thing.git
	run --oss-repo acme/proj
	expect_out "oss: acme/proj \(--oss-repo\)"
	expect_out "commercial: acme/proj-commercial \(--oss-repo \+ -commercial\)"
'

t "repos: --commercial-repo wins" '
	run --commercial-repo acme/other
	expect_out "commercial: acme/other \(--commercial-repo\)"
'

t "repos: both args work outside a git repository" '
	run_dir=$(mktemp -d)
	out=$(cd $run_dir && $SCRIPT --oss-repo acme/proj --commercial-repo acme/proj-commercial 2>&1); rc=$?
	rm -rf $run_dir
	expect_rc 0; expect_out "7.0.1"
'

t "repos: no remotes and no args is an error" '
	git -C $W remote remove oss; git -C $W remote remove commercial; git -C $W remote remove origin
	run; expect_rc 1; expect_out "Could not determine the oss repository"
'

t "repos: invalid repository name" '
	run --oss-repo nonsense; expect_rc 1; expect_out "must look like ORG/NAME"
'

t "list: default is open milestones from both repos in a table" '
	run; expect_rc 0
	expect_out "REPO +TITLE +STATE +DUE +OPEN +CLOSED"
	expect_out "oss +7.0.1 +open +${M}-20 +4 +9"
	expect_out "oss +7.2.0 +open +- +0 +0"
	expect_out "commercial +7.0.1 +open"
	reject_out "6.5.5"
	reject_out "7.0.0"
'

t "list: --state all and closed" '
	run --state all; expect_rc 0; expect_out "6.5.5 +closed"; expect_out "commercial +7.0.0 +closed"
	run --state closed; expect_rc 0; reject_out "open"
'

t "list: --due globs, null due dates never match" '
	run list --due "${M}-*"; expect_rc 0
	expect_out "7.0.1"; reject_out "7.1.0-M1"; reject_out "7.2.0"
	run list --due "2099-1?-27" --due "${M}-20" --state all; expect_rc 0
	expect_out "7.1.0-M1"; expect_out "7.0.1"; reject_out "6.5.5"
	run list --due "*"; expect_rc 0; reject_out "7.2.0"
'

t "list: --this-month" '
	run list --this-month; expect_rc 0; expect_out "7.0.1"; reject_out "7.1.0-M1"
'

t "list: --next-month matches next month only, and combines with --this-month" '
	run list --next-month; expect_rc 0; expect_out "No milestones matched"
	run list --this-month --next-month; expect_rc 0; expect_out "7.0.1"
'

t "list: --oss-only and --commercial-only" '
	run_stdout list --oss-only --oneline; expect_rc 0; expect_eq "7.0.1,7.1.0-M1,7.2.0"
	run_stdout list --commercial-only --oneline; expect_rc 0; expect_eq "7.0.1"
	run list --oss-only --commercial-only; expect_rc 1; expect_out "cannot be combined"
	run create --oss-only; expect_rc 1; expect_out "only valid with list"
	run set-due-date --commercial-only 2026-12-01 7.0.1; expect_rc 1; expect_out "only valid with list"
'

t "list: --hotfixes keeps only 4 part commercial titles and does not touch OSS" '
	local tab=$'"'"'\t'"'"'
	print -r -- "7${tab}7.0.1.1${tab}open${tab}${NM}-10T07:00:00Z${tab}1${tab}0
8${tab}7.0.2${tab}open${tab}${NM}-10T07:00:00Z${tab}1${tab}0
9${tab}7.0.3.RC1${tab}open${tab}${NM}-10T07:00:00Z${tab}1${tab}0" >> $FIX/acme_proj-commercial.tsv
	run_stdout list --commercial-only --hotfixes --oneline; expect_rc 0; expect_eq "7.0.1.1"
	run_stdout list --oss-only --hotfixes --oneline; expect_rc 0; expect_eq "7.0.1,7.1.0-M1,7.2.0"
	run_stdout list --hotfixes --oneline; expect_rc 0; expect_eq "7.0.1,7.1.0-M1,7.2.0,7.0.1.1"
	run create --hotfixes; expect_rc 1; expect_out "only valid with list"
'

t "list: --quiet hides the repositories and the no match message, only valid with list" '
	run list --quiet --this-month --oneline; expect_rc 0; expect_eq "7.0.1"
	run list --quiet --due "1999-*"; expect_rc 0; expect_eq ""
	run create --quiet; expect_rc 1; expect_out "only valid with list"
'

t "ghmr: OSS this month plus commercial hotfixes next month" '
	local tab=$'"'"'\t'"'"'
	print -r -- "7${tab}7.0.1.1${tab}open${tab}${NM}-10T07:00:00Z${tab}1${tab}0
8${tab}7.0.2${tab}open${tab}${NM}-10T07:00:00Z${tab}1${tab}0" >> $FIX/acme_proj-commercial.tsv
	out=$(cd $W && zsh -c "source ${SCRIPT:h}/gh-milestones.plugin.zsh; ghmr" 2>&1)
	expect_eq "7.0.1,7.0.1.1"
'

t "list: nothing matched is not an error" '
	run list --due "1999-*"; expect_rc 0; expect_out "No milestones matched"
'

t "oneline: unique comma-separated titles, stdout only" '
	run_stdout list --this-month --oneline; expect_rc 0; expect_eq "7.0.1"
	run_stdout --oneline; expect_rc 0; expect_eq "7.0.1,7.1.0-M1,7.2.0"
	run_stdout --oneline --state all; expect_rc 0; expect_eq "7.0.1,7.1.0-M1,6.5.5,7.2.0,7.0.0"
'

t "list: gh failure is reported" '
	touch $FIX/fail_acme_proj-commercial
	run; expect_rc 1; expect_out "commercial: could not read milestones from acme/proj-commercial"
'

t "create: usage errors" '
	run create; expect_rc 1; expect_out "needs --oss"
	run create --oss 7.0.3; expect_rc 1; expect_out "exactly one --due"
	run create --oss 7.0.3 --due 2026-13-01; expect_rc 1; expect_out "must be a date"
	run create --oss --due 2026-11-17; expect_rc 1; expect_out "requires at least one"
	run create --oss 7.0.3 --due 2026-11-17 --due 2026-11-18; expect_rc 1; expect_out "exactly one"
	run create --oss 7.0.3 --due 2026-11-17 --this-month; expect_rc 1; expect_out "not valid with create"
	run --oss 7.0.3; expect_rc 1; expect_out "only valid with create"
	no_writes
'

t "create: dry run prints the gh commands and writes nothing" '
	run create --oss 7.0.3 7.0.4 --commercial 7.0.3 --due 2026-11-17 -n; expect_rc 0
	expect_out "Dry run, nothing was created"
	expect_out "Would run:"
	expect_out "gh api repos/acme/proj/milestones -f title=7.0.3 -f due_on=2026-11-17T00:00:00Z"
	expect_out "gh api repos/acme/proj/milestones -f title=7.0.4 -f due_on=2026-11-17T00:00:00Z"
	expect_out "gh api repos/acme/proj-commercial/milestones -f title=7.0.3 -f due_on=2026-11-17T00:00:00Z"
	no_writes
'

t "create: creates in the chosen repos only" '
	run create --oss 7.0.3 --commercial 7.0.4 --due 2026-11-17; expect_rc 0
	calls 2
	called "api repos/acme/proj/milestones -f title=7.0.3 -f due_on=2026-11-17T00:00:00Z"
	called "api repos/acme/proj-commercial/milestones -f title=7.0.4 -f due_on=2026-11-17T00:00:00Z"
'

t "create: comma separated titles are split" '
	run create --oss 7.0.3,7.0.4 --due 2026-11-17; expect_rc 0; calls 2
'

t "create: existing open or closed title fails everything before writing" '
	run create --oss 7.0.3 6.5.5 --commercial 7.0.1 7.0.0 --due 2026-11-17; expect_rc 1
	expect_out "3 problem\(s\) found\. Nothing was created"
	expect_out "oss: milestone .6.5.5. already exists \(closed\)"
	expect_out "commercial: milestone .7.0.1. already exists \(open\)"
	no_writes
	run create --oss 7.0.3 --commercial 7.0.0 --due 2026-11-17; expect_rc 1
	expect_out "commercial: milestone .7.0.0. already exists \(closed\)"
	no_writes
'

t "create: the same title in both repos checks each repo separately" '
	run create --oss 7.0.1 --commercial 7.0.9 --due 2026-11-17; expect_rc 1
	expect_out "oss: milestone .7.0.1. already exists"
	reject_out "commercial: milestone"
	no_writes
'

t "create: duplicate titles in one list" '
	run create --oss 7.0.3 7.0.3 --due 2026-11-17; expect_rc 1; expect_out "oss: duplicate titles"
	no_writes
'

t "create: only the targeted repos are needed" '
	git -C $W remote remove oss; git -C $W remote remove origin
	run create --commercial 7.0.3 --commercial-repo acme/proj-commercial --due 2026-11-17; expect_rc 0
	calls 1
'

t "set-due-date: usage errors" '
	run set-due-date; expect_rc 1; expect_out "needs a date"
	run set-due-date tomorrow 7.0.1; expect_rc 1; expect_out "Date must be like"
	run set-due-date 2026-12-01; expect_rc 1; expect_out "at least one milestone title"
	run set-due-date 2026-12-01 --this-month; expect_rc 1; expect_out "only a date and milestone titles"
	run set-due-date 2026-12-01 7.0.1 --due "2026-*"; expect_rc 1; expect_out "only a date and milestone titles"
	run set-due-date 2026-12-01 7.0.1 --state all; expect_rc 1; expect_out "only a date and milestone titles"
	no_writes
'

t "set-due-date: titles are updated in both repos, missing in one repo is fine" '
	run set-due-date 2026-12-01 7.1.0-M1; expect_rc 0
	calls 1; called "repos/acme/proj/milestones/2 "
'

t "set-due-date: a title in both repos updates both" '
	run set-due-date 2026-12-01 7.0.1; expect_rc 0
	calls 2
	called "api -X PATCH repos/acme/proj/milestones/1 -f due_on=2026-12-01T00:00:00Z"
	called "api -X PATCH repos/acme/proj-commercial/milestones/5 -f due_on=2026-12-01T00:00:00Z"
'

t "set-due-date: several titles, closed ones included, repeats ignored" '
	run set-due-date 2026-12-01 7.0.1 6.5.5 7.0.1; expect_rc 0
	calls 3
	called "repos/acme/proj/milestones/3 "
'

t "set-due-date: unknown title fails before writing" '
	run set-due-date 2026-12-01 7.0.1 9.9.9; expect_rc 1
	expect_out "milestone .9.9.9. not found"
	no_writes
'

t "set-due-date: dry run prints the gh commands and writes nothing" '
	run set-due-date 2026-12-01 7.0.1 -n; expect_rc 0
	expect_out "Dry run, nothing was changed"
	expect_out "gh api -X PATCH repos/acme/proj/milestones/1 -f due_on=2026-12-01T00:00:00Z"
	expect_out "gh api -X PATCH repos/acme/proj-commercial/milestones/5 -f due_on=2026-12-01T00:00:00Z"
	no_writes
'

echo
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
