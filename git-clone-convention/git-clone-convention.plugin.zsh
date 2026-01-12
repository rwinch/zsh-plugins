# Define clone as a function so cd works in the current shell
clone() {
	# Check if git-url is available
	if ! command -v git-url &> /dev/null; then
		cat >&2 <<EOF
Error: git-url command not found

The git-clone-convention plugin requires the git-url plugin to be installed.

To install using Antigen, add this to your .antigenrc BEFORE loading git-clone-convention:

    antigen bundle rwinch/zsh-plugins --loc=git-url

For more information, see:
    https://github.com/rwinch/zsh-plugins/tree/main/git-url
    https://github.com/rwinch/zsh-plugins/tree/main/git-clone-convention

EOF
		return 1
	fi

	# Function to extract owner and repository from a git URL
	_clone_extract_owner_and_repo() {
		local url="$1"
		local owner=""
		local repo=""
		local path=""

		# Handle SSH format: git@host:owner/repo.git
		if [[ "$url" == git@*:*.git ]]; then
			# Remove git@host: prefix
			path="${url#git@*:}"
			# Remove .git suffix
			path="${path%.git}"
			# Split on /
			owner="${path%%/*}"
			repo="${path#*/}"
		# Handle HTTPS format: https://host/owner/repo.git
		elif [[ "$url" == http*://*.git ]]; then
			# Remove https://host/ or http://host/ prefix
			path="${url#http*://}"
			path="${path#*/}"
			# Remove .git suffix
			path="${path%.git}"
			# Split on /
			owner="${path%%/*}"
			repo="${path#*/}"
		fi

		# Output owner and repo on separate lines
		printf "%s\n%s\n" "$owner" "$repo"
	}

	# Separate git-url arguments from git clone arguments
	local git_url_args=()
	local git_clone_args=()
	local skip_next=false

	for arg in "$@"; do
		if [[ "$skip_next" == true ]]; then
			git_url_args+=("$arg")
			skip_next=false
			continue
		fi

		case "$arg" in
			--https|--gitlab|--help)
				git_url_args+=("$arg")
				;;
			--host|--owner|--repository)
				git_url_args+=("$arg")
				skip_next=true
				;;
			-*)
				# All other flags go to git clone
				git_clone_args+=("$arg")
				;;
			*)
				# Check if it looks like an owner/repo slug or URL (for git-url)
				if [[ "$arg" =~ ^[^/]+/[^/]+$ ]] || [[ "$arg" =~ ^git@.+:.+\.git$ ]] || [[ "$arg" =~ ^https?://.+\.git$ ]]; then
					git_url_args+=("$arg")
				else
					# Otherwise it's for git clone (e.g., directory name)
					git_clone_args+=("$arg")
				fi
				;;
		esac
	done

	# Handle --help specially
	if [[ " ${git_url_args[@]} " =~ " --help " ]]; then
		cat <<EOF
Usage: clone [GIT-URL-OPTIONS] [GIT-CLONE-OPTIONS]

A wrapper around git clone that integrates with git-url and follows directory conventions.

GIT-URL OPTIONS (passed to git-url to generate repository URL):
  --https              Use HTTPS URL format instead of SSH (default: SSH)
  --host HOST          Specify the Git host domain (default: github.com)
  --gitlab             Shortcut for --host gitlab.com
  --owner OWNER        Override the repository owner
  --repository REPO    Override the repository name
  OWNER/REPOSITORY     GitHub slug in the format owner/repository
  URL                  Full SSH or HTTPS URL

GIT-CLONE OPTIONS (passed to git clone):
  Any other options are passed directly to git clone (e.g., --branch, --depth, etc.)

BEHAVIOR:
  - Checks if ~/code/OWNER/REPOSITORY already exists before cloning
  - If exists, changes directory to ~/code/OWNER/REPOSITORY/BRANCH (main, master, or root)
  - Clones into ~/code/OWNER/REPOSITORY/main initially
  - Renames directory to actual default branch if different from 'main'
  - Sets remote name to OWNER instead of 'origin'
  - Changes directory to ~/code/OWNER/REPOSITORY/BRANCH after cloning
  - If wd command exists, creates shortcuts for spring-prefixed owners/repos:
    * Owner starting with 'spring-' creates shortcut with prefix removed
      (e.g., spring-projects → 'wd projects' points to ~/code/spring-projects)
    * Repo starting with 'spring-' creates shortcut with prefix removed
      (e.g., spring-security → 'wd security' points to the cloned directory)

EXAMPLES:
  clone spring-projects/spring-security
  clone --https spring-projects/spring-security
  clone --gitlab mygroup/myproject
  clone spring-projects/spring-security --depth 1
  clone --branch 5.8.x spring-projects/spring-security

EOF
		return 0
	fi

	# Get the URL from git-url
	local url=$(git-url "${git_url_args[@]}")
	local exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		echo "Error: Failed to generate URL from git-url" >&2
		return $exit_code
	fi

	# Extract owner and repository from the URL
	local result=$(_clone_extract_owner_and_repo "$url")
	local lines=("${(@f)result}")
	local owner="${lines[1]}"
	local repo="${lines[2]}"

	if [[ -z "$owner" || -z "$repo" ]]; then
		echo "Error: Could not extract owner and repository from URL: $url" >&2
		return 1
	fi

	# Check if the repository already exists
	local base_dir="$HOME/code/$owner/$repo"

	if [[ -d "$base_dir" ]]; then
		echo "Repository already exists at $base_dir"
		
		# Try to change to main, master, or base directory
		if [[ -d "$base_dir/main" ]]; then
			echo "Changing directory to $base_dir/main"
			cd "$base_dir/main" || return 1
		elif [[ -d "$base_dir/master" ]]; then
			echo "Changing directory to $base_dir/master"
			cd "$base_dir/master" || return 1
		else
			echo "Changing directory to $base_dir"
			cd "$base_dir" || return 1
		fi
		
		return 0
	fi

	# Create parent directory structure
	local owner_dir="$HOME/code/$owner"
	local created_owner_dir=false
	
	if [[ ! -d "$owner_dir" ]]; then
		mkdir -p "$owner_dir"
		created_owner_dir=true
	fi

	# Clone into main directory initially
	local clone_dir="$base_dir/main"
	echo "Cloning $url into $clone_dir with remote name '$owner'"

	# Clone with owner as remote name
	command git clone --origin "$owner" "${git_clone_args[@]}" "$url" "$clone_dir"
	local clone_exit=$?

	if [[ $clone_exit -ne 0 ]]; then
		echo "Error: git clone failed" >&2
		
		# Clean up owner directory if we created it
		if [[ "$created_owner_dir" == true ]]; then
			echo "Removing owner directory: $owner_dir" >&2
			rmdir "$owner_dir" 2>/dev/null
		fi
		
		return $clone_exit
	fi

	# Determine the actual default branch
	cd "$clone_dir" || return 1
	local actual_branch=$(git symbolic-ref refs/remotes/$owner/HEAD 2>/dev/null | sed "s@^refs/remotes/$owner/@@")

	if [[ -z "$actual_branch" ]]; then
		# Fallback: try to get the current branch
		actual_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
	fi

	if [[ -z "$actual_branch" ]]; then
		echo "Warning: Could not determine default branch, assuming 'main'"
		actual_branch="main"
	fi

	# Rename directory if the actual branch is different from 'main'
	if [[ "$actual_branch" != "main" ]]; then
		local new_dir="$base_dir/$actual_branch"
		echo "Renaming directory to match default branch: $actual_branch"
		cd "$HOME/code/$owner" || return 1
		mv "main" "$actual_branch"
		cd "$new_dir" || return 1
		echo "Changed directory to $new_dir"
	else
		echo "Changed directory to $clone_dir"
	fi

	# Add wd shortcuts if wd command exists
	if command -v wd &> /dev/null; then
		# Add shortcut for owner if it starts with spring-
		if [[ "$owner" == spring-* ]]; then
			local owner_shortcut="${owner#spring-}"
			echo "Adding wd shortcut: $owner_shortcut -> $owner_dir"
			wd add "$owner_shortcut" "$owner_dir" &> /dev/null
		fi

		# Add shortcut for repo if it starts with spring-
		if [[ "$repo" == spring-* ]]; then
			local repo_shortcut="${repo#spring-}"
			local current_dir=$(pwd)
			echo "Adding wd shortcut: $repo_shortcut -> $current_dir"
			wd add "$repo_shortcut" "$current_dir" &> /dev/null
		fi
	fi

	return 0
}

