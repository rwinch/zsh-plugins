# Cursor rules plugin: symlink ~/code/rwinch/.cursor/rules into the current git repo's .cursor/rules.
# Sets git_root to the root of the current directory's git repository.

readonly CURSOR_RULES_SOURCE=~/code/rwinch/.cursor/rules

function _cursor_rules_git_root() {
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  [[ -n "$git_root" ]]
}

function _cursor_rules_ensure_link() {
  git_root=
  _cursor_rules_git_root || return 0
  [[ -d "$CURSOR_RULES_SOURCE" ]] || return 0
  mkdir -p "$git_root/.cursor"
  ln -sf "$CURSOR_RULES_SOURCE" "$git_root/.cursor/rules"
}

function _cursor_rules_chpwd() {
  if _cursor_rules_git_root; then
    export git_root
    _cursor_rules_ensure_link
  else
    unset git_root
  fi
}

# Run on directory change and set git_root for the current repo
chpwd_functions+=(_cursor_rules_chpwd)

# Run once for the shell's current directory
_cursor_rules_chpwd
