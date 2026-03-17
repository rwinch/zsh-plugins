# Cursor rules plugin: Provides a command to symlink ~/code/rwinch/.cursor/rules 
# into the current git repo's .cursor/rules.

readonly CURSOR_RULES_SOURCE=~/code/rwinch/.cursor/rules

function cursor-rules() {
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  
  if [[ -z "$git_root" ]]; then
    echo "cursor-rules: Not in a git repository" >&2
    return 1
  fi

  if [[ ! -d "$CURSOR_RULES_SOURCE" ]]; then
    echo "cursor-rules: Source directory $CURSOR_RULES_SOURCE does not exist" >&2
    return 1
  fi

  mkdir -p "$git_root/.cursor"
  ln -sfn "$CURSOR_RULES_SOURCE" "$git_root/.cursor/rules"
  echo "Linked $CURSOR_RULES_SOURCE -> $git_root/.cursor/rules"
}
