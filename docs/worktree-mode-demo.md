# Worktree Mode Demo

Step-by-step guide to showcase worktree isolation, merge conflict detection, auto-merge, and conflict resolution in a fresh repo.

## 1. Configure git

```bash
git config --global user.name "Demo"
git config --global user.email "demo@test.com"
```

## 2. Install codex-yolo

```bash
git clone https://github.com/codex-yolo/codex-yolo.git /tmp/codex-yolo-src
bash /tmp/codex-yolo-src/install.sh --local
source ~/.bashrc
```

This installs dependencies, copies codex-yolo to `~/.codex-yolo`, and symlinks the binary into `~/.local/bin`.

## 3. Create a demo repo

The key to seeing conflicts: multiple agents must edit the same lines in the same file.

```bash
mkdir -p /tmp/demo-project && cd /tmp/demo-project
git init -b main
cat > app.py << 'EOF'
def hello():
    return "Hello, World!"

def add(a, b):
    return a + b

def multiply(a, b):
    return a * b

if __name__ == "__main__":
    print(hello())
    print(add(2, 3))
    print(multiply(4, 5))
EOF
git add -A && git commit -m "initial commit"
```

## 4. Launch worktree mode

```bash
codex-yolo --worktree -s demo -d /tmp/demo-project \
  "Rewrite app.py: rename hello to greet, add to sum_numbers, multiply to product. Add docstrings to every function. Update the main block to use the new names and print descriptive labels." \
  "Rewrite app.py: add type hints to all function signatures, add input validation for numeric args in add and multiply, add subtract(a, b), and update the main block to call subtract." \
  "Rewrite app.py: add divide(a, b) with ZeroDivisionError handling, add power(a, b), and rewrite the main block to demo all functions."
```

Worktree mode runs agents with `codex exec` so each task exits cleanly when finished. The merge window then auto-commits any uncommitted changes before merging.

## What you'll see in tmux

| Window | What's happening |
|--------|-----------------|
| `agent-1` | Codex running in worktree `demo-1` |
| `agent-2` | Codex running in worktree `demo-2` |
| `agent-3` | Codex running in worktree `demo-3` |
| `merge` | Waiting for agents, then auto-merging and resolving conflicts |
| `control` | Live audit log with approvals and conflict detection |

## Manual merge workflow

Use `--no-merge` to skip auto-merge and inspect worktrees before merging yourself:

```bash
codex-yolo -w --no-merge -s manual -d /tmp/demo-project \
  "task one" "task two" "task three"
```

After agents finish:

```bash
cd /tmp/demo-project
git diff main..manual-1
git diff main..manual-2
git merge-tree --write-tree manual-1 manual-2

git checkout main
git merge manual-1
git merge manual-2
git merge manual-3

source ~/.codex-yolo/lib/worktree-manager.sh
wt_cleanup manual
```

Use `--no-cleanup` with auto-merge to keep worktrees for inspection:

```bash
codex-yolo -w --no-cleanup -s keep -d /tmp/demo-project "task one" "task two"
ls /tmp/demo-project-worktrees/keep/
source ~/.codex-yolo/lib/worktree-manager.sh
wt_cleanup keep
```
