# Git Worktree Manager function
gw() {
    # Handle list and help commands directly
    case "${1:-}" in
        --list|-l|--help|-h)
            ~/.local/bin/gw "$@"
            return $?
            ;;
    esac
    
    # For branch switching/deleting, capture the output
    local result
    result=$(~/.local/bin/gw "$@")
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        # Check for special deletion case
        if [[ "$result" == *"DELETE_AFTER_CD:"* ]]; then
            # Extract the paths - first line is main worktree, second line has deletion info
            local main_worktree
            local to_delete
            main_worktree=$(echo "$result" | head -n1)
            to_delete=$(echo "$result" | grep "DELETE_AFTER_CD:" | cut -d: -f2)
            
            if [[ -d "$main_worktree" && -n "$to_delete" ]]; then
                echo "Switching to: $main_worktree" >&2
                cd "$main_worktree"
                echo "Deleting worktree at $to_delete" >&2
                git worktree remove "$to_delete"
                if [[ $? -eq 0 ]]; then
                    echo "Successfully deleted worktree" >&2
                else
                    echo "Error: Failed to delete worktree" >&2
                fi
            fi
        elif [[ "$result" == *"CLEAN_WORKTREES:"* ]]; then
            # Handle clean worktrees command
            local main_worktree=""
            local worktrees_to_delete=""
            
            # Check if we need to cd to main first (multi-line output)
            if [[ $(echo "$result" | wc -l) -gt 1 ]]; then
                main_worktree=$(echo "$result" | head -n1)
                worktrees_to_delete=$(echo "$result" | grep "CLEAN_WORKTREES:" | cut -d: -f2-)
                
                if [[ -d "$main_worktree" ]]; then
                    echo "Switching to: $main_worktree" >&2
                    cd "$main_worktree"
                fi
            else
                # Single line output, just get the worktrees to delete
                worktrees_to_delete=$(echo "$result" | cut -d: -f2-)
            fi
            
            # Delete the worktrees
            if [[ -n "$worktrees_to_delete" ]]; then
                local deleted_count=0
                local failed_count=0
                
                # Split the worktrees string by ':'
                local -a WORKTREES
                WORKTREES=(${(s.:.)worktrees_to_delete})
                for worktree_path in "${WORKTREES[@]}"; do
                    if [[ -n "$worktree_path" ]]; then
                        local branch_name
                        branch_name=$(basename "$worktree_path" | sed 's|__|/|g')
                        echo "Deleting worktree: $branch_name" >&2
                        
                        if git worktree remove "$worktree_path" 2>/dev/null; then
                            ((deleted_count++))
                        else
                            echo "Warning: Failed to delete $branch_name (may have untracked files)" >&2
                            ((failed_count++))
                        fi
                    fi
                done
                
                echo "Clean complete: $deleted_count deleted, $failed_count failed" >&2
            else
                echo "No worktrees to clean" >&2
            fi
        elif [[ -d "$result" ]]; then
            # Normal directory switching
            echo "Switching to: $result" >&2
            cd "$result"
        else
            # Command succeeded but didn't return a directory (like successful deletion)
            echo "$result"
        fi
    else
        # Script failed - show any output
        if [[ -n "$result" ]]; then
            echo "$result"
        fi
        return $exit_code
    fi
}

# Tab completion for gw function
_gw_completion() {
    local current_word="${COMP_WORDS[COMP_CWORD]}"
    local prev_word="${COMP_WORDS[COMP_CWORD-1]}"
    
    # Complete branch names
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        # Get local and remote branch names
        local branches
        branches=$(git branch -a | sed 's/^[ \t*]*//' | sed 's/^remotes\/origin\///' | grep -v '^HEAD' | sort -u)
        COMPREPLY=($(compgen -W "$branches" -- "$current_word"))
    fi
}

# Enable completion for gw (bash-style, works in zsh with bashcompinit)
if command -v complete >/dev/null; then
    complete -F _gw_completion gw
fi