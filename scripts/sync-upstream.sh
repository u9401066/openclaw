#!/usr/bin/env bash
# sync-upstream.sh — Sync local customizations with upstream OpenClaw
#
# Usage:
#   ./scripts/sync-upstream.sh          # Update & rebase local on latest upstream
#   ./scripts/sync-upstream.sh --status # Show current state
#   ./scripts/sync-upstream.sh --reset  # Hard reset main to upstream, then rebase local
#
# Workflow:
#   main   → tracks upstream/main (no local changes)
#   local  → rebased on main, contains all local customizations
#
# Local customizations (in separate commits on 'local' branch):
#   1. Git submodules: mcp-adapter, pubmed-search-mcp
#   2. Office extraction: office-extract.ts + core hooks
#   3. Dependencies: mammoth, xlsx
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# Ensure upstream remote exists
ensure_upstream() {
  if ! git remote get-url upstream &>/dev/null; then
    info "Adding upstream remote..."
    git remote add upstream https://github.com/openclaw/openclaw.git
  fi
}

show_status() {
  ensure_upstream
  local current_branch
  current_branch=$(git branch --show-current)
  echo ""
  info "Current branch: ${CYAN}${current_branch}${NC}"

  local main_hash upstream_hash local_hash
  main_hash=$(git rev-parse main 2>/dev/null || echo "n/a")
  upstream_hash=$(git rev-parse upstream/main 2>/dev/null || echo "n/a (run: git fetch upstream)")
  local_hash=$(git rev-parse local 2>/dev/null || echo "n/a")

  echo "  main:     ${main_hash:0:12}"
  echo "  upstream:  ${upstream_hash:0:12}"
  echo "  local:    ${local_hash:0:12}"

  if [[ "$main_hash" != "n/a" && "$upstream_hash" != "n/a" && "$upstream_hash" != *"run"* ]]; then
    local behind
    behind=$(git rev-list --count main..upstream/main 2>/dev/null || echo "?")
    if [[ "$behind" == "0" ]]; then
      ok "main is up to date with upstream"
    else
      warn "main is ${behind} commits behind upstream"
    fi
  fi

  if git rev-parse local &>/dev/null; then
    local local_ahead
    local_ahead=$(git rev-list --count main..local 2>/dev/null || echo "?")
    info "local has ${local_ahead} custom commit(s) on top of main"
  fi
  echo ""
}

do_sync() {
  ensure_upstream

  local current_branch
  current_branch=$(git branch --show-current)

  # 1. Fetch upstream
  info "Fetching upstream..."
  git fetch upstream main

  local behind
  behind=$(git rev-list --count main..upstream/main 2>/dev/null || echo "0")
  if [[ "$behind" == "0" ]]; then
    ok "Already up to date."
    return 0
  fi
  info "${behind} new commits from upstream"

  # 2. Update main to upstream/main
  info "Fast-forwarding main → upstream/main..."
  git checkout main --quiet
  if ! git merge --ff-only upstream/main 2>/dev/null; then
    err "main has diverged from upstream. Use --reset to force-align."
    git checkout "$current_branch" --quiet 2>/dev/null || true
    return 1
  fi
  ok "main updated"

  # 3. Rebase local on updated main
  if git rev-parse local &>/dev/null; then
    info "Rebasing local on updated main..."
    git checkout local --quiet
    if git rebase main; then
      ok "local rebased successfully"
    else
      warn "Rebase conflicts detected. Resolve them, then run:"
      echo "    git rebase --continue"
      echo ""
      echo "  After resolving, rebuild:"
      echo "    pnpm install && pnpm build"
      echo "    openclaw gateway restart"
      return 1
    fi

    # 4. Post-rebase: install & build
    info "Installing dependencies..."
    pnpm install 2>&1 | tail -3

    info "Building..."
    if pnpm build 2>&1 | tail -5; then
      ok "Build successful"
    else
      err "Build failed — check errors above"
      return 1
    fi

    # 5. Push to fork
    info "Pushing local to origin (fork)..."
    git push origin local --force-with-lease 2>&1 | tail -3
    ok "Pushed to origin/local"

    echo ""
    ok "Sync complete! Run 'openclaw gateway restart' to apply."
  else
    warn "No 'local' branch found. Create it with your customizations:"
    echo "    git checkout -b local"
    echo "    # ... commit your changes ..."
    git checkout "$current_branch" --quiet 2>/dev/null || true
  fi
}

do_reset() {
  ensure_upstream

  warn "This will hard-reset main to upstream/main."
  read -rp "Continue? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    return 1
  fi

  info "Fetching upstream..."
  git fetch upstream main

  info "Resetting main → upstream/main..."
  git checkout main --quiet
  git reset --hard upstream/main
  ok "main reset to upstream/main"

  if git rev-parse local &>/dev/null; then
    info "Rebasing local on reset main..."
    git checkout local --quiet
    if git rebase main; then
      ok "local rebased"
    else
      warn "Rebase conflicts. Resolve then: git rebase --continue"
      return 1
    fi
  fi
}

case "${1:-}" in
  --status|-s) show_status ;;
  --reset|-r)  do_reset ;;
  --help|-h)
    echo "Usage: $0 [--status|--reset|--help]"
    echo "  (no args)  Sync main with upstream, rebase local"
    echo "  --status   Show current sync state"
    echo "  --reset    Hard-reset main to upstream (destructive)"
    ;;
  *) do_sync ;;
esac
