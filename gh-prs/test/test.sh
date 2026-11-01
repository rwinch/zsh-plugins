#!/bin/zsh
# Tests for gh-prs. Puts a stub 'gh' first on PATH that serves canned data from
# $R/data and records the write calls (pr create, pr edit) in $R/calls.log, and
# builds throwaway repos: bare oss, commercial and fork remotes, and a work clone
# with feature branches that have been merged forward.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/gh-prs"
FILTER="$1"
pass=0
fail=0
out=""
rc=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true

# ---- fixture ----
# Repos: acme/proj (oss remote), acme/proj-commercial (commercial remote), me/proj (remote 'me',
# your fork). Branches: 7.0.x (version 7.0.9-SNAPSHOT), main (7.2.0-SNAPSHOT),
# embargoed/frozen/7.0.x (7.0.9.1-SNAPSHOT), and feature/<each>/bug1 merged forward.
# Data files in $FIX: login, ms_<repo>.txt, labels_<repo>.tsv (name, color, description), prs_<repo>.tsv (head, base,
# number, state, url, title, owner, labels separated by |).
setup() {
	R=$(mktemp -d); R=${R:A}
	W=$R/work
	mkdir -p $R/data $R/bin
	export CALLS=$R/calls.log FIX=$R/data
	: > $CALLS
	cat > $R/bin/gh <<'STUB'
#!/bin/zsh
a="$*"
if [[ $1 == api && $2 == user ]]; then
	cat $FIX/login 2>/dev/null; exit 0
fi
if [[ $1 == api ]]; then
	for x in "$@"; do [[ $x == repos/* ]] && p=$x; done
	repo=${${p#repos/}%%/milestones*}
	cat $FIX/ms_${repo//\//_}.txt 2>/dev/null; exit 0
fi
if [[ $1 == label && $2 == create ]]; then
	echo "$a" >> $CALLS; exit 0
fi
if [[ $1 == label ]]; then
	for ((i = 1; i <= $#; i++)); do [[ ${@[i]} == -R ]] && repo=${@[i+1]}; done
	cat $FIX/labels_${repo//\//_}.tsv 2>/dev/null; exit 0
fi
if [[ $1 == pr && $2 == list ]]; then
	for ((i = 1; i <= $#; i++)); do
		[[ ${@[i]} == -R ]] && repo=${@[i+1]}
		[[ ${@[i]} == --head ]] && head=${@[i+1]}
		[[ ${@[i]} == --base ]] && base=${@[i+1]}
	done
	f=$FIX/prs_${repo//\//_}.tsv
	[[ -e $f ]] && awk -F'\t' -v h=$head -v b=$base '$1==h && $2==b {print $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8}' $f
	exit 0
fi
if [[ $1 == pr && $2 == create ]]; then
	for ((i = 1; i <= $#; i++)); do [[ ${@[i]} == -R ]] && repo=${@[i+1]}; done
	n=$(cat $FIX/next 2>/dev/null || echo 100)
	echo $((n + 1)) > $FIX/next
	echo "$a" >> $CALLS
	echo "https://github.com/$repo/pull/$n"
	exit 0
fi
echo "$a" >> $CALLS
STUB
	chmod +x $R/bin/gh
	export PATH=$R/bin:$PATH
	echo me > $FIX/login
	print -r -- "7.0.9
7.0.9.1
7.2.0" > $FIX/ms_acme_proj.txt
	print -r -- "7.0.9.1" > $FIX/ms_acme_proj-commercial.txt
	labels acme/proj "in: web" e8f9de "An issue in web modules"
	labels acme/proj "in: config" e8f9de "An issue in config"
	labels acme/proj "type: bug" e3d9fc "A general bug"
	labels acme/proj "type: enhancement" e3d9fc "A general enhancement"
	labels acme/proj "status: forward-port" fef2c0 "An issue tracking the forward-port of a change made in an earlier branch"
	labels acme/proj-commercial "in: web" e8f9de "An issue in web modules"
	labels acme/proj-commercial "type: bug" e3d9fc "A general bug"
	labels acme/proj-commercial "status: forward-port" fef2c0 "An issue tracking the forward-port of a change made in an earlier branch"

	git init -q --bare -b main $R/oss.git
	git init -q --bare -b main $R/commercial.git
	git init -q --bare -b main $R/fork.git
	git init -q -b main $W
	git -C $W remote add oss git@github.com:acme/proj.git
	git -C $W remote add commercial git@github.com:acme/proj-commercial.git
	git -C $W remote add me git@github.com:me/proj.git
	git -C $W config url.$R/oss.git.insteadOf git@github.com:acme/proj.git
	git -C $W config url.$R/commercial.git.insteadOf git@github.com:acme/proj-commercial.git
	git -C $W config url.$R/fork.git.insteadOf git@github.com:me/proj.git

	echo "version=7.0.9-SNAPSHOT" > $W/gradle.properties
	git -C $W add gradle.properties; git -C $W commit -qm base
	git -C $W branch 7.0.x
	git -C $W branch -q embargoed/frozen/7.0.x
	echo "version=7.2.0-SNAPSHOT" > $W/gradle.properties
	git -C $W commit -qam "main version"
	git -C $W checkout -q embargoed/frozen/7.0.x
	echo "version=7.0.9.1-SNAPSHOT" > $W/gradle.properties
	git -C $W commit -qam "embargoed version"

	# the change, and the feature branches merged forward
	git -C $W checkout -q -b feature/7.0.x/bug1 7.0.x
	echo fix > $W/fix.txt; git -C $W add fix.txt
	git -C $W commit -q -m "Fix the thing" -m "Longer description of the fix."
	git -C $W checkout -q -b feature/main/bug1 main
	git -C $W merge -q --no-edit -m "Merge branch '7.0.x' into 'main'" feature/7.0.x/bug1
	git -C $W checkout -q -b feature/embargoed/frozen/7.0.x/bug1 embargoed/frozen/7.0.x
	git -C $W merge -q --no-edit -m "Merge branch '7.0.x' into '7.0.x'" feature/7.0.x/bug1
	git -C $W checkout -q feature/7.0.x/bug1
}

# Adds 7.1.x and the embargoed branches frozen/7.1.x, active/7.0.x and active/7.1.x with their feature branches.
add_generations() {
	git -C $W checkout -q 7.0.x
	git -C $W checkout -q -b 7.1.x main
	echo "version=7.1.3-SNAPSHOT" > $W/gradle.properties; git -C $W commit -qam "7.1.x version"
	git -C $W branch -q embargoed/frozen/7.1.x 7.1.x
	git -C $W branch -q embargoed/active/7.0.x embargoed/frozen/7.0.x
	git -C $W branch -q embargoed/active/7.1.x embargoed/frozen/7.1.x
	local b
	git -C $W checkout -q -b feature/7.1.x/bug1 7.1.x
	git -C $W merge -q -X ours --no-edit -m "Merge branch '7.0.x' into '7.1.x'" feature/7.0.x/bug1
	git -C $W checkout -q -b feature/embargoed/frozen/7.1.x/bug1 embargoed/frozen/7.1.x
	git -C $W merge -q -X ours --no-edit -m "m" feature/7.1.x/bug1
	git -C $W merge -q -X ours --no-edit -m "m" feature/embargoed/frozen/7.0.x/bug1
	git -C $W checkout -q -b feature/embargoed/active/7.0.x/bug1 embargoed/active/7.0.x
	git -C $W merge -q -X ours --no-edit -m "m" feature/embargoed/frozen/7.0.x/bug1
	git -C $W checkout -q -b feature/embargoed/active/7.1.x/bug1 embargoed/active/7.1.x
	git -C $W merge -q -X ours --no-edit -m "m" feature/embargoed/frozen/7.1.x/bug1
	git -C $W merge -q -X ours --no-edit -m "m" feature/embargoed/active/7.0.x/bug1
	git -C $W checkout -q feature/7.0.x/bug1
	print -r -- "7.1.3" >> $FIX/ms_acme_proj.txt
}
# num_of BASE: the number of the pull request that was created into BASE (from the output)
num_of() { print -r -- "$out" | grep -E "created .*pull/[0-9]+ +$1\$" | sed -E "s|.*pull/([0-9]+).*|\1|" }

# Branches nobody asked for: only the OSS ones
oss_only() {
	git -C $W branch -qD feature/embargoed/frozen/7.0.x/bug1
}

run() {
	set +e
	out=$(cd $W && $SCRIPT "$@" 2>&1)
	rc=$?
	set -e
	[[ -n "$DEBUG" ]] && { echo "  \$ gh-prs $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /' }
	return 0
}

expect_rc() { [[ $rc -eq $1 ]] || { echo "    expected rc $1, got $rc"; echo "${out}" | sed 's/^/      | /'; return 1; } }
expect_out() { print -r -- "$out" | grep -qE -- "$1" || { echo "    expected output to match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; } }
reject_out() { print -r -- "$out" | grep -qE -- "$1" && { echo "    output must not match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; }; return 0 }
no_writes() { [[ ! -s $CALLS ]] || { echo "    unexpected writes:"; sed 's/^/      | /' $CALLS; return 1; } }
called() { grep -qF -- "$1" $CALLS || { echo "    expected call: $1"; sed 's/^/      | /' $CALLS; return 1; } }
not_called() { grep -qF -- "$1" $CALLS && { echo "    unexpected call: $1"; sed 's/^/      | /' $CALLS; return 1; }; return 0 }
# labels REPO NAME COLOR DESCRIPTION: a label of a repository
labels() {
	printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> $FIX/labels_${1//\//_}.tsv
}
# prs REPO HEAD BASE NUMBER STATE TITLE OWNER LABELS: an existing pull request
prs() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "https://github.com/$1/pull/$4" "$6" "$7" "$8" >> $FIX/prs_${1//\//_}.tsv
}
pushed() { git --git-dir=$R/$1.git rev-parse -q --verify "refs/heads/$2" > /dev/null }

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
t "args: help, missing command, unknown command and option" '
	run --help; expect_rc 0; expect_out "^Usage: gh-prs create"
	run; expect_rc 1; expect_out "A command is required"
	run merge; expect_rc 1; expect_out "Unknown command"
	run create -x; expect_rc 1; expect_out "Unknown option"
	run create --label; expect_rc 1; expect_out "requires a value"
	run create a b; expect_rc 1; expect_out "Unexpected argument"
'

t "feature: taken from the current branch, or required" '
	run create -n; expect_rc 0; expect_out "feature .bug1."
	git -C $W checkout -q main
	run create -n; expect_rc 1; expect_out "not a feature/<branch>/<name> branch"
	run create -n nope; expect_rc 1; expect_out "no branches named feature/<branch>/nope"
	run create -n bug1; expect_rc 0
'

t "dry run: prints the plan and changes nothing" '
	run create -n --yes; expect_rc 0
	expect_out "Push remotes: OSS branches -> me \(your fork\), embargoed branches -> commercial"
	expect_out "\(1\) feature/7.0.x/bug1 +-> +7.0.x +acme/proj +create"
	expect_out "\(3\) feature/embargoed/frozen/7.0.x/bug1 +-> +embargoed/frozen/7.0.x +acme/proj-commercial +create"
	expect_out "\(2\) feature/main/bug1 +-> +main +acme/proj +create"
	expect_out "git push -u me feature/7.0.x/bug1"
	expect_out "git push -u commercial feature/embargoed/frozen/7.0.x/bug1"
	expect_out "head: +me:feature/7.0.x/bug1"
	expect_out "Dry run: nothing was pushed or created"
	no_writes
	! pushed fork feature/7.0.x/bug1
'

t "order: oldest first, by what contains what" '
	run create -n --yes; expect_rc 0
	local o=$(print -r -- "$out" | grep -E "^  \([0-9]\) " | sed -E "s/^  \(([0-9])\) ([^ ]+).*/\1 \2/")
	[[ "$(print -r -- $o | head -1)" == "1 feature/7.0.x/bug1" ]]
'

t "defaults: first PR from the commit, forward PRs link to it" '
	run create --yes; expect_rc 0
	# 7.0.x first
	called "pr create -R acme/proj --base 7.0.x --head me:feature/7.0.x/bug1 --title Fix the thing --body Longer description of the fix. --assignee @me --milestone 7.0.9"
	not_called "--base 7.0.x --head me:feature/7.0.x/bug1 --title Fix the thing --body Longer description of the fix. --assignee @me --label"
	called "pr create -R acme/proj --base main --head me:feature/main/bug1 --title Merge Fix the thing --body Forward merge of gh-100 --assignee @me --label status: forward-port --milestone 7.2.0"
	called "pr create -R acme/proj-commercial --base embargoed/frozen/7.0.x --head feature/embargoed/frozen/7.0.x/bug1 --title Merge Fix the thing into embargoed/frozen/7.0.x --body Merge of acme/proj#100 into embargoed/frozen/7.0.x --assignee @me --label status: forward-port"
	[[ "$(grep -F "proj-commercial --base" $CALLS)" != *--milestone* ]]
	pushed fork feature/7.0.x/bug1
	pushed fork feature/main/bug1
	pushed commercial feature/embargoed/frozen/7.0.x/bug1
	! pushed oss feature/7.0.x/bug1
	expect_out "created +https://github.com/acme/proj/pull/100 +7.0.x"
	expect_out "Done! 3 pull request\(s\): 3 created, 0 updated"
	[[ "$(git -C $W config branch.feature/7.0.x/bug1.remote)" == me ]]
'

t "remote: no fork remote falls back to oss, none at all fails" '
	git -C $W remote remove me
	oss_only
	run create --yes; expect_rc 0
	pushed oss feature/7.0.x/bug1
	called "--head feature/7.0.x/bug1 --title Fix the thing"
	git -C $W remote remove oss
	git -C $W remote add origin git@github.com:acme/proj.git
	run create -n --yes; expect_rc 1
	expect_out "no remote to push to"
'

t "remote: embargoed branches need the commercial remote and never go anywhere else" '
	git -C $W remote remove commercial
	run create --yes; expect_rc 1
	expect_out "feature/embargoed/frozen/7.0.x/bug1: embargoed branches must be pushed to the .commercial. remote"
	no_writes
	! pushed fork feature/7.0.x/bug1
	! pushed oss feature/embargoed/frozen/7.0.x/bug1
	! pushed fork feature/embargoed/frozen/7.0.x/bug1
'

t "validation: a missing milestone is reported with the hint" '
	print -r -- "7.0.9" > $FIX/ms_acme_proj.txt
	run create --yes; expect_rc 1
	expect_out "milestone .7.2.0. does not exist \(open\) in acme/proj"
	expect_out "gh-milestones create"
	no_writes
	! pushed fork feature/7.0.x/bug1
'

t "missing labels: created after asking, with the color and description of the other repository" '
	rm $FIX/labels_acme_proj.tsv
	labels acme/proj "in: web" e8f9de "An issue in web modules"
	printf "y\n" > $R/tty
	GH_PRS_TTY=$R/tty run create; expect_rc 0
	expect_out "These labels do not exist in acme/proj:"
	expect_out "status: forward-port   color fef2c0, An issue tracking the forward-port"
	called "label create status: forward-port -R acme/proj --color fef2c0 --description An issue tracking the forward-port of a change made in an earlier branch"
	pushed fork feature/7.0.x/bug1
'

t "missing labels: --yes creates without asking, a label unknown everywhere gets the color of its kind" '
	rm $FIX/labels_acme_proj.tsv
	oss_only
	run create --yes --label "in: crypto" --label "theme: foo" --label "odd"; expect_rc 0
	called "label create in: crypto -R acme/proj --color e8f9de --description "
	called "label create theme: foo -R acme/proj --color F9D0C4 --description "
	called "label create odd -R acme/proj --color ededed --description "
	called "label create status: forward-port -R acme/proj --color fef2c0"
	called "pr create -R acme/proj --base 7.0.x"
'

t "missing labels: declined, or no terminal, stops before anything is pushed" '
	oss_only
	rm $FIX/labels_acme_proj.tsv
	printf "n\n" > $R/tty
	GH_PRS_TTY=$R/tty run create; expect_rc 1; expect_out "the labels are needed"
	GH_PRS_TTY=$R/nothing run create; expect_rc 1; expect_out "no terminal to ask"
	no_writes
	! pushed fork feature/7.0.x/bug1
'

t "missing labels: a dry run only says what it would create" '
	rm $FIX/labels_acme_proj.tsv
	run create -n --yes --label "in: crypto"; expect_rc 0
	expect_out "These labels do not exist in acme/proj, a real run would ask to create them"
	expect_out "in: crypto   color e8f9de"
	no_writes
'

t "options: --no-forward-label, --label, --assignee, --reviewer, --milestone, --draft" '
	oss_only
	run create --yes --no-forward-label --label "in: web" --assignee rwinch --reviewer jzheaux --milestone 7.2.0 --draft; expect_rc 0
	not_called "status: forward-port"
	called "--assignee rwinch --label in: web --reviewer jzheaux --milestone 7.2.0 --draft"
	not_called "@me"
'

t "milestone comes from the version of gradle.properties of each base branch" '
	run create -n --yes; expect_rc 0
	expect_out "milestone: 7.0.9 "
	expect_out "milestone: 7.2.0 "
	expect_out "milestone: \(none, same as the OSS PR\)"
'

t "embargoed: every PR links the PR of its own generation and none gets a milestone" '
	add_generations
	run create --yes; expect_rc 0
	local oss70=$(num_of 7.0.x) oss71=$(num_of 7.1.x) f70=$(num_of embargoed/frozen/7.0.x) f71=$(num_of embargoed/frozen/7.1.x)
	[[ -n $oss70 && -n $oss71 && -n $f70 && -n $f71 ]]
	called "--base embargoed/frozen/7.0.x --head feature/embargoed/frozen/7.0.x/bug1 --title Merge Fix the thing into embargoed/frozen/7.0.x --body Merge of acme/proj#$oss70 into embargoed/frozen/7.0.x"
	called "--base embargoed/frozen/7.1.x --head feature/embargoed/frozen/7.1.x/bug1 --title Merge Fix the thing into embargoed/frozen/7.1.x --body Merge of acme/proj#$oss71 into embargoed/frozen/7.1.x"
	called "--base embargoed/active/7.0.x --head feature/embargoed/active/7.0.x/bug1 --title Merge Fix the thing into embargoed/active/7.0.x --body Merge of #$f70 into embargoed/active/7.0.x"
	called "--base embargoed/active/7.1.x --head feature/embargoed/active/7.1.x/bug1 --title Merge Fix the thing into embargoed/active/7.1.x --body Merge of #$f71 into embargoed/active/7.1.x"
	[[ "$(grep -F "proj-commercial --base" $CALLS | grep -c -- --milestone)" == 0 ]]
	[[ "$(grep -F "pr create -R acme/proj --base" $CALLS | grep -c -- --milestone)" == 3 ]]
'

t "embargoed: an explicit --milestone is applied to every PR" '
	print -r -- "7.0.9" >> $FIX/ms_acme_proj-commercial.txt
	run create --yes --milestone 7.0.9; expect_rc 0
	[[ "$(grep -c -- "--milestone 7.0.9" $CALLS)" == 3 ]]
'

t "embargoed: a chain of only embargoed branches keeps the milestone of the first PR" '
	git -C $W branch -qD feature/7.0.x/bug1 2>/dev/null || { git -C $W checkout -q main; git -C $W branch -qD feature/7.0.x/bug1 }
	git -C $W branch -qD feature/main/bug1
	git -C $W checkout -q feature/embargoed/frozen/7.0.x/bug1
	run create -n --yes; expect_rc 0
	expect_out "milestone: 7.0.9.1 "
'

t "embargoed: a re-run edits the PR and leaves its milestone alone" '
	prs acme/proj feature/7.0.x/bug1 7.0.x 100 OPEN "Fix the thing" me ""
	prs acme/proj-commercial feature/embargoed/frozen/7.0.x/bug1 embargoed/frozen/7.0.x 300 OPEN old acme ""
	run create --yes; expect_rc 0
	called "pr edit 300 -R acme/proj-commercial --title Merge Fix the thing into embargoed/frozen/7.0.x --body Merge of acme/proj#100 into embargoed/frozen/7.0.x"
	[[ "$(grep -F "pr edit 300" $CALLS)" != *--milestone* ]]
'

t "re-run updates the open PRs and derives the forward titles again" '
	oss_only
	prs acme/proj feature/7.0.x/bug1 7.0.x 100 OPEN old me "in: web"
	prs acme/proj feature/main/bug1 main 101 OPEN old me ""
	run create --yes --title "A new title"; expect_rc 0
	not_called "pr create"
	called "pr edit 100 -R acme/proj --title A new title"
	expect_out "updated +https://github.com/acme/proj/pull/100"
	expect_out "Done! 2 pull request\(s\): 0 created, 2 updated"
'

t "re-run: an existing first PR gives the number for the new forward PRs and the PR is edited" '
	oss_only
	prs acme/proj feature/7.0.x/bug1 7.0.x 200 OPEN "Fix the thing" me ""
	run create --yes; expect_rc 0
	called "pr edit 200 -R acme/proj --title Fix the thing"
	called "--body Forward merge of gh-200"
	expect_out "updated +https://github.com/acme/proj/pull/200"
	expect_out "created"
'

t "a merged or closed PR is a problem" '
	oss_only
	prs acme/proj feature/7.0.x/bug1 7.0.x 200 MERGED Fix me ""
	run create --yes; expect_rc 1
	expect_out "pull request #200 .* is merged"
	no_writes
'

t "labels: asks for in:/type: labels, once per repository, applied to that repository" '
	printf "1 3\n2\n" > $R/tty
	GH_PRS_TTY=$R/tty run create; expect_rc 0
	expect_out "No .in: \*. or .type: \*. label was given. Labels of acme/proj"
	expect_out "1\) in: config|1\) in: web"
	called "--head me:feature/7.0.x/bug1 --title Fix the thing --body Longer description of the fix. --assignee @me --label in: web --label type: bug --milestone 7.0.9"
	called "--head me:feature/main/bug1 --title Merge Fix the thing --body Forward merge of gh-100 --assignee @me --label status: forward-port --label in: web --label type: bug --milestone 7.2.0"
	called "--head feature/embargoed/frozen/7.0.x/bug1 --title Merge Fix the thing into embargoed/frozen/7.0.x --body Merge of acme/proj#100 into embargoed/frozen/7.0.x --assignee @me --label status: forward-port --label type: bug"
'

t "labels: not asked with --yes, with an in: or type: label given, or when a PR has one" '
	run create -n; expect_out "would ask which of"
	run create -n --yes; reject_out "would ask"
	run create -n --label "type: bug"; reject_out "would ask"
	oss_only
	prs acme/proj feature/7.0.x/bug1 7.0.x 200 OPEN Fix me "in: web|type: bug"
	run create -n; reject_out "would ask"
'

t "labels: without a terminal it continues without them" '
	GH_PRS_TTY=$R/nothing run create; expect_rc 0
	expect_out "No terminal to ask"
	called "pr create -R acme/proj --base 7.0.x"
'

t "labels: a number that is not in the list stops the run" '
	print -r -- "99" > $R/tty
	GH_PRS_TTY=$R/tty run create; expect_rc 1
	expect_out "not one of the numbers"
	no_writes
'

echo ""
echo "passed: $pass, failed: $fail"
[[ $fail -eq 0 ]]
