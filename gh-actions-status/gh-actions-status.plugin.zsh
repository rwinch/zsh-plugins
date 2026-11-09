export PATH=$(dirname $0):${PATH}

alias ghas=gh-actions-status

# Spring Security and Spring Session with their commercial repositories, showing only what is
# failing. Pass -s/--status to choose other statuses, or --all to show everything.
ghasa() {
	local -a defaults args=("$@")
	if (( ${args[(I)--all]} )); then
		args=(${args:#--all})
	elif (( ! ${args[(I)(-s|--status|--status=*)]} )); then
		defaults=(-s failure)
	fi
	gh-actions-status $defaults "${args[@]}" \
		spring-projects/spring-security spring-projects/spring-security-commercial \
		spring-projects/spring-session spring-projects/spring-session-commercial
}
