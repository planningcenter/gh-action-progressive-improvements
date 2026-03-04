#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_repo
}

teardown() {
  teardown_test_repo
}

# =========================================================================
# No tools available
# =========================================================================

@test "no tools available: exits cleanly with no changes" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(get_output has_changes)" = "false" ]
}

@test "no tools available: output mentions skipping" {
  # Hide npx so prettier detection falls through
  create_mock "npx" 'exit 1'

  run bash "$SCRIPT"
  [[ "$output" == *"No .rubocop.yml"* ]]
  [[ "$output" == *"stree not available"* ]]
  [[ "$output" == *"Prettier not available"* ]]
}

# =========================================================================
# RuboCop
# =========================================================================

@test "rubocop: skipped when .rubocop.yml missing" {
  setup_bundle_mock "rubocop" 'echo "1.0.0"'
  # No .rubocop.yml created

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No .rubocop.yml"* ]]
}

@test "rubocop: skipped when bundle exec rubocop not available" {
  touch .rubocop.yml
  # No bundle mock

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not available via bundle exec"* ]]
}

@test "rubocop: fixes single cop within budget" {
  touch .rubocop.yml

  # Create a ruby file to modify
  echo 'puts "hello"' > app.rb
  git add app.rb && git commit -q -m "add app.rb"

  # Mock rubocop --version
  setup_bundle_mock "rubocop" '
    if [[ "$*" == *"--version"* ]]; then
      echo "1.60.0"
      exit 0
    fi
    if [[ "$*" == *"--format json"* ]]; then
      cat <<JSON
{
  "files": [
    {
      "path": "app.rb",
      "offenses": [
        {"cop_name": "Style/FrozenStringLiteralComment", "correctable": true},
        {"cop_name": "Style/FrozenStringLiteralComment", "correctable": true}
      ]
    }
  ]
}
JSON
      exit 0
    fi
    if [[ "$*" == *"--only"* ]]; then
      # Simulate fixing: add a frozen string literal comment
      sed -i.bak "1s/^/# frozen_string_literal: true\n/" app.rb 2>/dev/null || \
        sed -i "" "1s/^/# frozen_string_literal: true\\
/" app.rb
      rm -f app.rb.bak
      exit 0
    fi
    exit 0
  '

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(get_output has_changes)" = "true" ]
  [[ "$output" == *"Style/FrozenStringLiteralComment"* ]]

  # Verify a commit was made
  local commit_msg
  commit_msg=$(git log -1 --format=%s)
  [[ "$commit_msg" == *"rubocop"* ]]
}

@test "rubocop: dry run does not commit" {
  touch .rubocop.yml
  echo 'puts "hello"' > app.rb
  git add app.rb && git commit -q -m "add app.rb"

  setup_bundle_mock "rubocop" '
    if [[ "$*" == *"--version"* ]]; then echo "1.60.0"; exit 0; fi
    if [[ "$*" == *"--format json"* ]]; then
      cat <<JSON
{
  "files": [
    {
      "path": "app.rb",
      "offenses": [
        {"cop_name": "Style/FrozenStringLiteralComment", "correctable": true}
      ]
    }
  ]
}
JSON
      exit 0
    fi
    if [[ "$*" == *"--only"* ]]; then
      sed -i.bak "1s/^/# frozen_string_literal: true\n/" app.rb 2>/dev/null || \
        sed -i "" "1s/^/# frozen_string_literal: true\\
/" app.rb
      rm -f app.rb.bak
      exit 0
    fi
  '

  export DRY_RUN=true
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]

  # No new commit beyond the initial ones
  local commit_count
  commit_count=$(git log --oneline | wc -l | tr -d ' ')
  [ "$commit_count" -eq 2 ]  # init + add app.rb
}

@test "rubocop: no correctable offenses produces no changes" {
  touch .rubocop.yml

  setup_bundle_mock "rubocop" '
    if [[ "$*" == *"--version"* ]]; then echo "1.60.0"; exit 0; fi
    if [[ "$*" == *"--format json"* ]]; then
      echo "{\"files\": [{\"path\": \"app.rb\", \"offenses\": []}]}"
      exit 0
    fi
    exit 0
  '

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No correctable offenses"* ]]
  [ "$(get_output has_changes)" = "false" ]
}

@test "rubocop: subsets files when over budget" {
  touch .rubocop.yml
  export RUBOCOP_MAX_LINES=5

  # Create multiple ruby files
  for i in $(seq 1 10); do
    echo "puts 'file $i'" > "file${i}.rb"
  done
  git add . && git commit -q -m "add files"

  setup_bundle_mock "rubocop" '
    if [[ "$*" == *"--version"* ]]; then echo "1.60.0"; exit 0; fi
    if [[ "$*" == *"--format json"* ]]; then
      offenses=""
      for i in $(seq 1 10); do
        [ -n "$offenses" ] && offenses+=","
        offenses+="{\"path\": \"file${i}.rb\", \"offenses\": [{\"cop_name\": \"Style/StringLiterals\", \"correctable\": true}]}"
      done
      echo "{\"files\": [$offenses]}"
      exit 0
    fi
    if [[ "$*" == *"--only"* ]]; then
      # Modify whichever files are passed as args (or all .rb files)
      for f in *.rb; do
        if [ -f "$f" ]; then
          # Check if this file is in the args or if no specific files given
          case " $* " in
            *" $f "*|*"--force-exclusion"*)
              echo "# modified" >> "$f"
              ;;
          esac
        fi
      done
      # If args contain specific files, only modify those
      for arg in "$@"; do
        if [[ "$arg" == *.rb ]] && [ -f "$arg" ]; then
          echo "# modified" >> "$arg"
        fi
      done
      exit 0
    fi
    exit 0
  '

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Subsetting"* ]] || [[ "$output" == *"Over budget"* ]] || [[ "$output" == *"subset"* ]]
}

# =========================================================================
# stree
# =========================================================================

@test "stree: skipped when not available" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stree not available"* ]]
}

@test "stree: formats files within budget" {
  # Create ruby file
  echo 'puts("hello")' > app.rb
  git add app.rb && git commit -q -m "add app.rb"

  # Mock stree as a standalone command
  create_mock "stree" '
    if [[ "$1" == "version" ]]; then echo "6.0.0"; exit 0; fi
    if [[ "$1" == "check" ]]; then
      echo "app.rb"
      exit 1  # stree check exits non-zero when files need formatting
    fi
    if [[ "$1" == "write" ]]; then
      shift
      for f in "$@"; do
        [ -f "$f" ] && echo "puts(\"hello\")" > "$f"  # "format" it
      done
      exit 0
    fi
  '

  # Need bundle to fail so it falls through to standalone stree
  create_mock "bundle" 'exit 1'

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # Should either find changes or report conforming (depending on diff)
  [[ "$output" == *"stree"* ]]
}

@test "stree: excludes db/schema.rb and db/migrate by default" {
  mkdir -p db/migrate
  echo 'puts("hello")' > app.rb
  echo 'puts("schema")' > db/schema.rb
  echo 'puts("migrate")' > db/migrate/20240101_create_users.rb
  git add . && git commit -q -m "add files"

  # Mock stree that records the --ignore-files args it receives
  create_mock "stree" '
    if [[ "$1" == "version" ]]; then echo "6.0.0"; exit 0; fi
    if [[ "$1" == "check" ]]; then
      # Record args for verification
      echo "$@" > '"$TEST_DIR"'/stree_check_args
      echo "app.rb"
      exit 1
    fi
    if [[ "$1" == "write" ]]; then
      shift
      for f in "$@"; do
        [ -f "$f" ] && echo "puts(\"hello\")" > "$f"
      done
      exit 0
    fi
  '
  create_mock "bundle" 'exit 1'

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # Verify the default ignore patterns were passed
  local check_args
  check_args=$(cat "$TEST_DIR/stree_check_args")
  [[ "$check_args" == *"--ignore-files=vendor/**/*.rb"* ]]
  [[ "$check_args" == *"--ignore-files=db/schema.rb"* ]]
  [[ "$check_args" == *"--ignore-files=db/migrate/**/*.rb"* ]]
}

@test "stree: includes custom STREE_IGNORE_FILES patterns" {
  echo 'puts("hello")' > app.rb
  git add app.rb && git commit -q -m "add app.rb"

  create_mock "stree" '
    if [[ "$1" == "version" ]]; then echo "6.0.0"; exit 0; fi
    if [[ "$1" == "check" ]]; then
      echo "$@" > '"$TEST_DIR"'/stree_check_args
      echo "app.rb"
      exit 1
    fi
    if [[ "$1" == "write" ]]; then
      shift
      for f in "$@"; do
        [ -f "$f" ] && echo "puts(\"hello\")" > "$f"
      done
      exit 0
    fi
  '
  create_mock "bundle" 'exit 1'

  export STREE_IGNORE_FILES="lib/generated/**/*.rb app/templates/**/*.rb"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local check_args
  check_args=$(cat "$TEST_DIR/stree_check_args")
  # Should have defaults
  [[ "$check_args" == *"--ignore-files=vendor/**/*.rb"* ]]
  [[ "$check_args" == *"--ignore-files=db/schema.rb"* ]]
  [[ "$check_args" == *"--ignore-files=db/migrate/**/*.rb"* ]]
  # And custom patterns
  [[ "$check_args" == *"--ignore-files=lib/generated/**/*.rb"* ]]
  [[ "$check_args" == *"--ignore-files=app/templates/**/*.rb"* ]]
}

@test "stree: all files conforming produces no changes" {
  echo 'puts "hello"' > app.rb
  git add app.rb && git commit -q -m "add app.rb"

  create_mock "stree" '
    if [[ "$1" == "version" ]]; then echo "6.0.0"; exit 0; fi
    if [[ "$1" == "check" ]]; then
      echo "All Ruby files already conform"
      exit 0
    fi
  '
  create_mock "bundle" 'exit 1'

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"conform"* ]] || [[ "$output" == *"no changes"* ]]
}

# =========================================================================
# Prettier
# =========================================================================

@test "prettier: skipped when not installed" {
  # Hide npx so prettier detection falls through
  create_mock "npx" 'exit 1'

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prettier not available"* ]]
}

@test "prettier: skipped when no config found" {
  create_mock "prettier" 'echo "3.0.0"'
  echo '{}' > package.json
  git add package.json && git commit -q -m "add package.json"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Prettier config"* ]]
}

@test "prettier: formats files within budget" {
  # Create prettier config and a JS file
  echo '{}' > .prettierrc
  echo 'const x=1' > app.js
  echo '{}' > package.json
  git add . && git commit -q -m "add files"

  mkdir -p node_modules/.bin
  cat > node_modules/.bin/prettier <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "--check" ]]; then
  echo "app.js"
  exit 1
fi
if [[ "$1" == "--write" ]]; then
  shift
  for f in "$@"; do
    [ -f "$f" ] && echo 'const x = 1;' > "$f"
  done
  exit 0
fi
echo "3.0.0"
MOCK
  chmod +x node_modules/.bin/prettier

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(get_output has_changes)" = "true" ]
  [[ "$output" == *"Prettier"* ]]

  local commit_msg
  commit_msg=$(git log -1 --format=%s)
  [[ "$commit_msg" == *"prettier"* ]]
}

@test "prettier: dry run does not commit" {
  echo '{}' > .prettierrc
  echo 'const x=1' > app.js
  echo '{}' > package.json
  git add . && git commit -q -m "add files"

  mkdir -p node_modules/.bin
  cat > node_modules/.bin/prettier <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "--check" ]]; then echo "app.js"; exit 1; fi
if [[ "$1" == "--write" ]]; then
  shift; for f in "$@"; do [ -f "$f" ] && echo 'const x = 1;' > "$f"; done; exit 0
fi
echo "3.0.0"
MOCK
  chmod +x node_modules/.bin/prettier

  export DRY_RUN=true
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
}

# =========================================================================
# PR body
# =========================================================================

@test "pr body: contains tool sections when changes made" {
  touch .rubocop.yml
  echo 'puts "hello"' > app.rb
  git add app.rb && git commit -q -m "add app.rb"

  setup_bundle_mock "rubocop" '
    if [[ "$*" == *"--version"* ]]; then echo "1.60.0"; exit 0; fi
    if [[ "$*" == *"--format json"* ]]; then
      cat <<JSON
{
  "files": [
    {
      "path": "app.rb",
      "offenses": [
        {"cop_name": "Style/FrozenStringLiteralComment", "correctable": true}
      ]
    }
  ]
}
JSON
      exit 0
    fi
    if [[ "$*" == *"--only"* ]]; then
      sed -i.bak "1s/^/# frozen_string_literal: true\n/" app.rb 2>/dev/null || \
        sed -i "" "1s/^/# frozen_string_literal: true\\
/" app.rb
      rm -f app.rb.bak
      exit 0
    fi
  '

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # PR body file should exist and contain RuboCop section
  [ -f "$TEST_DIR/pr_body.md" ]
  grep -q "RuboCop" "$TEST_DIR/pr_body.md"
  grep -q "Style/FrozenStringLiteralComment" "$TEST_DIR/pr_body.md"
}

# =========================================================================
# Outputs
# =========================================================================

@test "outputs: branch_name and pr_title set when changes exist" {
  touch .rubocop.yml
  echo 'puts "hello"' > app.rb
  git add app.rb && git commit -q -m "add app.rb"

  setup_bundle_mock "rubocop" '
    if [[ "$*" == *"--version"* ]]; then echo "1.60.0"; exit 0; fi
    if [[ "$*" == *"--format json"* ]]; then
      echo "{\"files\": [{\"path\": \"app.rb\", \"offenses\": [{\"cop_name\": \"Style/FrozenStringLiteralComment\", \"correctable\": true}]}]}"
      exit 0
    fi
    if [[ "$*" == *"--only"* ]]; then
      sed -i.bak "1s/^/# frozen_string_literal: true\n/" app.rb 2>/dev/null || \
        sed -i "" "1s/^/# frozen_string_literal: true\\
/" app.rb
      rm -f app.rb.bak
      exit 0
    fi
  '

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local branch
  branch="$(get_output branch_name)"
  [[ "$branch" == improvement/* ]]

  local title
  title="$(get_output pr_title)"
  [[ "$title" == *"chore(tidy)"* ]]
}

@test "outputs: custom branch prefix is used" {
  touch .rubocop.yml
  echo 'puts "hello"' > app.rb
  git add app.rb && git commit -q -m "add app.rb"

  setup_bundle_mock "rubocop" '
    if [[ "$*" == *"--version"* ]]; then echo "1.60.0"; exit 0; fi
    if [[ "$*" == *"--format json"* ]]; then
      echo "{\"files\": [{\"path\": \"app.rb\", \"offenses\": [{\"cop_name\": \"Style/FrozenStringLiteralComment\", \"correctable\": true}]}]}"
      exit 0
    fi
    if [[ "$*" == *"--only"* ]]; then
      sed -i.bak "1s/^/# frozen_string_literal: true\n/" app.rb 2>/dev/null || \
        sed -i "" "1s/^/# frozen_string_literal: true\\
/" app.rb
      rm -f app.rb.bak
      exit 0
    fi
  '

  export BRANCH_PREFIX="custom-prefix"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local branch
  branch="$(get_output branch_name)"
  [[ "$branch" == custom-prefix/* ]]
}
