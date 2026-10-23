export PATH=$(dirname $0):${PATH}

alias gbbmf=git-branches-merge-forward

# gbbmf with the OSS branches and --disclosures filled in, extra options are passed on (--no-disclosures leaves the disclosures out)
gbbmfa() {
	local -a disclosures=(--disclosures) no_disclosures
	zparseopts -D -E -- -no-disclosures=no_disclosures
	(( $#no_disclosures )) && disclosures=()
	git-branches-merge-forward $(spring-versions --type oss --field branch --line) $disclosures "$@"
}
