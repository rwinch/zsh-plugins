export PATH=$(dirname $0):${PATH}

alias ghm=gh-milestones

# OSS milestones due this month plus commercial hotfixes due next month, comma separated
ghmr() {
	{
		gh-milestones list --oss-only --this-month --oneline "$@"
		gh-milestones list --commercial-only --next-month --hotfixes --oneline "$@"
	} | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -
}
