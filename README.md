# Progressive Improvements

A reusable GitHub Actions workflow that chips away at formatting and linting violations over time. Instead of one massive PR that touches every file, it creates small, reviewable pull requests on a schedule — each staying within a configurable line-change budget.

## Supported Tools

| Tool | Language | What it does |
|------|----------|--------------|
| [RuboCop](https://rubocop.org/) | Ruby | Fixes the highest-volume correctable cop first (up to 3 attempts) |
| [stree](https://github.com/ruby-syntax-tree/syntax_tree) | Ruby | Applies syntax-tree formatting |
| [Prettier](https://prettier.io/) | JS / TS | Applies Prettier formatting to `.js`, `.jsx`, `.ts`, `.tsx` files |

Each tool is **optional** — the workflow skips any tool that isn't installed or configured in the calling repository.

## Quick Start

Create a workflow in your repository (e.g. `.github/workflows/progressive-improvements.yml`):

```yaml
name: Progressive Improvements

on:
  schedule:
    - cron: '0 14 * * 1' # Every Monday at 2 PM UTC
  workflow_dispatch:       # Allow manual runs

jobs:
  improve:
    uses: planningcenter/gh-action-progressive-improvements/.github/workflows/improvement.yml@main
```

That's it. The workflow will:

1. Detect which tools are available in your project
2. Run each tool and collect fixes
3. Trim changes to stay within the line budget
4. Open (or update) a pull request with a detailed summary

## Inputs

All inputs are optional and have sensible defaults.

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `rubocop_max_lines` | string | `300` | Max lines changed for RuboCop fixes |
| `stree_max_lines` | string | `200` | Max lines changed for stree formatting |
| `prettier_max_lines` | string | `200` | Max lines changed for Prettier formatting |
| `rubocop_autocorrect_mode` | string | `-a` | `-a` for safe auto-correct, `-A` for all (including unsafe) |
| `branch_prefix` | string | `improvement` | Prefix for the created branch (e.g. `improvement/2025-02-26-1400`) |
| `pr_title_prefix` | string | `chore(tidy): formatting and linting` | Prefix for the PR title |
| `pr_assignees` | string | `''` | Comma-separated GitHub usernames to assign to the PR |
| `pr_reviewers` | string | `''` | Comma-separated GitHub usernames to request review from |
| `dry_run` | boolean | `false` | When `true`, analyzes and logs changes but does not commit or open a PR |

### Example with custom inputs

```yaml
jobs:
  improve:
    uses: planningcenter/gh-action-progressive-improvements/.github/workflows/improvement.yml@main
    with:
      rubocop_max_lines: '500'
      stree_max_lines: '300'
      prettier_max_lines: '300'
      rubocop_autocorrect_mode: '-A'
      dry_run: true
```

### Assigning a shepherd

Let one person volunteer to review all improvement PRs before rolling it out to the whole team:

```yaml
jobs:
  improve:
    uses: planningcenter/gh-action-progressive-improvements/.github/workflows/improvement.yml@main
    with:
      pr_assignees: 'octocat'
      pr_reviewers: 'octocat'
```

## How It Works

### Budget enforcement

Each tool has a maximum line-change budget. When a tool's changes exceed the budget, the workflow:

1. Calculates a proportional subset of files that should fit within the budget
2. Resets the working tree and re-runs the tool on only those files
3. If still over budget, applies a second trim

This ensures PRs stay small and reviewable regardless of how many violations exist in the codebase.

### RuboCop strategy

Rather than fixing all cops at once, the workflow:

1. Runs RuboCop in JSON mode to identify all correctable offenses
2. Ranks cops by violation count (highest first)
3. Attempts to fix the top cop — if it produces no changes, tries the next one (up to 3 attempts)

This focuses each PR on a single type of fix, making review easier.

### Tool detection

The workflow auto-detects your project setup:

- **Ruby**: Runs `bundle exec rubocop` / `bundle exec stree` if available, falls back to system commands
- **Node.js**: Detects your package manager (yarn, pnpm, bun, or npm) and installs dependencies
- **Prettier**: Checks `node_modules/.bin/prettier`, system `prettier`, then `npx prettier`; also requires a Prettier config file or `prettier` key in `package.json`

### Permissions

The workflow requires these permissions on the caller's `GITHUB_TOKEN`:

```yaml
permissions:
  contents: write      # Push branches
  pull-requests: write # Create and update PRs
```

These are declared in the reusable workflow itself, so you don't need to set them in your calling workflow.

## Pull Request Output

Each PR includes a structured summary showing what was changed:

```markdown
## chore(tidy): formatting and linting 02/26/2025 14:00

### RuboCop: `Style/StringLiterals`
- Fixed 12 files (87 lines changed)
- Safe auto-correct (`-a`)

### stree formatting
- Formatted 5 of 23 non-conforming Ruby files

### Prettier formatting
- Formatted 8 of 15 non-conforming JS/TS files

---
Existing CI gates merging. Generated by improvement workflow.
```

## Dry Run

Use `dry_run: true` to see what the workflow would do without creating any commits or PRs. The workflow will still run all tools and log the results — useful for evaluating the scope of changes before going live.

## Requirements

For each tool to run, the calling repository needs:

- **RuboCop**: `.rubocop.yml` + RuboCop in the bundle
- **stree**: `stree` in the bundle or on `PATH`
- **Prettier**: A Prettier config file + `prettier` available (via `node_modules`, system, or `npx`)
