export PATH=$(dirname $0):${PATH}

alias gbbcm=git-branches-check-merged

# gbbcm with the OSS branches and --disclosures filled in, extra options are passed on (--no-disclosures leaves the disclosures out)
gbbcma() {
	local -a disclosures=(--disclosures) no_disclosures
	zparseopts -D -E -- -no-disclosures=no_disclosures
	(( $#no_disclosures )) && disclosures=()
	git-branches-check-merged $(spring-versions --type oss --field branch --line) $disclosures "$@"
}
