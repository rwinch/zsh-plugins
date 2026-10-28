#!/bin/zsh
# Tests for gh-block-embargoed-branches. Puts a stub 'gh' first on PATH that serves
# canned ruleset ids from $R/data/<owner>_<repo>.id and records write calls
# (and their stdin) in $R/calls.log.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/gh-block-embargoed-branches"
FILTER="$1"
pass=0
fail=0
out=""
rc=0

setup() {
	R=$(mktemp -d); R=${R:A}
	mkdir -p $R/data $R/bin $R/tmp
	export TMPDIR=$R/tmp GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
	export CALLS=$R/calls.log FIX=$R/data
	: > $CALLS
	cat > $R/bin/gh <<'STUB'
#!/bin/zsh
[[ "$1 $2" == "api user" ]] && { [[ -e $FIX/nologin ]] && exit 1; echo me; exit 0 }
if [[ "$1 $2" == "repo clone" ]]; then
	repo=$3; dir=$4
	[[ -e $FIX/fail_clone_${repo//\//_} ]] && { echo "gh: could not clone" >&2; exit 1 }
	echo "Cloning into '$dir'..." >&2
	git init -q $dir && git -C $dir remote add origin $FIX/${repo//\//_}.git
	exit
fi
if [[ "$2" == repos/*/* && "$2" != repos/*/*/* && "$*" == *.archived* ]]; then
	repo=${2#repos/}
	[[ -e $FIX/archived_${repo//\//_} ]] && echo true || echo false
	exit 0
fi
if [[ "$2" == repos/*/rules/branches/* ]]; then
	repo=${${2#repos/}%%/rules*}
	[[ -e $FIX/fail_${repo//\//_} ]] && { echo "gh: HTTP 500" >&2; exit 1 }
	[[ -e $FIX/rules_${repo//\//_} ]] && cat $FIX/rules_${repo//\//_}
	exit 0
fi
p=""
for a in "$@"; do [[ $a == repos/* ]] && p=$a; done
repo=${${p#repos/}%%/rulesets*}
if [[ $p == */rulesets && " $* " != *" -X "* && " $* " != *" --input "* ]]; then
	[[ -e $FIX/fail_${repo//\//_} ]] && { echo "gh: HTTP 404" >&2; exit 1 }
	[[ -e $FIX/${repo//\//_}.id ]] && cat $FIX/${repo//\//_}.id
	exit 0
fi
echo "$*" >> $CALLS
if [[ " $* " == *" --input - "* ]]; then cat >> $CALLS; echo >> $CALLS; fi
STUB
	chmod +x $R/bin/gh
	export PATH=$R/bin:$PATH
}

# bare NAME [HOOK-MESSAGE]: a fake remote, rejecting every push with the message
bare() {
	git init -q --bare $FIX/$1.git
	[[ -n "$2" ]] || return 0
	print -r -- "#!/bin/sh
echo '$2' >&2
exit 1" > $FIX/$1.git/hooks/pre-receive
	chmod +x $FIX/$1.git/hooks/pre-receive
}
GH013="remote: error: GH013: Repository rule violations found for refs/heads/embargoed/active/main."

run() {
	set +e
	out=$($SCRIPT "$@" 2>&1)
	rc=$?
	set -e
	[[ -n "$DEBUG" ]] && { echo "  \$ gh-block-embargoed-branches $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
	return 0
}

expect_rc() { [[ $rc -eq $1 ]] || { echo "    expected rc $1, got $rc"; echo "${out}" | sed 's/^/      | /'; return 1; } }
expect_out() { print -r -- "$out" | grep -qE -- "$1" || { echo "    expected output to match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; } }
reject_out() { print -r -- "$out" | grep -qE -- "$1" && { echo "    output must not match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; }; return 0 }
no_writes() { [[ ! -s $CALLS ]] || { echo "    unexpected writes:"; sed 's/^/      | /' $CALLS; return 1; } }
called() { grep -qF -- "$1" $CALLS || { echo "    expected call: $1"; sed 's/^/      | /' $CALLS; return 1; } }
ncalls() { [[ $(grep -c "^api " $CALLS) -eq $1 ]] || { echo "    expected $1 write calls:"; sed "s/^/      | /" $CALLS; return 1; } }

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
t "args: help, unknown option, no repos, missing values" '
	run --help; expect_rc 0; expect_out "^Usage: gh-block-embargoed-branches"
	run -x a/b; expect_rc 1; expect_out "Unknown option"
	run; expect_rc 1; expect_out "At least one repository"
	run a/b --owners; expect_rc 1; expect_out "requires a value"
'

t "expand: example from the spec, in order" '
	run rwinch/foo repo1 repo2 --owners owner1,owner2 -n
	expect_rc 0
	expect_out "Repositories \(5\)"
	local order=$(print -r -- "$out" | grep -E "^  (rwinch|owner)" | tr -d " " | tr "\n" ",")
	[[ $order == "rwinch/foo,owner1/repo1,owner2/repo1,owner1/repo2,owner2/repo2," ]] || { echo "bad order: $order"; return 1 }
'

t "expand: --owners anywhere, repeated, deduped" '
	run --owners a repo --owners b,a -n
	expect_rc 0; expect_out "Repositories \(2\)"
	run a/x repo a/x --owners a -n
	expect_rc 0; expect_out "Repositories \(2\)"
'

t "expand: @me is replaced by the gh login, in place" '
	run foo --owners @me -n
	expect_rc 0; expect_out "Repositories \(1\)"; expect_out "^  me/foo"
	run foo --owners a,@me --owners b -n
	expect_rc 0; expect_out "Repositories \(3\)"; expect_out "^  a/foo"; expect_out "^  me/foo"
	run foo --owners me,@me -n
	expect_rc 0; expect_out "Repositories \(1\)"
	touch $FIX/nologin
	run foo --owners @me -n
	expect_rc 1; expect_out "@me needs"
'

t "expand: bare name without --owners and malformed repos are problems" '
	run rwinch/foo repo1
	expect_rc 1; expect_out "1 problem"; expect_out "has no owner"
	run a/b/c /x a/ --owners o
	expect_rc 1; expect_out "3 problem"; expect_out "OWNER/NAME"
	no_writes
'

t "create: POST with the ruleset body" '
	run rwinch/foo
	expect_rc 0; expect_out "create"
	called "api repos/rwinch/foo/rulesets --input -"
	called "\"include\": [\"refs/heads/embargoed/**\"]"
	called "\"bypass_actors\": []"
	called "\"enforcement\": \"active\""
	for r in creation update deletion non_fast_forward; do called "\"type\": \"$r\""; done
'

t "update: existing ruleset is PUT by id" '
	echo 4821 > $FIX/owner1_repo1.id
	run owner1/repo1 owner2/repo1
	expect_rc 0; expect_out "update \(ruleset 4821\)"
	called "api -X PUT repos/owner1/repo1/rulesets/4821 --input -"
	called "api repos/owner2/repo1/rulesets --input -"
	ncalls 2
'

t "dry run: prints commands, makes no writes" '
	echo 4821 > $FIX/owner1_repo1.id
	run owner1/repo1 owner2/repo1 -n
	expect_rc 0; expect_out "Dry run, nothing was changed"
	expect_out "gh api -X PUT repos/owner1/repo1/rulesets/4821 --input -"
	no_writes
'

t "remove: DELETE when present, skip when absent" '
	echo 77 > $FIX/a_b.id
	run --remove a/b a/c
	expect_rc 0; expect_out "remove \(ruleset 77\)"; expect_out "skip"
	called "api -X DELETE repos/a/b/rulesets/77"
	ncalls 1
'

t "failure: one unreadable repo aborts all writes" '
	touch $FIX/fail_a_bad
	run a/good a/bad
	expect_rc 1; expect_out "a/bad: could not read rulesets"
	no_writes
'

t "verify: all blocked => rc 0, nothing left behind" '
	bare a_one "$GH013"; bare b_one "$GH013"
	run verify one --owners a,b
	expect_rc 0; expect_out "GH013"
	expect_out "a/one +BLOCKED"; expect_out "b/one +BLOCKED"
	expect_out "2 blocked, 0 failed, 0 error"
	reject_out "To remove the accidentally"
	[[ -z "$(ls -A $TMPDIR)" ]] || { echo "temp dirs left: $(ls $TMPDIR)"; return 1 }
	no_writes
'

t "verify: unblocked repo => FAILED, rc 1, cleanup command, orphan branch with test.txt" '
	bare a_one "$GH013"; bare b_one
	run verify one --owners a,b
	expect_rc 1
	expect_out "a/one +BLOCKED"; expect_out "b/one +FAILED"
	expect_out "1 blocked, 1 failed, 0 error"
	expect_out "gh api -X DELETE repos/b/one/git/refs/heads/embargoed/active/main"
	reject_out "DELETE repos/a/one"
	local g=$FIX/b_one.git
	[[ $(git -C $g rev-list --count embargoed/active/main) -eq 1 ]] || { echo "expected one commit"; return 1 }
	[[ $(git -C $g rev-list --parents -n1 embargoed/active/main | wc -w) -eq 1 ]] || { echo "commit has a parent"; return 1 }
	[[ "$(git -C $g ls-tree --name-only embargoed/active/main)" == test.txt ]] || { echo "expected only test.txt"; return 1 }
	[[ "$(git -C $g show embargoed/active/main:test.txt)" == gh-block-embargoed-branches ]] || { echo "bad contents"; return 1 }
	[[ -z "$(ls -A $TMPDIR)" ]] || { echo "temp dirs left"; return 1 }
'

t "verify: other rejection and clone failure => ERROR, rc 1, no cleanup command" '
	bare a_one "remote: error: permission denied"
	touch $FIX/fail_clone_a_two
	run verify one two --owners a
	expect_rc 1
	expect_out "a/one +ERROR"; expect_out "a/two +ERROR"
	expect_out "0 blocked, 0 failed, 2 error"
	reject_out "To remove the accidentally"
	[[ -z "$(ls -A $TMPDIR)" ]] || { echo "temp dirs left"; return 1 }
'

t "verify: -n clones and pushes nothing; --remove rejected; @me works" '
	run verify one --owners a -n
	expect_rc 0; expect_out "Dry run, nothing was cloned or pushed"; expect_out "^  a/one"
	[[ -z "$(ls -A $TMPDIR)" ]] || { echo "temp dirs left"; return 1 }
	run verify --remove a/one
	expect_rc 1; expect_out "--remove is not valid with verify"
	run verify one --owners @me -n
	expect_rc 0; expect_out "^  me/one"
	run apply a/one -n
	expect_rc 0; expect_out "create"
'

t "check: protected, not protected, unknown, exit status, read-only" '
	echo "creation,update,deletion,non_fast_forward" > $FIX/rules_a_one
	echo "deletion" > $FIX/rules_a_two
	run check one --owners a
	expect_rc 0; expect_out "a/one +protected"
	run check one two --owners a
	expect_rc 1; expect_out "a/one +protected"; expect_out "a/two +NOT PROTECTED"
	touch $FIX/fail_a_bad
	run check one two bad --owners a
	expect_rc 2; expect_out "a/bad +unknown \(gh: HTTP 500\)"
	run check a/three
	expect_rc 1; expect_out "a/three +NOT PROTECTED"
	run check --remove a/one; expect_rc 1; expect_out "not valid with check"
	run check -n a/one; expect_rc 1; expect_out "not valid with check"
	no_writes
'

t "archived: apply and remove skip them, the rest is applied, rc 0" '
	touch $FIX/archived_a_old
	run old new --owners a
	expect_rc 0; expect_out "a/old +skip \(archived\)"; expect_out "a/new +create"
	expect_out "Protected 1 repository"; expect_out "Skipped 1 archived"
	called "api repos/a/new/rulesets --input -"
	! grep -q "a/old" $CALLS
	run old --owners a
	expect_rc 0; expect_out "skip \(archived\)"; expect_out "Protected 0 repository"
	echo 9 > $FIX/a_new.id
	: > $CALLS
	run --remove old new --owners a
	expect_rc 0; expect_out "a/old +skip \(archived\)"; expect_out "remove \(ruleset 9\)"
	! grep -q "a/old" $CALLS
'

t "archived: check does not count them, verify skips them without cloning" '
	touch $FIX/archived_a_old
	echo "creation,update" > $FIX/rules_a_new
	run check old new --owners a
	expect_rc 0; expect_out "a/old +skipped \(archived\)"; expect_out "a/new +protected"
	bare a_new "$GH013"
	run verify old new --owners a
	expect_rc 0; expect_out "a/old +SKIPPED"; expect_out "a/new +BLOCKED"
	expect_out "1 blocked, 0 failed, 0 error\\(s\\), 1 skipped"
	[[ -z "$(ls -A $TMPDIR)" ]] || { echo "temp dirs left"; return 1 }
'

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
