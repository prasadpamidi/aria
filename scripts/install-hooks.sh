#!/usr/bin/env bash
#
# Installs Aria's git hooks by pointing `core.hooksPath` at the tracked
# `.githooks/` directory. Run this once per clone.
#
# Uninstall:
#   git config --unset core.hooksPath

set -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [ ! -d ".githooks" ]; then
    echo "✗ .githooks/ directory not found at $REPO_ROOT" >&2
    exit 1
fi

# Make sure all hooks are executable
chmod +x .githooks/* 2>/dev/null || true

# Point git at the tracked hooks directory
git config core.hooksPath .githooks

cat <<EOF
✓ Git hooks installed.

  Hooks directory: $REPO_ROOT/.githooks
  pre-commit:      runs swiftformat --lint and swiftlint --strict on staged Swift files

Tooling required (install via 'brew bundle'):
  - swiftformat
  - swiftlint

To uninstall:
  git config --unset core.hooksPath
EOF
