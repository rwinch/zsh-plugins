export PATH=$(dirname $0):${PATH}

alias gbbf=git-branches-fetch

# gbbf with the OSS branches and --disclosures filled in, extra options are passed on (--no-disclosures leaves the disclosures out)
gbbfa() {
	local -a disclosures=(--disclosures) no_disclosures
	zparseopts -D -E -- -no-disclosures=no_disclosures
	(( $#no_disclosures )) && disclosures=()
	git-branches-fetch $(spring-versions --type oss --field branch --line) $disclosures "$@"
}
