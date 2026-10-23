export PATH=$(dirname $0):${PATH}

alias gbbrtu=git-branches-reset-to-upstream

# gbbrtu with the OSS branches and --disclosures filled in, extra options are passed on (gbbrtua --undo undoes it) (--no-disclosures leaves the disclosures out)
gbbrtua() {
	local -a disclosures=(--disclosures) no_disclosures
	zparseopts -D -E -- -no-disclosures=no_disclosures
	(( $#no_disclosures )) && disclosures=()
	git-branches-reset-to-upstream $(spring-versions --type oss --field branch --line) $disclosures "$@"
}
