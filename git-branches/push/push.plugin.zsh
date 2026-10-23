export PATH=$(dirname $0):${PATH}

alias gbbph=git-branches-push

# gbbph with the OSS branches and --disclosures filled in, extra options are passed on (--no-disclosures leaves the disclosures out)
gbbpha() {
	local -a disclosures=(--disclosures) no_disclosures
	zparseopts -D -E -- -no-disclosures=no_disclosures
	(( $#no_disclosures )) && disclosures=()
	git-branches-push $(spring-versions --type oss --field branch --line) $disclosures "$@"
}
