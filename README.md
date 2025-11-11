# Git Worktree Manager (gw)

A shell tool for managing git worktrees in a flat directory structure with automatic configuration and setup.

## Installation

1. Copy `gw.zsh` to `~/.local/bin/gw` (or another location in your PATH)
2. Make it executable: `chmod +x ~/.local/bin/gw`
3. Source `gw_shell_fn.zsh` in your shell config (`.zshrc` or `.bashrc`)

## Usage

```bash
gw <branch>         # Switch to worktree for <branch>, create if doesn't exist
gw -b <branch>      # Create new branch and worktree
gw -d [branch]      # Delete worktree (exact match required)
gw -c               # Clean up worktrees that are up to date with tracking branches
gw --list           # List all worktrees
gw --help           # Show help
```

## Directory Structure

Branch names with `/` are converted to `__` in directory names:
- `feature/api-update` → `feature__api-update/`
- `main` → `main/`
- `user/branch` → `user__branch/`

## Configuration

Create a `.gwconfig` file in your **main worktree** to automatically manage files and run scripts when creating or deleting worktrees.

### Format

Both YAML-like and JSON formats are supported:

**YAML format:**
```yaml
link_files: [".env.local", ".env.production.local", "config/local.yaml"]
scripts: ["npm install", "make setup"]
delete_scripts: ["git stash", "cleanup.sh"]
```

**JSON format:**
```json
{
  "link_files": [".env.local", ".env.production.local", "config/local.yaml"],
  "scripts": ["npm install", "make setup"],
  "delete_scripts": ["git stash", "cleanup.sh"]
}
```

### Configuration Options

#### `link_files`
Array of file paths to symlink from the main worktree to new worktrees.

- **When it runs:** When creating a new worktree (`gw -b` or `gw <branch>`)
- **Purpose:** Share configuration files across all worktrees
- **Behavior:** Creates relative symlinks (`../main/filename`) pointing to the main worktree
- **Use cases:**
  - Environment files (`.env.local`)
  - Local config files (`config/local.yaml`)
  - IDE settings (`.vscode/settings.json`)

#### `scripts`
Array of shell commands to run after creating a new worktree.

- **When it runs:** After creating a new worktree and setting up symlinks
- **Working directory:** Inside the new worktree
- **Purpose:** Automatically set up dependencies and build artifacts
- **Behavior:** Runs sequentially; failures are reported but don't block worktree creation
- **Use cases:**
  - Install dependencies (`npm install`, `bundle install`)
  - Build assets (`make setup`, `npm run build`)
  - Database setup (`rake db:migrate`)

#### `delete_scripts`
Array of shell commands to run before deleting a worktree.

- **When it runs:** Before deleting a worktree (`gw -d` or `gw -c`)
- **Working directory:** Inside the worktree being deleted
- **Purpose:** Save work and cleanup resources before deletion
- **Behavior:** Runs sequentially; **if any script fails, deletion is aborted**
- **Use cases:**
  - Save uncommitted work (`git stash`)
  - Stop running services (`docker-compose down`)
  - Custom cleanup scripts (`./cleanup.sh`)

## Examples

### Switching Worktrees
```bash
gw main                    # Switch to main worktree
gw feature/new-api        # Switch to or create feature__new-api/ worktree
```

### Creating New Branches
```bash
gw -b zgotsch/experimental  # Create new branch and zgotsch__experimental/ worktree
```

### Deleting Worktrees
```bash
gw -d feature/old-api      # Delete feature__old-api/ worktree (runs delete_scripts first)
gw -d                      # Delete current worktree (switches to main first)
```

### Cleaning Up Merged Branches
```bash
gw -c  # Automatically delete worktrees that are up-to-date with their tracking branch
```

## Safety Features

- **Exact match required for deletion:** Prevents accidental deletion
- **Cannot delete main worktree:** Protected by default
- **Delete scripts as guardrails:** Failed delete_scripts abort deletion
- **Untracked files protection:** Git refuses to remove worktrees with untracked files

## Example Workflow

1. Create `.gwconfig` in your main worktree:
```yaml
link_files: [".env.local", "node_modules"]
scripts: ["npm install"]
delete_scripts: ["git stash"]
```

2. Create a feature branch:
```bash
gw -b feature/new-widget
# Automatically:
# - Creates worktree at feature__new-widget/
# - Symlinks .env.local and node_modules from main
# - Runs npm install
```

3. Work on the feature, then merge and clean up:
```bash
git push origin feature/new-widget
# After PR is merged...
gw -c
# Automatically:
# - Runs git stash to save any uncommitted work
# - Removes merged worktrees
```
