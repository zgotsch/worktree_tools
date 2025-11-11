#!/bin/bash

set -euo pipefail

# Git Worktree Manager
# Usage: gw [options] <branch-name>
# 
# This script manages git worktrees in a flat structure, replacing '/' with '__' in directory names

show_help() {
    cat << EOF
Git Worktree Manager (gw)

Usage: gw [options] <branch-name>

Commands:
    gw <branch>         Switch to worktree for <branch>, create if doesn't exist
    gw -b <branch>      Create new branch and worktree
    gw -d [branch]      Delete worktree (exact match required)
    gw -c               Clean up worktrees that are up to date with tracking branches
    gw --list          List all worktrees
    gw --help          Show this help

Examples:
    gw main                           # Switch to main worktree
    gw feature/new-api                # Switch to or create feature__new-api/ worktree
    gw -b zgotsch/experimental        # Create new branch and zgotsch__experimental/ worktree
    gw -d feature/old-api            # Delete feature__old-api/ worktree
    gw -d                            # Delete current worktree (switches to main first)
    gw -c                            # Clean up finished feature branches

Directory Structure:
    Branch names with '/' are converted to '__' in directory names:
    - feature/api-update  →  feature__api-update/
    - main               →  main/
    - user/branch        →  user__branch/

Configuration:
    Create a .gwconfig file in the main worktree to automatically symlink files
    and run setup scripts:

    link_files: [".env.local", ".env.production.local", "config/local.yaml"]
    scripts: ["npm install", "make setup"]

    or JSON format:

    {"link_files": [".env.local", ".env.production.local", "config/local.yaml"], "scripts": ["npm install", "make setup"]}
EOF
}

# Convert branch name to directory name (replace / with __)
branch_to_dir() {
    echo "$1" | sed 's|/|__|g'
}

# Convert directory name to branch name (replace __ with /)
dir_to_branch() {
    echo "$1" | sed 's|__|/|g'
}

# Find the worktree root directory (parent of all worktrees)
find_worktree_root() {
    local current_dir="$PWD"
    
    # First, check if we're already in a worktree
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        # Get the top-level directory of the current worktree
        local git_top_level
        git_top_level=$(git rev-parse --show-toplevel)
        
        # The worktree root is the parent of the git top-level
        echo "$(dirname "$git_top_level")"
        return 0
    fi
    
    # If not in a git repo, look for a directory structure that looks like worktrees
    # Check current directory and parents for multiple git worktrees
    while [[ "$current_dir" != "/" ]]; do
        local git_dirs
        git_dirs=$(find "$current_dir" -maxdepth 2 -name ".git" -type f 2>/dev/null | wc -l)
        if [[ $git_dirs -gt 1 ]]; then
            echo "$current_dir"
            return 0
        fi
        current_dir=$(dirname "$current_dir")
    done
    
    echo "Error: Could not find worktree root directory" >&2
    return 1
}

# Get relative path from current directory to target
get_relative_path() {
    local target="$1"
    local current="$PWD"
    
    # If target is the current directory
    if [[ "$target" == "$current" ]]; then
        echo "."
        return
    fi
    
    # If target is a subdirectory of current
    if [[ "$target" == "$current"/* ]]; then
        echo "${target#$current/}"
        return
    fi
    
    # If current is a subdirectory of target
    if [[ "$current" == "$target"/* ]]; then
        local rel_path=""
        local temp_current="$current"
        while [[ "$temp_current" != "$target" ]]; do
            rel_path="../$rel_path"
            temp_current=$(dirname "$temp_current")
        done
        echo "${rel_path%/}"
        return
    fi
    
    # Find common ancestor and build relative path
    local common_prefix="$current"
    while [[ "$target" != "$common_prefix"* ]]; do
        common_prefix=$(dirname "$common_prefix")
    done
    
    # Count how many levels up we need to go
    local up_levels=""
    local temp_current="$current"
    while [[ "$temp_current" != "$common_prefix" ]]; do
        up_levels="../$up_levels"
        temp_current=$(dirname "$temp_current")
    done
    
    # Add the path from common ancestor to target
    local down_path="${target#$common_prefix/}"
    if [[ -n "$up_levels" && -n "$down_path" ]]; then
        echo "${up_levels}${down_path}"
    elif [[ -n "$up_levels" ]]; then
        echo "${up_levels%/}"
    elif [[ -n "$down_path" ]]; then
        echo "$down_path"
    else
        echo "."
    fi
}

# Get current worktree path
get_current_worktree() {
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        git rev-parse --show-toplevel
    else
        echo ""
    fi
}

# List all worktrees with their branch names
list_worktrees() {
    local worktree_root
    worktree_root=$(find_worktree_root)
    
    local current_worktree
    current_worktree=$(get_current_worktree)
    
    # Colors
    local branch_color='\033[0;32m'    # Green for branch names
    local path_color='\033[0;36m'      # Cyan for paths
    local current_color='\033[0;33m'   # Yellow for current worktree
    local reset_color='\033[0m'        # Reset
    
    # Arrays to store worktree info
    local -a worktree_data=()
    local -a current_worktree_data=()
    
    # Use git worktree list if we're in a git repo
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        while IFS= read -r line; do
            # Parse git worktree list output: path commit [branch]
            local path commit branch
            read -r path commit branch <<< "$line"
            
            # Remove any brackets around branch name
            branch=${branch#[}
            branch=${branch%]}
            
            local dir_name
            dir_name=$(basename "$path")
            local branch_name
            branch_name=$(dir_to_branch "$dir_name")
            
            # If branch is empty (detached HEAD), use the directory name
            if [[ -z "$branch" || "$branch" == *"detached"* ]]; then
                branch_name="$dir_name"
            fi
            
            local relative_path
            relative_path=$(get_relative_path "$path")
            
            # Check if this is the current worktree
            if [[ "$path" == "$current_worktree" ]]; then
                current_worktree_data=("$branch_name" "$relative_path")
            else
                worktree_data+=("$branch_name|$relative_path")
            fi
        done < <(git worktree list)
    else
        # Fallback: look for directories that look like worktrees
        for dir in "$worktree_root"/*; do
            if [[ -d "$dir" && -f "$dir/.git" ]]; then
                local dir_name
                dir_name=$(basename "$dir")
                local branch_name
                branch_name=$(dir_to_branch "$dir_name")
                local relative_path
                relative_path=$(get_relative_path "$dir")
                
                if [[ "$dir" == "$current_worktree" ]]; then
                    current_worktree_data=("$branch_name" "$relative_path")
                else
                    worktree_data+=("$branch_name|$relative_path")
                fi
            fi
        done
    fi
    
    # Print current worktree first (if any)
    if [[ ${#current_worktree_data[@]} -gt 0 ]]; then
        printf "* ${current_color}%-30s${reset_color} ${path_color}%s${reset_color}\n" \
            "${current_worktree_data[0]}" "${current_worktree_data[1]}"
    fi
    
    # Print other worktrees
    if [[ ${#worktree_data[@]} -gt 0 ]]; then
        for entry in "${worktree_data[@]}"; do
            local branch_name="${entry%|*}"
            local relative_path="${entry#*|}"
            printf "  ${branch_color}%-30s${reset_color} ${path_color}%s${reset_color}\n" \
                "$branch_name" "$relative_path"
        done
    fi
}

# Get list of existing worktree branch names (sorted by most recent first)
get_existing_worktrees() {
    local -a worktree_names=()
    
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        # Use git worktree list and sort by commit date (most recent first)
        while IFS= read -r line; do
            local path commit branch
            read -r path commit branch <<< "$line"
            
            # Remove brackets around branch name
            branch=${branch#[}
            branch=${branch%]}
            
            local dir_name
            dir_name=$(basename "$path")
            local branch_name
            branch_name=$(dir_to_branch "$dir_name")
            
            # If branch is empty (detached HEAD), use the directory name
            if [[ -z "$branch" || "$branch" == *"detached"* ]]; then
                branch_name="$dir_name"
            fi
            
            echo "$branch_name"
        done < <(git worktree list)
    fi
}

# Get list of existing branch names (local and remote)
get_existing_branches() {
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        # Get all branch names (local and remote, without remotes/origin/ prefix)
        git branch -a | sed 's/^[ \t*]*//' | sed 's/^remotes\/origin\///' | grep -v '^HEAD' | sort -u
    fi
}

# Find best match for a given input
find_worktree_match() {
    local input="$1"
    
    # 1. Check for exact worktree match
    while IFS= read -r worktree; do
        if [[ "$worktree" == "$input" ]]; then
            echo "exact_worktree:$worktree"
            return 0
        fi
    done < <(get_existing_worktrees)
    
    # 2. Check for exact branch match
    while IFS= read -r branch; do
        if [[ "$branch" == "$input" ]]; then
            echo "exact_branch:$branch"
            return 0
        fi
    done < <(get_existing_branches)
    
    # 3. Check for substring match in worktrees (most recent first)
    while IFS= read -r worktree; do
        if [[ "$worktree" == *"$input"* ]]; then
            echo "substring_worktree:$worktree"
            return 0
        fi
    done < <(get_existing_worktrees)
    
    # No match found
    echo "no_match:"
    return 1
}

# Create or switch to a worktree
switch_or_create_worktree() {
    local input="$1"
    local create_new_branch="${2:-false}"
    
    local worktree_root
    worktree_root=$(find_worktree_root)
    
    # Need to be in a git repo for any operations
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Error: Not in a git repository. Cannot create worktree." >&2
        return 1
    fi
    
    # If -b flag was used, create new branch without any matching logic
    if [[ "$create_new_branch" == "true" ]]; then
        local dir_name
        dir_name=$(branch_to_dir "$input")
        local worktree_path="$worktree_root/$dir_name"
        
        # Check if worktree already exists
        if [[ -d "$worktree_path" ]]; then
            echo "$worktree_path"
            return 0
        fi
        
        echo "Creating new branch '$input' and worktree at $worktree_path" >&2
        git worktree add -b "$input" "$worktree_path" >&2

        # Create symlinks for configured files
        create_config_links "$worktree_path" "$worktree_root"

        # Run configured scripts
        run_config_scripts "$worktree_path" "$worktree_root"

        echo "$worktree_path"
        return 0
    fi
    
    # Use enhanced matching logic
    local match_result
    match_result=$(find_worktree_match "$input" || true)
    local match_type="${match_result%:*}"
    local match_value="${match_result#*:}"
    
    case "$match_type" in
        "exact_worktree")
            # Switch to existing worktree
            local dir_name
            dir_name=$(branch_to_dir "$match_value")
            local worktree_path="$worktree_root/$dir_name"
            echo "$worktree_path"
            return 0
            ;;
        "exact_branch")
            # Create worktree for existing branch
            local dir_name
            dir_name=$(branch_to_dir "$match_value")
            local worktree_path="$worktree_root/$dir_name"
            
            # Check if worktree already exists
            if [[ -d "$worktree_path" ]]; then
                echo "$worktree_path"
                return 0
            fi
            
            # Create the worktree for the existing branch
            if git show-ref --verify --quiet "refs/heads/$match_value"; then
                echo "Creating worktree for existing local branch '$match_value' at $worktree_path" >&2
                git worktree add "$worktree_path" "$match_value" >&2
            elif git show-ref --verify --quiet "refs/remotes/origin/$match_value"; then
                echo "Creating worktree for remote branch 'origin/$match_value' at $worktree_path" >&2
                git worktree add "$worktree_path" "$match_value" >&2
            else
                echo "Error: Branch '$match_value' not found" >&2
                return 1
            fi

            # Create symlinks for configured files
            create_config_links "$worktree_path" "$worktree_root"

            # Run configured scripts
            run_config_scripts "$worktree_path" "$worktree_root"

            echo "$worktree_path"
            return 0
            ;;
        "substring_worktree")
            # Switch to worktree that matches substring
            local dir_name
            dir_name=$(branch_to_dir "$match_value")
            local worktree_path="$worktree_root/$dir_name"
            echo "$worktree_path"
            return 0
            ;;
        "no_match")
            # No match found
            echo "Error: No matching worktree found for '$input'." >&2
            echo "To create a worktree, you need an exact match to an existing branch name," >&2
            echo "or use 'gw -b $input' to create a new branch." >&2
            return 1
            ;;
    esac
}

# Read .gwconfig file and extract link_files
get_link_files() {
    local worktree_root="$1"
    local config_file="$worktree_root/main/.gwconfig"

    # Check if config file exists
    if [[ ! -f "$config_file" ]]; then
        return 0  # No config file, no files to link
    fi

    # Parse the simple YAML/JSON format to extract link_files
    # Expected format: link_files: [".env.local", ".env.production.local"]
    # or JSON format: {"link_files": [".env.local", ".env.production.local"]}

    local files
    if grep -q "link_files:" "$config_file"; then
        # YAML format
        files=$(grep "link_files:" "$config_file" | sed 's/.*link_files: *\[\(.*\)\].*/\1/' | tr -d '"' | tr ',' '\n' | sed 's/^ *//;s/ *$//')
    elif grep -q '"link_files"' "$config_file"; then
        # JSON format
        files=$(grep '"link_files"' "$config_file" | sed 's/.*"link_files": *\[\(.*\)\].*/\1/' | tr -d '"' | tr ',' '\n' | sed 's/^ *//;s/ *$//')
    fi

    # Output each file on a separate line, removing any quotes and whitespace
    if [[ -n "$files" ]]; then
        echo "$files" | while read -r file; do
            if [[ -n "$file" ]]; then
                echo "$file"
            fi
        done
    fi
}

# Read .gwconfig file and extract scripts
get_scripts() {
    local worktree_root="$1"
    local config_file="$worktree_root/main/.gwconfig"

    # Check if config file exists
    if [[ ! -f "$config_file" ]]; then
        return 0  # No config file, no scripts to run
    fi

    # Parse the simple YAML/JSON format to extract scripts
    # Expected format: scripts: ["npm install", "make setup"]
    # or JSON format: {"scripts": ["npm install", "make setup"]}

    local scripts
    if grep -q "scripts:" "$config_file"; then
        # YAML format
        scripts=$(grep "scripts:" "$config_file" | sed 's/.*scripts: *\[\(.*\)\].*/\1/' | tr -d '"' | sed 's/, */\n/g' | sed 's/^ *//;s/ *$//')
    elif grep -q '"scripts"' "$config_file"; then
        # JSON format
        scripts=$(grep '"scripts"' "$config_file" | sed 's/.*"scripts": *\[\(.*\)\].*/\1/' | tr -d '"' | sed 's/, */\n/g' | sed 's/^ *//;s/ *$//')
    fi

    # Output each script on a separate line, removing any quotes and whitespace
    if [[ -n "$scripts" ]]; then
        echo "$scripts" | while read -r script; do
            if [[ -n "$script" ]]; then
                echo "$script"
            fi
        done
    fi
}

# Get delete scripts from config
get_delete_scripts() {
    local worktree_root="$1"
    local config_file="$worktree_root/main/.gwconfig"

    # Check if config file exists
    if [[ ! -f "$config_file" ]]; then
        return 0  # No config file, no scripts to run
    fi

    # Parse the simple YAML/JSON format to extract delete_scripts
    # Expected format: delete_scripts: ["git stash", "cleanup.sh"]
    # or JSON format: {"delete_scripts": ["git stash", "cleanup.sh"]}

    local scripts
    if grep -q "delete_scripts:" "$config_file"; then
        # YAML format
        scripts=$(grep "delete_scripts:" "$config_file" | sed 's/.*delete_scripts: *\[\(.*\)\].*/\1/' | tr -d '"' | sed 's/, */\n/g' | sed 's/^ *//;s/ *$//')
    elif grep -q '"delete_scripts"' "$config_file"; then
        # JSON format
        scripts=$(grep '"delete_scripts"' "$config_file" | sed 's/.*"delete_scripts": *\[\(.*\)\].*/\1/' | tr -d '"' | sed 's/, */\n/g' | sed 's/^ *//;s/ *$//')
    fi

    # Output each script on a separate line, removing any quotes and whitespace
    if [[ -n "$scripts" ]]; then
        echo "$scripts" | while read -r script; do
            if [[ -n "$script" ]]; then
                echo "$script"
            fi
        done
    fi
}

# Create symlinks for configured files in a new worktree
create_config_links() {
    local worktree_path="$1"
    local worktree_root="$2"

    # Get files to link from config
    local -a link_files=()
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            link_files+=("$file")
        fi
    done < <(get_link_files "$worktree_root")

    # If no files to link, return
    if [[ ${#link_files[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Creating symlinks for configured files..." >&2

    # Create symlinks for each configured file
    for file in "${link_files[@]}"; do
        local source_file="$worktree_root/main/$file"
        local target_file="$worktree_path/$file"

        # Check if source file exists in main worktree
        if [[ -f "$source_file" || -d "$source_file" ]]; then
            # Create directory structure if needed
            local target_dir
            target_dir=$(dirname "$target_file")
            if [[ "$target_dir" != "." && ! -d "$target_dir" ]]; then
                mkdir -p "$target_dir"
            fi

            # Create relative symlink from target directory to source file
            # Since worktrees are siblings, the path is usually ../main/filename
            local relative_source="../main/$file"

            # Create the symlink
            if ln -sf "$relative_source" "$target_file" 2>/dev/null; then
                echo "  Linked: $file" >&2
            else
                echo "  Warning: Failed to link $file" >&2
            fi
        else
            echo "  Warning: Source file $file not found in main worktree" >&2
        fi
    done
}

# Run configured scripts in a new worktree
run_config_scripts() {
    local worktree_path="$1"
    local worktree_root="$2"

    # Get scripts to run from config
    local -a scripts=()
    while IFS= read -r script; do
        if [[ -n "$script" ]]; then
            scripts+=("$script")
        fi
    done < <(get_scripts "$worktree_root")

    # If no scripts to run, return
    if [[ ${#scripts[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Running configured scripts..." >&2

    # Run each script in the worktree directory
    for script in "${scripts[@]}"; do
        echo "  Running: $script" >&2
        (cd "$worktree_path" && eval "$script" >&2)
        if [[ $? -eq 0 ]]; then
            echo "  ✓ Completed: $script" >&2
        else
            echo "  ✗ Failed: $script" >&2
        fi
    done
}

# Run configured delete scripts before removing a worktree
# Returns 0 if all scripts succeed, 1 if any script fails
run_delete_scripts() {
    local worktree_path="$1"
    local worktree_root="$2"

    # Get scripts to run from config
    local -a scripts=()
    while IFS= read -r script; do
        if [[ -n "$script" ]]; then
            scripts+=("$script")
        fi
    done < <(get_delete_scripts "$worktree_root")

    # If no scripts to run, return success
    if [[ ${#scripts[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Running pre-delete scripts..." >&2

    # Run each script in the worktree directory
    # Stop on first failure
    for script in "${scripts[@]}"; do
        echo "  Running: $script" >&2
        (cd "$worktree_path" && eval "$script" >&2)
        local exit_status=$?
        if [[ $exit_status -eq 0 ]]; then
            echo "  ✓ Completed: $script" >&2
        else
            echo "  ✗ Failed: $script (exit status: $exit_status)" >&2
            echo "Error: Pre-delete script failed. Aborting worktree deletion." >&2
            return 1
        fi
    done

    return 0
}

# Clean up worktrees that are up to date with their tracking branches
clean_worktrees() {
    # Need to be in a git repo
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Error: Not in a git repository. Cannot clean worktrees." >&2
        return 1
    fi
    
    local worktree_root
    worktree_root=$(find_worktree_root)
    
    local current_worktree
    current_worktree=$(get_current_worktree)
    
    echo "Fetching latest from remotes..." >&2
    git fetch >&2
    
    echo "Checking worktrees for cleanup..." >&2
    
    local -a worktrees_to_delete=()
    local current_will_be_deleted=false
    
    # Iterate through all worktrees except main
    while IFS= read -r line; do
        local path commit branch
        read -r path commit branch <<< "$line"
        
        # Remove brackets around branch name
        branch=${branch#[}
        branch=${branch%]}
        
        local dir_name
        dir_name=$(basename "$path")
        local branch_name
        branch_name=$(dir_to_branch "$dir_name")
        
        # Skip main worktree
        if [[ "$branch_name" == "main" ]]; then
            continue
        fi
        
        # Skip if branch is empty (detached HEAD)
        if [[ -z "$branch" || "$branch" == *"detached"* ]]; then
            echo "  Skipping $branch_name (detached HEAD)" >&2
            continue
        fi
        
        # Change to the worktree directory to check its status
        cd "$path" || continue
        
        # Get the tracking branch
        local upstream
        upstream=$(git rev-parse --abbrev-ref HEAD@{upstream} 2>/dev/null)
        
        if [[ -z "$upstream" ]]; then
            echo "  Skipping $branch_name (no tracking branch)" >&2
            continue
        fi
        
        # Check if branch is up to date with its tracking branch
        local behind ahead
        behind=$(git rev-list --count HEAD.."$upstream" 2>/dev/null)
        ahead=$(git rev-list --count "$upstream"..HEAD 2>/dev/null)
        
        if [[ "$behind" -eq 0 && "$ahead" -eq 0 ]]; then
            echo "  Marking $branch_name for deletion (up to date with $upstream)" >&2
            worktrees_to_delete+=("$path")
            
            # Check if this is the current worktree
            if [[ "$path" == "$current_worktree" ]]; then
                current_will_be_deleted=true
            fi
        else
            echo "  Keeping $branch_name ($ahead ahead, $behind behind $upstream)" >&2
        fi
    done < <(git worktree list)
    
    # If no worktrees to delete, we're done
    if [[ ${#worktrees_to_delete[@]} -eq 0 ]]; then
        echo "No worktrees need cleaning." >&2
        return 0
    fi

    # Run pre-delete scripts for each worktree to be deleted
    # Track which worktrees are safe to delete
    local -a worktrees_safe_to_delete=()
    local -a worktrees_failed=()

    for worktree_path in "${worktrees_to_delete[@]}"; do
        if run_delete_scripts "$worktree_path" "$worktree_root"; then
            worktrees_safe_to_delete+=("$worktree_path")
        else
            worktrees_failed+=("$worktree_path")
            echo "Skipping deletion of worktree at $worktree_path due to script failure." >&2
            # Check if this was the current worktree
            if [[ "$worktree_path" == "$current_worktree" ]]; then
                current_will_be_deleted=false
            fi
        fi
    done

    # If all worktrees failed, abort
    if [[ ${#worktrees_safe_to_delete[@]} -eq 0 ]]; then
        echo "No worktrees can be deleted due to script failures." >&2
        return 1
    fi

    # Update the list to only include safe worktrees
    worktrees_to_delete=("${worktrees_safe_to_delete[@]}")

    # If current worktree will be deleted, we need to cd to main first
    if [[ "$current_will_be_deleted" == "true" ]]; then
        local main_worktree="$worktree_root/main"
        if [[ ! -d "$main_worktree" ]]; then
            echo "Error: Main worktree not found at $main_worktree" >&2
            return 1
        fi
        
        # Output main worktree path for shell function to cd to
        echo "$main_worktree"
    fi
    
    # Output the worktrees to delete for the shell function
    local worktrees_string
    worktrees_string=$(IFS=':'; echo "${worktrees_to_delete[*]}")
    echo "CLEAN_WORKTREES:$worktrees_string"
    
    return 0
}

# Delete a worktree
delete_worktree() {
    local branch_name="$1"
    
    # Need to be in a git repo
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Error: Not in a git repository. Cannot delete worktree." >&2
        return 1
    fi
    
    local worktree_root
    worktree_root=$(find_worktree_root)
    
    # If no branch name provided, delete current worktree
    if [[ -z "$branch_name" ]]; then
        local current_worktree
        current_worktree=$(get_current_worktree)
        
        if [[ -z "$current_worktree" ]]; then
            echo "Error: Not in a worktree." >&2
            return 1
        fi
        
        # Extract branch name from current worktree path
        local current_dir
        current_dir=$(basename "$current_worktree")
        branch_name=$(dir_to_branch "$current_dir")
        
        # Don't allow deleting main worktree
        if [[ "$branch_name" == "main" ]]; then
            echo "Error: Cannot delete the main worktree." >&2
            return 1
        fi

        # Run pre-delete scripts if configured
        if ! run_delete_scripts "$current_worktree" "$worktree_root"; then
            echo "Error: Cannot delete worktree due to script failure." >&2
            return 1
        fi

        # Switch to main worktree first
        local main_worktree="$worktree_root/main"
        if [[ ! -d "$main_worktree" ]]; then
            echo "Error: Main worktree not found at $main_worktree" >&2
            return 1
        fi

        # Output just what the shell function needs to parse
        echo "$main_worktree"
        echo "DELETE_AFTER_CD:$current_worktree"
        return 0
    fi
    
    # Don't allow deleting main worktree by name
    if [[ "$branch_name" == "main" ]]; then
        echo "Error: Cannot delete the main worktree." >&2
        return 1
    fi
    
    # Check if worktree exists (exact match only)
    local dir_name
    dir_name=$(branch_to_dir "$branch_name")
    local worktree_path="$worktree_root/$dir_name"
    
    if [[ ! -d "$worktree_path" ]]; then
        echo "Error: Worktree for branch '$branch_name' does not exist at $worktree_path" >&2
        return 1
    fi

    # Run pre-delete scripts if configured
    if ! run_delete_scripts "$worktree_path" "$worktree_root"; then
        echo "Error: Cannot delete worktree due to script failure." >&2
        return 1
    fi

    # Use git worktree remove
    # Note: This will fail if there are untracked files in the worktree, which is the desired
    # safety behavior to prevent accidental data loss. Use --force flag manually if needed.
    echo "Deleting worktree for branch '$branch_name' at $worktree_path" >&2
    git worktree remove "$worktree_path"
    
    if [[ $? -eq 0 ]]; then
        echo "Successfully deleted worktree for branch '$branch_name'" >&2
    else
        echo "Error: Failed to delete worktree" >&2
        return 1
    fi
}

# Parse command line arguments
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            return 0
            ;;
        --list|-l)
            list_worktrees
            return 0
            ;;
        -b)
            if [[ $# -lt 2 ]]; then
                echo "Error: -b requires a branch name" >&2
                return 1
            fi
            switch_or_create_worktree "$2" "true"
            ;;
        -d)
            delete_worktree "${2:-}"
            ;;
        -c)
            clean_worktrees
            ;;
        "")
            list_worktrees
            return 0
            ;;
        *)
            switch_or_create_worktree "$1" "false"
            ;;
    esac
}

main "$@"