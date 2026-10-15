# Loads every git-branches plugin (fetch, pull, reset-to-upstream, check-merged,
# merge-forward, release). To load only some, bundle the subfolders instead,
# for example: antigen bundle rwinch/zsh-plugins git-branches/fetch
for plugin in ${0:A:h}/*/*.plugin.zsh(N); do
	source $plugin
done
unset plugin
