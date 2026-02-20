# rdubbs: like robbyrussell but shows git repo path as branch@repo-path (no host).
# Example in ~/code/spring-projects/spring-security/main:
#   main git:(main@spring-projects/spring-security)

# Returns the git repo path relative to $HOME, with first path component stripped
# (e.g. ~/code/spring-projects/spring-security -> spring-projects/spring-security)
function _git_repo_path() {
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null) || return
  local repo_path="${git_root#$HOME/}"
  # Strip first path component so "code/spring-projects/spring-security" -> "spring-projects/spring-security"
  if [[ "$repo_path" == */* ]]; then
    echo "${repo_path#*/}"
  else
    echo "$repo_path"
  fi
}

# Git prompt info with branch and repo path: branch@repo-path
function git_prompt_info_with_repo() {
  if [[ "$(command git config --get oh-my-zsh.hide-status 2>/dev/null)" == "1" ]]; then
    return
  fi
  local ref
  ref=$(command git symbolic-ref HEAD 2>/dev/null) || \
    ref=$(command git rev-parse --short HEAD 2>/dev/null) || return 0
  local branch="${ref#refs/heads/}"
  local repo_path
  repo_path=$(_git_repo_path) || return 0
  local dirty
  if [[ -n $(command git status --porcelain 2>/dev/null) ]]; then
    dirty="$ZSH_THEME_GIT_PROMPT_DIRTY"
  else
    dirty="$ZSH_THEME_GIT_PROMPT_CLEAN"
  fi
  echo "${ZSH_THEME_GIT_PROMPT_PREFIX}${branch}@${repo_path}${dirty}${ZSH_THEME_GIT_PROMPT_SUFFIX}"
}

# Same PROMPT as robbyrussell: green/red arrow, cyan %c (current dir)
PROMPT="%(?:%{$fg_bold[green]%}%1{➜%} :%{$fg_bold[red]%}%1{➜%} ) %{$fg[cyan]%}%c%{$reset_color%}"
PROMPT+=' $(git_prompt_info_with_repo)'

# Reuse robbyrussell git prompt styling
ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg_bold[blue]%}git:(%{$fg[red]%}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%} "
ZSH_THEME_GIT_PROMPT_DIRTY="%{$fg[blue]%}) %{$fg[yellow]%}%1{✗%}"
ZSH_THEME_GIT_PROMPT_CLEAN="%{$fg[blue]%})"
