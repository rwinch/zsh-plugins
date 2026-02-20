# rdubbs: like robbyrussell but shows repo name in git prompt when repo is under ~/code (grand child only).
# Example in ~/code/spring-projects/spring-security/main:
#   main git:(main@spring-security)

# Outputs the repo name only when under ~/code with exactly 3 path segments (org/repo/worktree), i.e. in a worktree.
# Main clones at ~/code/org/repo (2 segments) output nothing. Uses --show-toplevel (worktree root when in a worktree).
# Example: ~/code/spring-projects/spring-security/main -> spring-security; ~/code/rwinch/zsh-plugins -> nothing
function _git_repo_path() {
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null) || return
  [[ -z "$git_root" ]] && return
  local repo_path="${git_root#$HOME/}"
  [[ "$repo_path" != code/* ]] && return
  local under_code="${repo_path#code/}"
  # Exactly 3 segments (org/repo/worktree): output the repo name (second segment)
  [[ "$under_code" != */*/* ]] && return
  [[ "$under_code" == */*/*/* ]] && return
  local rest="${under_code#*/}"
  echo "${rest%%/*}"
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
  repo_path=$(_git_repo_path) 2>/dev/null
  local dirty
  if [[ -n $(command git status --porcelain 2>/dev/null) ]]; then
    dirty="$ZSH_THEME_GIT_PROMPT_DIRTY"
  else
    dirty="$ZSH_THEME_GIT_PROMPT_CLEAN"
  fi
  if [[ -n "$repo_path" ]]; then
    echo "${ZSH_THEME_GIT_PROMPT_PREFIX}${branch}@${repo_path}${dirty}${ZSH_THEME_GIT_PROMPT_SUFFIX}"
  else
    echo "${ZSH_THEME_GIT_PROMPT_PREFIX}${branch}${dirty}${ZSH_THEME_GIT_PROMPT_SUFFIX}"
  fi
}

# Same PROMPT as robbyrussell: green/red arrow, cyan %c (current dir)
PROMPT="%(?:%{$fg_bold[green]%}%1{➜%} :%{$fg_bold[red]%}%1{➜%} ) %{$fg[cyan]%}%c%{$reset_color%}"
PROMPT+=' $(git_prompt_info_with_repo)'

# Reuse robbyrussell git prompt styling
ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg_bold[blue]%}git:(%{$fg[red]%}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%} "
ZSH_THEME_GIT_PROMPT_DIRTY="%{$fg[blue]%}) %{$fg[yellow]%}%1{✗%}"
ZSH_THEME_GIT_PROMPT_CLEAN="%{$fg[blue]%})"
