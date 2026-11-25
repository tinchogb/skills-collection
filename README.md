# skills-collection

Centralized repository for custom AI agent skills, third-party integrations, and profile definitions, managed via [skillm](https://github.com).

## Structure

- `custom/`: Custom skills developed from scratch.
- `third-party/`: External skills integrated alongside declarative upstream metadata (`upstream.toml` and `.upstream-version`), allowing local customizations while preserving upstream sync capabilities.
- `scripts/`: Automation scripts invoked by the `justfile` (`sync_upstream.py`) to detect upstream drift, generate commit summaries via `pi`, and propagate updates.
- `justfile`: Generic task runner interface for checking, upgrading, and syncing third-party skills.
- `profiles.toml`: Profile definitions for grouping skills by workflow or domain.

## Installation

Install skills from this collection using `skillm`:

```bash
skillm install tinchogb/skills-collection --global
```

## Upstream Sync Workflow

Third-party skills that declare an `upstream.toml` configuration can be audited and synchronized from the host using [`just`](https://github.com) (requires `uv`, `incus`, `git`, and `skillm`):

```bash
# List tracked third-party skills and their recorded upstream version
just status

# Check for new upstream versions or file drift without modifying the repository
just check [skill|all]

# Upgrade the upstream package in its source environment and sync changes
just upgrade [skill|all]

# Extract updated files, draft a Conventional Commit via Pi, push, and run `skillm update`
just sync [skill|all]
```

## Adding a Third-Party Skill

To register a new third-party skill under `third-party/<skill-name>/`, include the skill files (`SKILL.md`, `reference.md`, scripts, etc.) along with a declarative `upstream.toml` manifest:

```toml
[upstream]
type = "incus"
container = "c1-gui-u24-zotero"
user = "ubuntu"
package = "zotero-mcp-server"

# Command executed inside the container to print the current upstream version string
version_cmd = "uv tool list | awk '/^zotero-mcp-server / {print \$2}'"

# Command executed inside the container when running `just upgrade`
upgrade_cmd = "uv tool upgrade 'zotero-mcp-server[all]' && zotero-mcp install-skill --dir ~/Zotero-Agent || true"

# Source directory inside the container and exact list of files to pull
source_dir = "/home/ubuntu/Zotero-Agent/.agents/skills/zotero-cli"
files = ["SKILL.md", "reference.md"]

[commit]
scope = "third-party"          # Optional (default: "third-party")
use_pi = true                  # Optional (default: false); drafts commit message via Pi
pi_model = "vllm/qwen3.8"      # Optional (default: "vllm/qwen3.8")
pi_timeout = 90                # Optional (default: 90 seconds)
pi_repo_mount = "/mnt/skills-collection" # Optional; auto-mounted read-only if missing
```

### Registration Steps

1. Create `third-party/<skill-name>/` with the initial skill files and `upstream.toml`.
2. Record the baseline version (or run `just sync <skill-name>` after committing `upstream.toml` so `sync_upstream.py` pulls the files and writes `.upstream-version` automatically).
3. Commit and push the new directory, then install it via `skillm`:
   ```bash
   skillm install https://github.com<skill-name> --global
   ```
4. Verify discovery and state with `just status` and `just check <skill-name>`.