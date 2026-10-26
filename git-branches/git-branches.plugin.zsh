# Loads every git-branches plugin (fetch, pull, reset-to-upstream, check-merged,
# merge-forward, release). To load only some, bundle the subfolders instead,
# for example: antigen bundle rwinch/zsh-plugins git-branches/fetch
# Completion files live in the subfolders, so put them on fpath (before compinit runs).
fpath=(${0:A:h}/*(/N) $fpath)

for plugin in ${0:A:h}/*/*.plugin.zsh(N); do
	source $plugin
done
unset plugin
