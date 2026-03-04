#!/usr/bin/env bash
# Shared setup/teardown for improve.sh BATS tests

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PROJECT_ROOT/.github/scripts/improve.sh"

setup_test_repo() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"

  cd "$TEST_DIR" || return 1
  git init -q
  git config user.name "test"
  git config user.email "test@test.com"

  # Create an initial commit so HEAD exists
  echo "init" > README.md
  git add README.md
  git commit -q -m "init"

  # Point GITHUB_OUTPUT and RUNNER_TEMP to temp files
  export GITHUB_OUTPUT="$TEST_DIR/github_output"
  export RUNNER_TEMP="$TEST_DIR"
  touch "$GITHUB_OUTPUT"

  # Add mock bin directory to PATH (prepend so mocks take priority)
  MOCK_BIN="$TEST_DIR/mock_bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  # Default: no tools available (tests opt in by creating mocks)
  # No .rubocop.yml, no package.json, no stree, no prettier
}

teardown_test_repo() {
  cd /
  rm -rf "$TEST_DIR"
}

# Read a GitHub Actions output value
get_output() {
  grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

# Create a mock executable in the mock bin directory
create_mock() {
  local name="$1"
  local body="$2"
  cat > "$MOCK_BIN/$name" <<SCRIPT
#!/usr/bin/env bash
$body
SCRIPT
  chmod +x "$MOCK_BIN/$name"
}

# Create a mock "bundle" that dispatches to sub-mocks based on args
# Usage: setup_bundle_mock "rubocop" "script body"
setup_bundle_mock() {
  local tool="$1"
  local body="$2"

  # Create the tool-specific mock
  create_mock "_mock_${tool}" "$body"

  # Create or append to bundle mock
  if [ ! -f "$MOCK_BIN/bundle" ]; then
    cat > "$MOCK_BIN/bundle" <<'SCRIPT'
#!/usr/bin/env bash
shift  # consume "exec"
tool="$1"
shift
mock_script="$(dirname "$0")/_mock_${tool}"
if [ -x "$mock_script" ]; then
  exec "$mock_script" "$@"
else
  echo "mock bundle: unknown tool $tool" >&2
  exit 1
fi
SCRIPT
    chmod +x "$MOCK_BIN/bundle"
  fi
}
