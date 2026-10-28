#!/bin/zsh
# Tests for git-clone-convention. Builds throwaway bare repos under a temp dir that
# stand in for GitHub/GitLab (git url.insteadOf rewrites the SSH and HTTPS URLs to
# them), stubs gh with a script driven by environment variables, and runs the script
# with HOME pointing into the temp dir so ~/code is sandboxed.
#
# Usage: test/test.sh [name-filter]

SCRIPT="${0:A:h:h}/git-clone-convention"
PLUGIN="${0:A:h:h}/git-clone-convention.plugin.zsh"
FILTER="$1"
pass=0
fail=0
out=""
sout=""
rc=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_EDITOR=true

# ---- fixture ----
# $R root. $R/remotes/OWNER/REPO.git are the "hosted" repos, $R/home is HOME, $R/bin holds
# the gh stub. gh answers from $R/gh-repos (lines of 'OWNER/REPO true|false', private flag).
mkremote() { # OWNER REPO [DEFAULT-BRANCH]
	local b="${3:-main}" s=$R/seed-$1-$2
	mkdir -p $R/remotes/$1
	git init -q --bare -b $b $R/remotes/$1/$2.git
	git init -q -b $b $s
	echo "$1/$2" > $s/f; git -C $s add f; git -C $s commit -qm "seed $1/$2"
	git -C $s push -q $R/remotes/$1/$2.git $b
}

setup() {
	R=$(mktemp -d); R=${R:A}
	mkdir -p $R/home $R/bin
	mkremote spring-projects spring-security
	mkremote spring-projects spring-security-commercial
	mkremote rwinch spring-security
	mkremote spring-projects spring-framework
	mkremote mongodb mongo-java-driver master
	mkremote mygroup myproject
	mkremote rwinch zsh-plugins
	cat > $R/bin/gh <<'EOF'
#!/bin/zsh
if [[ -n "$GH_STUB_FAIL" ]]; then
	echo "gh: To get started with GitHub CLI, please run:  gh auth login" >&2
	exit 4
fi
echo "$@" >> "$GH_STUB_LOG"
case $2 in
	user) echo "$GH_STUB_LOGIN" ;;
	repos/*)
		if [[ "$*" == *permissions.admin* ]]; then
			grep -qx "${2#repos/}" "$GH_STUB_NOT_ADMIN" && echo false || echo true
			exit 0
		fi
		line=$(grep "^${2#repos/} " "$GH_STUB_REPOS") || { echo "gh: Not Found (HTTP 404)" >&2; exit 1 }
		echo "${line#* }"
		;;
esac
EOF
	chmod +x $R/bin/gh
	: > $R/gh-repos
	: > $R/not-admin
	export GH_STUB_NOT_ADMIN=$R/not-admin EMB_LOG=$R/emb-log EMB_DIR=$R/emb
	mkdir -p $R/emb; : > $R/emb-log
	: > $R/gh-log
	export GH_STUB_REPOS=$R/gh-repos GH_STUB_LOG=$R/gh-log GH_STUB_LOGIN=rwinch
	unset GH_STUB_FAIL
	export GIT_CONFIG_COUNT=3
	export GIT_CONFIG_KEY_0="url.$R/remotes/.insteadOf" GIT_CONFIG_VALUE_0="git@github.com:"
	export GIT_CONFIG_KEY_1="url.$R/remotes/.insteadOf" GIT_CONFIG_VALUE_1="https://github.com/"
	export GIT_CONFIG_KEY_2="url.$R/remotes/.insteadOf" GIT_CONFIG_VALUE_2="git@gitlab.com:"
	CODE=$R/home/code
	CLEAN_PATH="/usr/bin:/bin"
}

# with_ghbeb: install a stub gh-block-embargoed-branches. check exits with the number in
# $EMB_DIR/OWNER_REPO (default 0 = protected), apply exits with $EMB_APPLY_RC (default 0).
with_ghbeb() {
	cat > $R/bin/gh-block-embargoed-branches <<'EOF2'
#!/bin/zsh
echo "$@" >> "$EMB_LOG"
case $1 in
	check)
		f=$EMB_DIR/${2//\//_}
		rc=0; [[ -e $f ]] && rc=$(<$f)
		(( rc == 0 )) && echo "$2  protected"
		(( rc == 1 )) && echo "$2  NOT PROTECTED"
		(( rc == 2 )) && echo "$2  unknown (HTTP 500)"
		exit $rc ;;
	apply) exit ${EMB_APPLY_RC:-0} ;;
esac
EOF2
	chmod +x $R/bin/gh-block-embargoed-branches
}
# embargo_state OWNER/REPO RC: what the stub check reports
embargo_state() { echo $2 > $R/emb/${1//\//_} }
# run_tty ANSWER ARGS...: like run, but stdin is a terminal that has ANSWER typed on it
run_tty() {
	local ans=$1; shift
	set +e
	(cd $R && HOME=$R/home PATH=$R/bin:$PATH python3 -c '
import os, subprocess, sys
m, s = os.openpty()
os.write(m, sys.argv[1].encode())
sys.exit(subprocess.run(sys.argv[2:], stdin=s).returncode)
' "$ans" $SCRIPT "$@" > $R/stdout 2> $R/stderr)
	rc=$?
	set -e
	out=$(<$R/stderr); sout=$(<$R/stdout)
}
emb_calls() { grep -c "$1" $R/emb-log; true }

# gh_has OWNER/REPO PRIVATE: make the gh stub know a repository
gh_has() { echo "$1 $2" >> $R/gh-repos }

run() {
	set +e
	(cd $R && HOME=$R/home PATH=$R/bin:$PATH $SCRIPT "$@" > $R/stdout 2> $R/stderr)
	rc=$?
	set -e
	out=$(<$R/stderr); sout=$(<$R/stdout)
	[[ -n "$DEBUG" ]] && { echo "  \$ git-clone-convention $*  (rc $rc)"; print -r -- "$out" | sed 's/^/    | /'; print -r -- "$sout" | sed 's/^/    > /' }
	return 0
}

expect_rc() { [[ $rc -eq $1 ]] || { echo "    expected rc $1, got $rc"; echo "${out}" | sed 's/^/      | /'; return 1; } }
expect_out() { print -r -- "$out" | grep -qE -- "$1" || { echo "    expected output to match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; } }
reject_out() { print -r -- "$out" | grep -qE -- "$1" && { echo "    output must not match: $1"; echo "${out}" | sed 's/^/      | /'; return 1; }; return 0 }
expect_sout() { [[ "$sout" == "$1" ]] || { echo "    expected stdout '$1', got '$sout'"; return 1; } }
remotes_of() { git -C $1 remote | sort | tr '\n' ' ' }
remote_url() { git -C $1 config remote.$2.url }
gh_not_called() { [[ ! -s $R/gh-log ]] }

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
t "args: none, unknown directory, two repositories, --origin, --host without value" '
	run; expect_rc 1; expect_out "Missing OWNER/REPOSITORY"
	run a/b c; expect_rc 1; expect_out "Unexpected argument"
	run --origin x a/b; expect_rc 1; expect_out "chooses the remote names"
	run --host; expect_rc 1; expect_out "requires a value"
	run notaslug; expect_rc 1; expect_out "Invalid repository"
'

t "help goes to stderr and prints nothing on stdout" '
	run --help; expect_rc 0; expect_out "Usage: clone"
	expect_sout ""
'

t "plain clone without a commercial repo: remote is the owner" '
	run spring-projects/spring-framework; expect_rc 0
	expect_sout "$CODE/spring-projects/spring-framework/main"
	[[ "$(remotes_of $CODE/spring-projects/spring-framework/main)" == "spring-projects " ]]
	[[ $(remote_url $CODE/spring-projects/spring-framework/main spring-projects) == git@github.com:spring-projects/spring-framework.git ]]
'

t "commercial repo: remotes are oss and commercial, oss is fetched" '
	gh_has spring-projects/spring-security-commercial true
	run spring-projects/spring-security; expect_rc 0
	local d=$CODE/spring-projects/spring-security/main
	expect_sout "$d"
	[[ "$(remotes_of $d)" == "commercial oss " ]]
	[[ $(remote_url $d commercial) == git@github.com:spring-projects/spring-security-commercial.git ]]
	[[ $(remote_url $d oss) == git@github.com:spring-projects/spring-security.git ]]
	git -C $d rev-parse --verify -q refs/remotes/oss/main > /dev/null
	git -C $d rev-parse --verify -q refs/remotes/commercial/main > /dev/null
	expect_out "Adding remote commercial"
'

t "public commercial repo is ignored" '
	gh_has spring-projects/spring-security-commercial false
	run spring-projects/spring-security; expect_rc 0
	[[ "$(remotes_of $CODE/spring-projects/spring-security/main)" == "spring-projects " ]]
'

t "fork is added as the login and fetched" '
	gh_has rwinch/spring-security false
	run spring-projects/spring-security; expect_rc 0
	local d=$CODE/spring-projects/spring-security/main
	[[ "$(remotes_of $d)" == "rwinch spring-projects " ]]
	[[ $(remote_url $d rwinch) == git@github.com:rwinch/spring-security.git ]]
	git -C $d rev-parse --verify -q refs/remotes/rwinch/main > /dev/null
'

t "commercial repo and fork together" '
	gh_has spring-projects/spring-security-commercial true
	gh_has rwinch/spring-security false
	run spring-projects/spring-security; expect_rc 0
	[[ "$(remotes_of $CODE/spring-projects/spring-security/main)" == "commercial oss rwinch " ]]
'

t "no fork remote when the login is the owner" '
	GH_STUB_LOGIN=rwinch
	gh_has rwinch/zsh-plugins false
	run rwinch/zsh-plugins; expect_rc 0
	[[ "$(remotes_of $CODE/rwinch/zsh-plugins/main)" == "rwinch " ]]
'

t "gh not installed: warns and clones with the owner remote" '
	set +e
	(cd $R && HOME=$R/home PATH=$CLEAN_PATH $SCRIPT spring-projects/spring-framework > $R/stdout 2> $R/stderr); rc=$?
	set -e
	out=$(<$R/stderr)
	expect_rc 0; expect_out "gh is not installed"
	[[ "$(remotes_of $CODE/spring-projects/spring-framework/main)" == "spring-projects " ]]
'

t "gh failing: warns and clones with the owner remote" '
	export GH_STUB_FAIL=1
	run spring-projects/spring-security; expect_rc 0
	expect_out "gh lookup failed"
	[[ "$(remotes_of $CODE/spring-projects/spring-security/main)" == "spring-projects " ]]
'

t "non-GitHub host: no gh lookups, no warning" '
	run --gitlab mygroup/myproject; expect_rc 0
	gh_not_called
	reject_out "gh"
	[[ "$(remotes_of $CODE/mygroup/myproject/main)" == "mygroup " ]]
	[[ $(remote_url $CODE/mygroup/myproject/main mygroup) == git@gitlab.com:mygroup/myproject.git ]]
'

t "URLs: ssh, https and https without .git" '
	run git@github.com:spring-projects/spring-framework.git; expect_rc 0
	[[ $(remote_url $CODE/spring-projects/spring-framework/main spring-projects) == git@github.com:spring-projects/spring-framework.git ]]
	rm -rf $CODE
	run https://github.com/spring-projects/spring-framework.git; expect_rc 0
	[[ $(remote_url $CODE/spring-projects/spring-framework/main spring-projects) == https://github.com/spring-projects/spring-framework.git ]]
	rm -rf $CODE
	run https://github.com/spring-projects/spring-framework; expect_rc 0
	expect_sout "$CODE/spring-projects/spring-framework/main"
'

t "--https builds https URLs, also for the added remotes" '
	gh_has spring-projects/spring-security-commercial true
	run --https spring-projects/spring-security; expect_rc 0
	local d=$CODE/spring-projects/spring-security/main
	[[ $(remote_url $d oss) == https://github.com/spring-projects/spring-security.git ]]
	[[ $(remote_url $d commercial) == https://github.com/spring-projects/spring-security-commercial.git ]]
'

t "default branch other than main renames the directory" '
	run mongodb/mongo-java-driver; expect_rc 0
	expect_sout "$CODE/mongodb/mongo-java-driver/master"
	[[ -d $CODE/mongodb/mongo-java-driver/master/.git ]]
	[[ ! -e $CODE/mongodb/mongo-java-driver/main ]]
'

t "git clone options pass through, including values that look like a repository" '
	run --no-tags spring-projects/spring-framework; expect_rc 0
	[[ $(git -C $CODE/spring-projects/spring-framework/main config remote.spring-projects.tagOpt) == --no-tags ]]
	rm -rf $CODE
	run --branch main spring-projects/spring-framework --single-branch; expect_rc 0
	expect_sout "$CODE/spring-projects/spring-framework/main"
'

t "already cloned: cd only, no lookups, no changes" '
	mkdir -p $CODE/spring-projects/spring-security/master
	run spring-projects/spring-security; expect_rc 0
	expect_out "already exists"
	expect_sout "$CODE/spring-projects/spring-security/master"
	gh_not_called
	rm -rf $CODE/spring-projects/spring-security/master
	run spring-projects/spring-security; expect_sout "$CODE/spring-projects/spring-security"
'

t "failed clone removes what it created and nothing else" '
	run nobody/nothing; expect_rc 1
	expect_out "git clone failed"
	[[ ! -e $CODE/nobody ]]
	mkdir -p $CODE/nobody2
	run nobody2/nothing; expect_rc 1
	[[ -d $CODE/nobody2 && ! -e $CODE/nobody2/nothing ]]
'

t "dry-run changes nothing and prints the plan" '
	gh_has spring-projects/spring-security-commercial true
	gh_has rwinch/spring-security false
	run --dry-run spring-projects/spring-security; expect_rc 0
	expect_sout ""
	[[ ! -e $CODE ]]
	expect_out "Looking up spring-projects/spring-security-commercial... found \(private\)"
	expect_out "Looking up rwinch/spring-security \(fork\)... found"
	expect_out "Plan \(clone\):"
	expect_out "directory   ~/code/spring-projects/spring-security/main"
	expect_out "branch      main \(default branch\)"
	expect_out "oss         git@github.com:spring-projects/spring-security.git"
	expect_out "commercial  git@github.com:spring-projects/spring-security-commercial.git"
	expect_out "rwinch      git@github.com:rwinch/spring-security.git"
	expect_out "Dry run, nothing was cloned."
'

t "dry-run for an existing clone" '
	mkdir -p $CODE/spring-projects/spring-security/main
	run --dry-run spring-projects/spring-security; expect_rc 0
	expect_out "Would change directory to ~/code/spring-projects/spring-security/main"
	expect_out "Dry run, nothing was changed."
	expect_sout ""
'

t "dry-run shows the real default branch" '
	run --dry-run mongodb/mongo-java-driver; expect_rc 0
	expect_out "directory   ~/code/mongodb/mongo-java-driver/master"
	expect_out "master \(default branch\)"
'

# ---- wd ----
t "wd: shortcuts for a spring owner and repo, with prefixes removed" '
	run spring-projects/spring-security; expect_rc 0
	[[ "$sout" != *wd* ]]
	run_wd() { set +e; (cd $R && HOME=$R/home PATH=$R/bin:$PATH GIT_CLONE_CONVENTION_WD=1 $SCRIPT "$@" > $R/stdout 2> $R/stderr); rc=$?; set -e; out=$(<$R/stderr); sout=$(<$R/stdout) }
	rm -rf $CODE
	run_wd spring-projects/spring-security; expect_rc 0
	print -r -- "$sout" | grep -qxF "$(printf "wd\tprojects\t$CODE/spring-projects")"
	print -r -- "$sout" | grep -qxF "$(printf "wd\tsecurity\t$CODE/spring-projects/spring-security/main")"
	expect_out "Adding wd shortcut: security"
'

t "wd: a repo without spring- gets its full name, the owner gets none" '
	set +e; (cd $R && HOME=$R/home PATH=$R/bin:$PATH GIT_CLONE_CONVENTION_WD=1 $SCRIPT mongodb/mongo-java-driver > $R/stdout 2> $R/stderr); rc=$?; set -e
	out=$(<$R/stderr); sout=$(<$R/stdout)
	expect_rc 0
	print -r -- "$sout" | grep -qxF "$(printf "wd\tmongo-java-driver\t$CODE/mongodb/mongo-java-driver/master")"
	[[ $(print -r -- "$sout" | grep -c "^wd") -eq 1 ]]
'

t "wd: not installed is reported when there is something to add" '
	run spring-projects/spring-security; expect_rc 0
	expect_out "wd is not installed, so no shortcuts will be added \(projects, security\)"
'

t "wd: an existing shortcut is left alone with a warning" '
	echo "security:~/code/elsewhere" > $R/home/.warprc
	set +e; (cd $R && HOME=$R/home PATH=$R/bin:$PATH GIT_CLONE_CONVENTION_WD=1 $SCRIPT spring-projects/spring-security > $R/stdout 2> $R/stderr); rc=$?; set -e
	out=$(<$R/stderr); sout=$(<$R/stdout)
	expect_rc 0
	expect_out "wd shortcut .security. already exists \(-> ~/code/elsewhere\), not changed"
	[[ $(print -r -- "$sout" | grep -c "^wd.*security") -eq 0 ]]
	print -r -- "$sout" | grep -q "projects"
'

# ---- the clone function ----
t "clone function: changes directory and adds the wd shortcuts" '
	local res
	res=$(HOME=$R/home PATH=$R/bin:$PATH zsh -c "
		wd() { print -r -- \"\$@\" >> $R/wd-calls }
		source $PLUGIN
		clone spring-projects/spring-security 2>/dev/null
		print -r -- \$PWD
	")
	[[ "$res" == "$CODE/spring-projects/spring-security/main" ]]
	grep -qxF "addcd $CODE/spring-projects projects" $R/wd-calls
	grep -qxF "addcd $CODE/spring-projects/spring-security/main security" $R/wd-calls
'

t "clone function: dry-run does not change directory" '
	local res
	res=$(cd $R && HOME=$R/home PATH=$R/bin:$PATH zsh -c "
		source $PLUGIN
		clone --dry-run spring-projects/spring-security 2>/dev/null
		print -r -- \$PWD
	")
	[[ "$res" == "$R" ]]
'

# ---- embargoed branch protection ----
emb_setup() {
	gh_has spring-projects/spring-security-commercial true
	gh_has spring-projects/spring-security true
	gh_has rwinch/spring-security false
	with_ghbeb
}

t "embargo: command not installed warns at the end" '
	emb_setup; rm $R/bin/gh-block-embargoed-branches
	run spring-projects/spring-security; expect_rc 0
	expect_out "Warning: gh-block-embargoed-branches is not installed.*spring-projects/spring-security, rwinch/spring-security"
	expect_sout "$CODE/spring-projects/spring-security/main"
'

t "embargo: both protected, nothing asked or applied" '
	emb_setup
	run_tty "" spring-projects/spring-security; expect_rc 0
	expect_out "Checking that embargoed/\*\* branches are blocked in spring-projects/spring-security, rwinch/spring-security"
	reject_out "Warning: .*embargoed"; reject_out "Block embargoed"
	[[ $(emb_calls "^check ") -eq 2 && $(emb_calls "^apply") -eq 0 ]]
'

t "embargo: only the oss and fork repositories are checked, not commercial" '
	emb_setup
	run_tty "" spring-projects/spring-security
	! grep -q commercial $R/emb-log
'

t "embargo: unprotected, default answer sets it up in both" '
	emb_setup; embargo_state spring-projects/spring-security 1; embargo_state rwinch/spring-security 1
	run_tty "
" spring-projects/spring-security; expect_rc 0
	expect_out "Block embargoed/\*\* branches in spring-projects/spring-security, rwinch/spring-security now\? \[Y/n\]"
	grep -qx "apply spring-projects/spring-security rwinch/spring-security" $R/emb-log
	reject_out "Warning: .*embargoed"
'

t "embargo: answering n warns at the end and applies nothing" '
	emb_setup; embargo_state rwinch/spring-security 1
	run_tty "n
" spring-projects/spring-security; expect_rc 0
	expect_out "Warning: embargoed/\*\* branches are NOT blocked in rwinch/spring-security\. Run: gh-block-embargoed-branches rwinch/spring-security"
	[[ $(emb_calls "^apply") -eq 0 ]]
'

t "embargo: not an admin warns that it could not be set up, others still asked" '
	emb_setup; embargo_state spring-projects/spring-security 1; embargo_state rwinch/spring-security 1
	echo spring-projects/spring-security > $R/not-admin
	run_tty "y
" spring-projects/spring-security; expect_rc 0
	expect_out "Warning: embargoed/\*\* branches are NOT blocked in spring-projects/spring-security and you are not an admin.*Ask an admin"
	expect_out "Block embargoed/\*\* branches in rwinch/spring-security now"
	grep -qx "apply rwinch/spring-security" $R/emb-log
'

t "embargo: no terminal does not ask and warns with the command" '
	emb_setup; embargo_state rwinch/spring-security 1
	run spring-projects/spring-security; expect_rc 0
	expect_out "Warning: .*NOT blocked in rwinch/spring-security \(not asking without a terminal\)"
	[[ $(emb_calls "^apply") -eq 0 ]]
'

t "embargo: check that cannot read warns" '
	emb_setup; embargo_state rwinch/spring-security 2
	run_tty "" spring-projects/spring-security; expect_rc 0
	expect_out "Warning: Could not check whether embargoed/\*\* branches are blocked in rwinch/spring-security"
'

t "embargo: failing apply warns" '
	emb_setup; embargo_state rwinch/spring-security 1
	export EMB_APPLY_RC=1
	run_tty "y
" spring-projects/spring-security; expect_rc 0
	expect_out "Warning: Could not block embargoed/\*\* branches in rwinch/spring-security"
'

t "embargo: no commercial repository means no check" '
	gh_has spring-projects/spring-framework false; with_ghbeb
	run_tty "" spring-projects/spring-framework; expect_rc 0
	[[ ! -s $R/emb-log ]]; reject_out "embargoed"
'

t "embargo: dry-run checks but never asks or applies" '
	emb_setup; embargo_state rwinch/spring-security 1
	run --dry-run spring-projects/spring-security; expect_rc 0
	expect_out "Would ask to block embargoed/\*\* branches in rwinch/spring-security"
	[[ $(emb_calls "^check ") -eq 2 && $(emb_calls "^apply") -eq 0 ]]
'

echo ""
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
