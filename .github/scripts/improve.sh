#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# improve.sh — Chip away at RuboCop, stree, and Prettier/ESLint violations.
#
# Env vars (with defaults):
#   RUBOCOP_MAX_LINES            (300)
#   STREE_MAX_LINES              (200)
#   PRETTIER_MAX_LINES           (200)
#   RUBOCOP_AUTOCORRECT_MODE     (-a)
#   BRANCH_PREFIX                (improvement)
#   PR_TITLE_PREFIX              (chore(tidy): formatting and linting)
#   DRY_RUN                      (false)
#   GH_TOKEN                     (for gh CLI)
##############################################################################

RUBOCOP_MAX_LINES="${RUBOCOP_MAX_LINES:-300}"
STREE_MAX_LINES="${STREE_MAX_LINES:-200}"
STREE_IGNORE_FILES="${STREE_IGNORE_FILES:-}"
PRETTIER_MAX_LINES="${PRETTIER_MAX_LINES:-200}"
AUTOCORRECT_MODE="${RUBOCOP_AUTOCORRECT_MODE:--a}"
BRANCH_PREFIX="${BRANCH_PREFIX:-improvement}"
PR_TITLE_PREFIX="${PR_TITLE_PREFIX:-chore(tidy): formatting and linting}"
DRY_RUN="${DRY_RUN:-false}"

BRANCH_NAME="${BRANCH_PREFIX}/$(date +%Y-%m-%d-%H%M)"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
PR_BODY_FILE="${RUNNER_TEMP}/pr_body.md"

PR_SECTIONS=()
HAS_CHANGES="false"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo ">>> $*"; }
warn() { echo "::warning::$*"; }

set_output() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }

# Total lines changed (added + removed) in unstaged diff
diff_lines() {
  git diff --numstat | awk '{ a += $1; b += $2 } END { print a + b + 0 }'
}

# Reset uncommitted changes back to HEAD
reset_changes() { git checkout -- . 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Error trap — clean up on unexpected failure
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "::error::Unexpected failure (exit $rc). Resetting working tree."
    reset_changes
    git checkout - 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ===========================================================================
# Git setup
# ===========================================================================
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Save starting point for diff fingerprint (used to detect duplicate PRs)
START_SHA=$(git rev-parse HEAD)

git checkout -b "$BRANCH_NAME" 2>/dev/null || {
  git branch -D "$BRANCH_NAME" 2>/dev/null || true
  git checkout -b "$BRANCH_NAME"
}

# ===========================================================================
# Tool 1 — RuboCop
# ===========================================================================
echo "::group::RuboCop"

if [ -f .rubocop.yml ] && bundle exec rubocop --version &>/dev/null; then
  log "Running RuboCop analysis..."
  rubocop_json=$(bundle exec rubocop --format json 2>/dev/null || true)

  if [ -n "$rubocop_json" ]; then
    # Correctable offenses grouped by cop, most violations first
    cop_ranking=$(
      echo "$rubocop_json" | jq -r '
        [ .files[].offenses[] | select(.correctable == true) ]
        | group_by(.cop_name)
        | map({ cop: .[0].cop_name, count: length })
        | sort_by(-.count)
        | .[]
        | "\(.cop) \(.count)"
      ' 2>/dev/null || true
    )

    if [ -n "$cop_ranking" ]; then
      total_correctable=$(echo "$cop_ranking" | awk '{ s += $2 } END { print s + 0 }')
      cop_count=$(echo "$cop_ranking" | wc -l | tr -d ' ')
      log "Found $total_correctable correctable offenses across $cop_count cops."

      # ---------------------------------------------------------------
      # Incrementally apply cops, checking actual diff after each
      # ---------------------------------------------------------------
      applied_cops=()
      prev_lines=0
      max_scan=10
      rubocop_committed=false

      cop_idx=0
      while [ "$cop_idx" -lt "$max_scan" ]; do
        cop_idx=$((cop_idx + 1))
        cop_line=$(echo "$cop_ranking" | sed -n "${cop_idx}p")
        [ -z "$cop_line" ] && break

        cop_name=$(echo "$cop_line" | awk '{ print $1 }')
        cop_violations=$(echo "$cop_line" | awk '{ print $2 }')
        log "Trying $cop_name ($cop_violations violations)..."

        bundle exec rubocop --only "$cop_name" "$AUTOCORRECT_MODE" --force-exclusion 2>/dev/null || true
        lines=$(diff_lines)
        cop_delta=$((lines - prev_lines))

        if [ "$cop_delta" -eq 0 ]; then
          log "$cop_name produced no changes — skipping."
          continue
        fi

        log "$cop_name: +$cop_delta lines (cumulative: $lines)."

        if [ "$lines" -le "$RUBOCOP_MAX_LINES" ]; then
          applied_cops+=("$cop_name")
          prev_lines=$lines
          log "Accepted $cop_name."
        elif [ ${#applied_cops[@]} -eq 0 ]; then
          # First viable cop already over budget — accept and subset later
          applied_cops+=("$cop_name")
          log "$cop_name exceeds budget alone — will subset."
          break
        else
          # Would push over budget — roll back to accepted cops only
          log "$cop_name would exceed budget. Rolling back..."
          reset_changes
          cops_csv=$(IFS=,; echo "${applied_cops[*]}")
          bundle exec rubocop --only "$cops_csv" "$AUTOCORRECT_MODE" --force-exclusion 2>/dev/null || true
          break
        fi
      done

      lines=$(diff_lines)

      # Over budget → subset to alphabetical slice of files
      if [ "$lines" -gt "$RUBOCOP_MAX_LINES" ]; then
        cops_csv=$(IFS=,; echo "${applied_cops[*]}")
        log "Over budget ($lines > $RUBOCOP_MAX_LINES). Subsetting files..."
        changed_files=$(git diff --name-only | sort)
        total_files=$(echo "$changed_files" | wc -l | tr -d ' ')
        reset_changes

        subset_count=$(( total_files * RUBOCOP_MAX_LINES / lines ))
        [ "$subset_count" -lt 1 ] && subset_count=1
        subset_files=$(echo "$changed_files" | head -n "$subset_count")
        log "Re-running on $subset_count of $total_files files..."

        echo "$subset_files" | tr '\n' '\0' \
          | xargs -0 bundle exec rubocop --only "$cops_csv" "$AUTOCORRECT_MODE" --force-exclusion 2>/dev/null || true

        lines=$(diff_lines)
        log "Subset diff: $lines lines."

        # Second trim if still over
        if [ "$lines" -gt "$RUBOCOP_MAX_LINES" ] && [ "$lines" -gt 0 ]; then
          changed_files=$(git diff --name-only | sort)
          total_files=$(echo "$changed_files" | wc -l | tr -d ' ')
          reset_changes

          subset_count=$(( total_files * RUBOCOP_MAX_LINES / lines ))
          [ "$subset_count" -lt 1 ] && subset_count=1
          subset_files=$(echo "$changed_files" | head -n "$subset_count")
          log "Second trim: $subset_count files..."

          echo "$subset_files" | tr '\n' '\0' \
            | xargs -0 bundle exec rubocop --only "$cops_csv" "$AUTOCORRECT_MODE" --force-exclusion 2>/dev/null || true

          lines=$(diff_lines)
          log "Final diff: $lines lines."
        fi
      fi

      if [ "$lines" -gt 0 ]; then
        files_changed=$(git diff --name-only | wc -l | tr -d ' ')

        if [ "$DRY_RUN" = "true" ]; then
          cops_csv=$(IFS=,; echo "${applied_cops[*]}")
          log "[DRY RUN] Would commit: rubocop $cops_csv — $lines lines, $files_changed files"
          reset_changes
        else
          git add -u
          if [ ${#applied_cops[@]} -eq 1 ]; then
            git commit -m "rubocop: fix ${applied_cops[0]} ($files_changed files)"
          else
            git commit -m "rubocop: fix ${#applied_cops[@]} cops ($files_changed files)"
          fi
          HAS_CHANGES="true"
        fi

        autocorrect_label="Safe auto-correct (\`-a\`)"
        [ "$AUTOCORRECT_MODE" = "-A" ] && autocorrect_label="All auto-correct (\`-A\`)"

        section="### RuboCop: ${#applied_cops[@]} cop(s)"$'\n'
        for c in "${applied_cops[@]}"; do
          section+="- \`$c\`"$'\n'
        done
        section+="- Fixed $files_changed files ($lines lines changed)"$'\n'
        section+="- $autocorrect_label"$'\n'
        PR_SECTIONS+=("$section")

        rubocop_committed=true
      fi

      [ "$rubocop_committed" = "false" ] && log "No RuboCop changes produced."
    else
      log "No correctable offenses found."
    fi
  else
    warn "RuboCop produced no JSON output."
  fi
else
  if [ ! -f .rubocop.yml ]; then
    log "No .rubocop.yml — skipping RuboCop."
  else
    warn "RuboCop not available via bundle exec — skipping."
  fi
fi
echo "::endgroup::"

# ===========================================================================
# Tool 2 — stree
# ===========================================================================
echo "::group::stree"

stree_cmd=""
if bundle exec stree version &>/dev/null 2>&1; then
  stree_cmd="bundle exec stree"
elif command -v stree &>/dev/null; then
  stree_cmd="stree"
fi

if [ -n "$stree_cmd" ]; then
  # Warn if both RuboCop and stree are active without syntax_tree config inheritance
  if [ -f .rubocop.yml ] && bundle exec rubocop --version &>/dev/null 2>&1; then
    if ! grep -q 'syntax_tree' .rubocop.yml 2>/dev/null; then
      warn "Both RuboCop and stree are enabled but .rubocop.yml does not inherit syntax_tree config. This can cause conflicting fixes that loop. Add 'inherit_gem: { syntax_tree: config/rubocop.yml }' to .rubocop.yml. See: https://github.com/ruby-syntax-tree/syntax_tree#rubocop"
    fi
  fi

  log "Running stree check..."

  # Build --ignore-files flags: sensible defaults + caller-supplied extras
  stree_ignore_flags=("--ignore-files=vendor/**/*.rb" "--ignore-files=db/schema.rb" "--ignore-files=db/migrate/**/*.rb")
  # shellcheck disable=SC2086
  for pattern in $STREE_IGNORE_FILES; do
    stree_ignore_flags+=("--ignore-files=${pattern}")
  done

  stree_output=$($stree_cmd check "${stree_ignore_flags[@]}" '**/*.rb' 2>&1 || true)

  # Extract .rb file paths from whatever output format stree produces
  stree_files=""
  while IFS= read -r candidate; do
    [ -f "$candidate" ] && stree_files+="$candidate"$'\n'
  done < <(echo "$stree_output" | grep -oE '\S+\.rb\b' | sort -u)
  stree_files=$(echo "$stree_files" | sed '/^$/d')

  if [ -n "$stree_files" ]; then
    total_stree_files=$(echo "$stree_files" | wc -l | tr -d ' ')
    log "Found $total_stree_files files needing stree formatting."

    # shellcheck disable=SC2086
    echo "$stree_files" | tr '\n' '\0' | xargs -0 $stree_cmd write 2>/dev/null || true
    lines=$(diff_lines)
    log "Total stree diff: $lines lines."

    if [ "$lines" -gt "$STREE_MAX_LINES" ] && [ "$lines" -gt 0 ]; then
      log "Over budget ($lines > $STREE_MAX_LINES). Subsetting..."
      reset_changes

      subset_count=$(( total_stree_files * STREE_MAX_LINES / lines ))
      [ "$subset_count" -lt 1 ] && subset_count=1
      subset_files=$(echo "$stree_files" | head -n "$subset_count")
      log "Formatting $subset_count of $total_stree_files files..."

      # shellcheck disable=SC2086
      echo "$subset_files" | tr '\n' '\0' | xargs -0 $stree_cmd write 2>/dev/null || true
      lines=$(diff_lines)
      log "Subset diff: $lines lines."

      # Second trim
      if [ "$lines" -gt "$STREE_MAX_LINES" ] && [ "$lines" -gt 0 ]; then
        changed_count=$(git diff --name-only | wc -l | tr -d ' ')
        reset_changes

        subset_count=$(( changed_count * STREE_MAX_LINES / lines ))
        [ "$subset_count" -lt 1 ] && subset_count=1
        subset_files=$(echo "$stree_files" | head -n "$subset_count")
        log "Second trim: $subset_count files..."

        # shellcheck disable=SC2086
        echo "$subset_files" | tr '\n' '\0' | xargs -0 $stree_cmd write 2>/dev/null || true
        lines=$(diff_lines)
        log "Final stree diff: $lines lines."
      fi
    fi

    if [ "$lines" -gt 0 ]; then
      files_changed=$(git diff --name-only | wc -l | tr -d ' ')

      if [ "$DRY_RUN" = "true" ]; then
        log "[DRY RUN] Would commit: stree format $files_changed ruby files ($lines lines)"
        reset_changes
      else
        git add -u
        git commit -m "stree: format $files_changed ruby files"
        HAS_CHANGES="true"
      fi

      section="### stree formatting"$'\n'
      section+="- Formatted $files_changed of $total_stree_files non-conforming Ruby files"$'\n'
      PR_SECTIONS+=("$section")
    else
      log "stree produced no changes."
    fi
  else
    log "All Ruby files already conform to stree formatting."
  fi
else
  log "stree not available — skipping."
fi
echo "::endgroup::"

# ===========================================================================
# Tool 3 — Prettier
# ===========================================================================
echo "::group::Prettier"

prettier_bin=""
if [ -x node_modules/.bin/prettier ]; then
  prettier_bin="node_modules/.bin/prettier"
elif command -v prettier &>/dev/null; then
  prettier_bin="prettier"
elif npx prettier --version &>/dev/null 2>&1; then
  prettier_bin="npx prettier"
fi

# Check for any Prettier config
has_prettier_config=false
for cfg in .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml \
           .prettierrc.js .prettierrc.cjs .prettierrc.mjs .prettierrc.toml \
           prettier.config.js prettier.config.cjs prettier.config.mjs; do
  [ -f "$cfg" ] && { has_prettier_config=true; break; }
done
if [ "$has_prettier_config" = "false" ] && [ -f package.json ]; then
  jq -e '.prettier' package.json &>/dev/null 2>&1 && has_prettier_config=true
fi

# Detect eslint-plugin-prettier
uses_eslint_prettier=false
if [ -f node_modules/eslint-plugin-prettier/package.json ]; then
  uses_eslint_prettier=true
fi

# Resolve ESLint binary (only when eslint-plugin-prettier detected)
eslint_bin=""
if [ "$uses_eslint_prettier" = "true" ]; then
  if [ -x node_modules/.bin/eslint ]; then
    eslint_bin="node_modules/.bin/eslint"
  elif command -v eslint &>/dev/null; then
    eslint_bin="eslint"
  elif npx eslint --version &>/dev/null 2>&1; then
    eslint_bin="npx eslint"
  fi

  if [ -z "$eslint_bin" ]; then
    warn "eslint-plugin-prettier detected but ESLint binary not found — falling back to standalone Prettier."
    uses_eslint_prettier=false
  fi
fi

if [ "$uses_eslint_prettier" = "true" ]; then
  log "eslint-plugin-prettier detected — using ESLint for JS/TS formatting."

  $eslint_bin --fix '**/*.{js,jsx,ts,tsx}' --ignore-pattern 'vendor/**' 2>/dev/null || true
  lines=$(diff_lines)
  log "Total ESLint+Prettier diff: $lines lines."

  if [ "$lines" -gt "$PRETTIER_MAX_LINES" ] && [ "$lines" -gt 0 ]; then
    log "Over budget ($lines > $PRETTIER_MAX_LINES). Subsetting..."
    changed_files=$(git diff --name-only | sort)
    total_files=$(echo "$changed_files" | wc -l | tr -d ' ')
    reset_changes

    subset_count=$(( total_files * PRETTIER_MAX_LINES / lines ))
    [ "$subset_count" -lt 1 ] && subset_count=1
    subset_files=$(echo "$changed_files" | head -n "$subset_count")
    log "Re-running ESLint on $subset_count of $total_files files..."

    echo "$subset_files" | tr '\n' '\0' \
      | xargs -0 "$eslint_bin" --fix --no-error-on-unmatched-pattern 2>/dev/null || true
    lines=$(diff_lines)
    log "Subset diff: $lines lines."

    # Second trim
    if [ "$lines" -gt "$PRETTIER_MAX_LINES" ] && [ "$lines" -gt 0 ]; then
      changed_count=$(git diff --name-only | wc -l | tr -d ' ')
      reset_changes

      subset_count=$(( changed_count * PRETTIER_MAX_LINES / lines ))
      [ "$subset_count" -lt 1 ] && subset_count=1
      subset_files=$(echo "$changed_files" | head -n "$subset_count")
      log "Second trim: $subset_count files..."

      echo "$subset_files" | tr '\n' '\0' \
        | xargs -0 "$eslint_bin" --fix --no-error-on-unmatched-pattern 2>/dev/null || true
      lines=$(diff_lines)
      log "Final ESLint+Prettier diff: $lines lines."
    fi
  fi

  if [ "$lines" -gt 0 ]; then
    files_changed=$(git diff --name-only | wc -l | tr -d ' ')

    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY RUN] Would commit: eslint+prettier fix $files_changed js/ts files ($lines lines)"
      reset_changes
    else
      git add -u
      git commit -m "eslint+prettier: fix $files_changed js/ts files"
      HAS_CHANGES="true"
    fi

    section="### ESLint + Prettier formatting"$'\n'
    section+="- Fixed $files_changed JS/TS files via \`eslint --fix\` (eslint-plugin-prettier)"$'\n'
    section+="- $lines lines changed"$'\n'
    PR_SECTIONS+=("$section")
  else
    log "ESLint+Prettier produced no changes."
  fi
elif [ -n "$prettier_bin" ] && [ "$has_prettier_config" = "true" ]; then
  log "Running Prettier check..."
  # shellcheck disable=SC2086
  prettier_output=$($prettier_bin --check '**/*.{js,jsx,ts,tsx}' '!vendor/**' 2>&1 || true)

  # Strip [warn] prefix (older Prettier) and filter to JS/TS file paths
  prettier_files=$(
    echo "$prettier_output" \
      | sed 's/^\[warn\] //' \
      | grep -E '\.(js|jsx|ts|tsx)$' \
      | sort -u || true
  )

  if [ -n "$prettier_files" ]; then
    total_prettier_files=$(echo "$prettier_files" | wc -l | tr -d ' ')
    log "Found $total_prettier_files files needing Prettier formatting."

    # shellcheck disable=SC2086
    echo "$prettier_files" | tr '\n' '\0' | xargs -0 $prettier_bin --write 2>/dev/null || true
    lines=$(diff_lines)
    log "Total Prettier diff: $lines lines."

    if [ "$lines" -gt "$PRETTIER_MAX_LINES" ] && [ "$lines" -gt 0 ]; then
      log "Over budget ($lines > $PRETTIER_MAX_LINES). Subsetting..."
      reset_changes

      subset_count=$(( total_prettier_files * PRETTIER_MAX_LINES / lines ))
      [ "$subset_count" -lt 1 ] && subset_count=1
      subset_files=$(echo "$prettier_files" | head -n "$subset_count")
      log "Formatting $subset_count of $total_prettier_files files..."

      # shellcheck disable=SC2086
      echo "$subset_files" | tr '\n' '\0' | xargs -0 $prettier_bin --write 2>/dev/null || true
      lines=$(diff_lines)
      log "Subset diff: $lines lines."

      # Second trim
      if [ "$lines" -gt "$PRETTIER_MAX_LINES" ] && [ "$lines" -gt 0 ]; then
        changed_count=$(git diff --name-only | wc -l | tr -d ' ')
        reset_changes

        subset_count=$(( changed_count * PRETTIER_MAX_LINES / lines ))
        [ "$subset_count" -lt 1 ] && subset_count=1
        subset_files=$(echo "$prettier_files" | head -n "$subset_count")
        log "Second trim: $subset_count files..."

        # shellcheck disable=SC2086
        echo "$subset_files" | tr '\n' '\0' | xargs -0 $prettier_bin --write 2>/dev/null || true
        lines=$(diff_lines)
        log "Final Prettier diff: $lines lines."
      fi
    fi

    if [ "$lines" -gt 0 ]; then
      files_changed=$(git diff --name-only | wc -l | tr -d ' ')

      if [ "$DRY_RUN" = "true" ]; then
        log "[DRY RUN] Would commit: prettier format $files_changed js/ts files ($lines lines)"
        reset_changes
      else
        git add -u
        git commit -m "prettier: format $files_changed js/ts files"
        HAS_CHANGES="true"
      fi

      section="### Prettier formatting"$'\n'
      section+="- Formatted $files_changed of $total_prettier_files non-conforming JS/TS files"$'\n'
      PR_SECTIONS+=("$section")
    else
      log "Prettier produced no changes."
    fi
  else
    log "All JS/TS files already conform to Prettier formatting."
  fi
else
  if [ -z "$prettier_bin" ]; then
    log "Prettier not available — skipping."
  else
    log "No Prettier config found — skipping."
  fi
fi
echo "::endgroup::"

# ===========================================================================
# Outputs
# ===========================================================================
echo "::group::Summary"

if [ ${#PR_SECTIONS[@]} -eq 0 ]; then
  log "No changes produced by any tool."
  set_output "has_changes" "false"
  set_output "dry_run" "$DRY_RUN"
else
  pr_title="${PR_TITLE_PREFIX}"

  # Compute diff fingerprint for duplicate detection
  diff_fingerprint=$(git diff "$START_SHA"..HEAD | sha256sum | cut -d' ' -f1)
  log "Diff fingerprint: $diff_fingerprint"
  set_output "diff_fingerprint" "$diff_fingerprint"

  {
    echo "## $pr_title"
    echo ""
    for section in "${PR_SECTIONS[@]}"; do
      echo "$section"
    done
    echo "---"
    echo "Existing CI gates merging. Generated by improvement workflow."
    echo ""
    echo "<!-- diff-fingerprint:${diff_fingerprint} -->"
  } > "$PR_BODY_FILE"

  log "PR body written to $PR_BODY_FILE"
  cat "$PR_BODY_FILE"

  set_output "has_changes" "$HAS_CHANGES"
  set_output "dry_run" "$DRY_RUN"
  set_output "branch_name" "$BRANCH_NAME"
  set_output "pr_title" "$pr_title"
fi

echo "::endgroup::"
log "Done."
