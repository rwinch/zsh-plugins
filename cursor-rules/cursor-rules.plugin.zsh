# Cursor rules plugin: Provides a command to symlink ~/code/rwinch/.cursor/rules 
# into the current directory's .cursor/rules.



function cursor-rules() {
  export CURSOR_RULES_SOURCE=~/code/rwinch/.cursor/rules
  if [[ ! -d "$CURSOR_RULES_SOURCE" ]]; then
    echo "cursor-rules: Source directory $CURSOR_RULES_SOURCE does not exist" >&2
    return 1
  fi

  mkdir -p "$PWD/.cursor"
  ln -sfn "$CURSOR_RULES_SOURCE" "$PWD/.cursor/rules"
  echo "Linked $CURSOR_RULES_SOURCE -> $PWD/.cursor/rules"
}
