#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

NAME="cursor-setup"
VERSION="1.1.0"
DESCRIPTION="Set up Cursor rules and commands symlinks for any workspace"
USAGE="
$NAME [options] [workspace-dir]

Sets up symlinks to Cursor rules and commands in the specified workspace directory.
Creates .cursor/rules/ and .cursor/commands/ with -local postfixed symlinks and updates .gitignore.

Options:
  -n, --dry-run       Print commands without executing
  -q, --quiet         Minimal output
  -v, --verbose       Increase logging output
  -f, --force         Skip confirmation and overwrites existing files
  -s, --save          Save workspace directory to .cursor-workspaces file
  -c, --cleanup       Remove orphaned *-local.* files that no longer have source files
      --ci            Disable colors and spinners (CI mode)
  -h, --help          Show help
      --version       Show version

Commands:
  update              Process all saved workspace directories
  list                List all saved workspace directories
  remove <workspace>  Remove workspace directory from saved list
  self-test           Run internal self-test

Examples:
  $NAME ~/projects/my-app           # Set up rules and commands for my-app workspace
  $NAME --save ~/projects/my-app    # Set up and save workspace for future runs
  $NAME --cleanup ~/projects/my-app # Set up and remove orphaned files
  $NAME update                      # Process all saved workspaces
  $NAME list                        # Show all saved workspaces
  $NAME remove ~/projects/old-app   # Remove workspace from saved list
  $NAME --dry-run .                 # Preview what would happen in current dir
  $NAME --force ~/old-project       # Overwrite existing setup
"

on_exit() { :; }
on_err()  { printf "✗ runtime failure on line %s\n" "$LINENO" >&2; exit 4; }
trap on_err ERR
trap on_exit EXIT

DRY_RUN=false
QUIET=false
VERBOSE=0
CI_MODE=false
FORCE=false
SAVE_WORKSPACE=false
CLEANUP=false

# Initialize colors early
BOLD="" RESET="" BLUE="" GREEN="" YELLOW="" RED=""

_init_colors() {
  if [[ -n "${CI:-}" || $CI_MODE == true ]]; then COLOR=false; else COLOR=true; fi
  if command -v tput >/dev/null 2>&1 && $COLOR; then
    BOLD=$(tput bold) || BOLD=""
    RESET=$(tput sgr0) || RESET=""
    BLUE=$(tput setaf 4) || BLUE=""
    GREEN=$(tput setaf 2) || GREEN=""
    YELLOW=$(tput setaf 3) || YELLOW=""
    RED=$(tput setaf 1) || RED=""
  else
    BOLD="" RESET="" BLUE="" GREEN="" YELLOW="" RED=""
  fi
}

_log() { local lvl="$1"; shift; $QUIET && [[ "$lvl" != ok && "$lvl" != err ]] && return 0; printf "%s\n" "$@"; }
info() { _log info "${BLUE}ℹ${RESET} $*"; }
ok()   { _log ok   "${GREEN}✓${RESET} $*"; }
warn() { _log warn "${YELLOW}⚠${RESET} $*"; }
err()  { _log err  "${RED}✗${RESET} $*" 1>&2; }
dbg()  { (( VERBOSE > 0 )) && printf "… %s\n" "$*" || true; }

run() {
  dbg "running: $*"
  if $DRY_RUN; then printf "+ %s\n" "$*"; else "$@"; fi
}

confirm() {
  $FORCE && return 0
  printf "%s? [y/N] " "$1"; read -r reply; [[ "$reply" == y || "$reply" == Y ]]
}

print_help() { printf "%s\n" "$USAGE"; }

parse_args() {
  local argv=()
  while (($#)); do case "$1" in
    -n|--dry-run) DRY_RUN=true;;
    -q|--quiet) QUIET=true;;
    -v|--verbose) ((VERBOSE++));;
    -f|--force) FORCE=true;;
    -s|--save) SAVE_WORKSPACE=true;;
    -c|--cleanup) CLEANUP=true;;
    --ci) CI_MODE=true;;
    -h|--help) printf "%s\n" "$USAGE"; exit 0;;
    --version) printf "%s %s\n" "$NAME" "$VERSION"; exit 0;;
    -*) # support stacked short flags like -nqv
        if [[ "$1" =~ ^-[a-zA-Z]{2,}$ ]]; then
          local i; for ((i=1;i<${#1};i++)); do parse_args "-${1:i:1}"; done
        else err "unknown option: $1"; exit 2; fi;;
    *) argv+=("$1");;
  esac; shift; done
  set -- "${argv[@]+"${argv[@]}"}"; ARGS=("$@")
}

validate_workspace() {
  local workspace_dir="$1"
  
  if [[ -z "$workspace_dir" ]]; then
    err "workspace directory cannot be empty"
    return 1
  fi
  
  if [[ ! -d "$workspace_dir" ]]; then
    err "workspace directory not found: $workspace_dir"
    return 1
  fi
  
  if [[ ! -w "$workspace_dir" ]]; then
    err "workspace directory not writable: $workspace_dir"
    return 1
  fi
  
  return 0
}

get_config_dir() {
  dirname "$(realpath "${BASH_SOURCE[0]}")"
}

get_workspaces_file() {
  printf "%s/.cursor-workspaces" "$(get_config_dir)"
}

resolve_workspace_path() {
  local input_path="$1"
  local require_exists="${2:-true}"
  
  if [[ -z "$input_path" ]]; then
    return 1
  fi
  
  # Try realpath first (works for existing paths)
  local resolved_path
  if resolved_path=$(realpath "$input_path" 2>/dev/null); then
    printf "%s" "$resolved_path"
    return 0
  fi
  
  # If path doesn't exist but we don't require it to exist, normalize manually
  if [[ "$require_exists" == "false" ]]; then
    if [[ "$input_path" = /* ]]; then
      printf "%s" "$input_path"
    else
      printf "%s/%s" "$(pwd)" "$input_path"
    fi
    return 0
  fi
  
  return 1
}

save_workspace() {
  local workspace_dir="$1"
  local workspaces_file
  workspaces_file=$(get_workspaces_file)
  
  # Resolve to absolute path
  workspace_dir=$(resolve_workspace_path "$workspace_dir") || {
    err "invalid workspace path: $1"
    return 1
  }
  
  # Check if already saved
  if [[ -f "$workspaces_file" ]] && grep -Fxq "$workspace_dir" "$workspaces_file" 2>/dev/null; then
    dbg "workspace already saved: $workspace_dir"
    return 0
  fi
  
  # Add to file
  run mkdir -p "$(dirname "$workspaces_file")"
  printf "%s\n" "$workspace_dir" | run tee -a "$workspaces_file" >/dev/null
  ok "Saved workspace: $workspace_dir"
}

load_workspaces() {
  local workspaces_file
  workspaces_file=$(get_workspaces_file)
  
  if [[ ! -f "$workspaces_file" ]]; then
    return 1
  fi
  
  # Filter out empty lines and comments, ensure paths exist
  local -a valid_workspaces=()
  while IFS= read -r workspace_dir; do
    [[ -n "$workspace_dir" && ! "$workspace_dir" =~ ^[[:space:]]*# ]] || continue
    if [[ -d "$workspace_dir" ]]; then
      valid_workspaces+=("$workspace_dir")
    else
      warn "saved workspace not found, skipping: $workspace_dir"
    fi
  done < "$workspaces_file"
  
  if (( ${#valid_workspaces[@]} == 0 )); then
    return 1
  fi
  
  printf "%s\n" "${valid_workspaces[@]}"
}

remove_workspace() {
  local workspace_to_remove="$1"
  local workspaces_file
  workspaces_file=$(get_workspaces_file)
  
  if [[ ! -f "$workspaces_file" ]]; then
    err "no saved workspaces found"
    return 1
  fi
  
  # Resolve path for comparison, allowing non-existent workspaces to be removed
  workspace_to_remove=$(resolve_workspace_path "$workspace_to_remove" false) || {
    err "invalid workspace path: $1"
    return 1
  }
  
  dbg "looking for workspace to remove: $workspace_to_remove"
  
  # Create temporary file without the workspace to remove
  local temp_file="${workspaces_file}.tmp"
  local found=false
  
  {
    while IFS= read -r workspace_dir; do
      [[ -n "$workspace_dir" ]] || continue
      dbg "comparing: '$workspace_dir' with '$workspace_to_remove'" >&2
      if [[ "$workspace_dir" != "$workspace_to_remove" ]]; then
        printf "%s\n" "$workspace_dir"
      else
        found=true
        dbg "found match, removing: $workspace_dir" >&2
      fi
    done < "$workspaces_file"
  } > "$temp_file"
  
  if $found; then
    run mv "$temp_file" "$workspaces_file"
    ok "Removed workspace: $workspace_to_remove"
  else
    run rm -f "$temp_file"
    err "workspace not found in saved list: $workspace_to_remove"
    return 1
  fi
}

cleanup_orphaned_files() {
  local source_dir="$1" target_dir="$2" type_name="$3"
  local orphaned_count=0
  
  if [[ ! -d "$target_dir" ]]; then
    return 0
  fi
  
  # Find all *-local.* files in target directory
  while IFS= read -r -d '' target_file; do
    local basename_file local_name source_file
    basename_file=$(basename "$target_file")
    
    # Extract original filename by removing -local suffix
    if [[ "$basename_file" =~ ^(.+)-local(\.|$) ]]; then
      local_name="${BASH_REMATCH[1]}"
      if [[ -n "${BASH_REMATCH[2]}" && "${BASH_REMATCH[2]}" != "." ]]; then
        local_name="${local_name}${BASH_REMATCH[2]}"
      fi
    else
      continue
    fi
    
    # Check if corresponding source file exists
    source_file="$source_dir/$local_name"
    if [[ ! -f "$source_file" ]]; then
      if $FORCE || confirm "Remove orphaned $type_name file: $basename_file"; then
        run rm -f -- "$target_file"
        ok "Removed orphaned $type_name: $basename_file"
        ((orphaned_count++))
      else
        warn "skipped orphaned file: $basename_file"
      fi
    fi
  done < <(find "$target_dir" -name "*-local.*" -type f -print0)
  
  if (( orphaned_count > 0 )); then
    ok "Cleaned up $orphaned_count orphaned $type_name file(s)"
  else
    dbg "No orphaned $type_name files found"
  fi
  
  return 0
}

setup_cursor_workspace() {
  local workspace_dir="$1"
  
  # Resolve and validate paths early
  workspace_dir=$(resolve_workspace_path "$workspace_dir") || {
    err "invalid workspace path: $1"
    return 1
  }
  
  validate_workspace "$workspace_dir" || return 1
  
  local config_source rules_source commands_source
  local rules_target commands_target gitignore_file
  
  config_source=$(get_config_dir)
  rules_source="$config_source/rules"
  commands_source="$config_source/commands"
  rules_target="$workspace_dir/.cursor/rules"
  commands_target="$workspace_dir/.cursor/commands"
  gitignore_file="$workspace_dir/.gitignore"
  
  info "Setting up Cursor workspace for: $workspace_dir"
  dbg "config source: $config_source"
  dbg "rules target: $rules_target"
  dbg "commands target: $commands_target"
  
  # Setup rules and commands
  local setup_count=0
  create_rule_symlinks "$rules_source" "$rules_target" && ((setup_count++))
  create_command_symlinks "$commands_source" "$commands_target" && ((setup_count++))
  
  if (( setup_count == 0 )); then
    err "no source directories found - nothing to set up"
    return 1
  fi
  
  # Cleanup orphaned files if requested
  if $CLEANUP; then
    info "Cleaning up orphaned files"
    cleanup_orphaned_files "$rules_source" "$rules_target" "rules"
    cleanup_orphaned_files "$commands_source" "$commands_target" "commands"
  fi
  
  # Update .gitignore
  update_gitignore "$gitignore_file"
  
  # Save workspace if requested
  if $SAVE_WORKSPACE; then
    save_workspace "$workspace_dir"
  fi
  
  ok "Cursor workspace setup complete for: $workspace_dir"
  
  # Show summary
  if (( VERBOSE > 0 )); then
    show_summary "$rules_target" "$commands_target" "$gitignore_file"
  fi
}

create_local_symlink() {
  local source_file="$1" target_dir="$2" type_name="$3"
  local basename_file target_link local_name
  
  basename_file=$(basename "$source_file")
  
  # Add -local postfix before file extension
  if [[ "$basename_file" =~ \. ]]; then
    local_name="${basename_file%.*}-local.${basename_file##*.}"
  else
    local_name="${basename_file}-local"
  fi
  target_link="$target_dir/$local_name"
  
  # Handle existing files
  if [[ -e "$target_link" ]]; then
    if $FORCE; then
      run rm -f -- "$target_link"
      dbg "removed existing: $target_link"
    else
      warn "skipping existing file: $target_link (use --force to overwrite)"
      return 1
    fi
  fi
  
  run ln -s "$source_file" "$target_link"
  ok "Linked $type_name: $basename_file -> $local_name"
  return 0
}

create_rule_symlinks() {
  local source_dir="$1" target_dir="$2"
  
  info "Setting up Cursor rules"
  
  if [[ ! -d "$source_dir" ]]; then
    warn "rules source directory not found: $source_dir"
    return 1
  fi
  
  if [[ -d "$target_dir" && ! $FORCE ]]; then
    if ! confirm "Directory $target_dir already exists. Continue"; then
      warn "aborted rules setup"
      return 1
    fi
  fi
  
  run mkdir -p "$target_dir"
  ok "Created rules directory: $target_dir"
  
  local link_count=0 file_count=0 source_file
  while IFS= read -r -d '' source_file; do
    ((file_count++))
    if create_local_symlink "$source_file" "$target_dir" "rules"; then
      ((link_count++))
    fi
  done < <(find "$source_dir" -name "*.mdc" -type f -print0)
  
  if (( file_count == 0 )); then
    warn "No rules files found in $source_dir"
  elif (( link_count == 0 )); then
    warn "No rules files could be linked (all may already exist, use --force to overwrite)"
  fi
  
  return 0
}

create_command_symlinks() {
  local source_dir="$1" target_dir="$2"
  
  info "Setting up Cursor commands"
  
  if [[ ! -d "$source_dir" ]]; then
    warn "commands source directory not found: $source_dir"
    return 1
  fi
  
  if [[ -d "$target_dir" && ! $FORCE ]]; then
    if ! confirm "Directory $target_dir already exists. Continue"; then
      warn "aborted commands setup"
      return 1
    fi
  fi
  
  run mkdir -p "$target_dir"
  ok "Created commands directory: $target_dir"
  
  local link_count=0 file_count=0 source_file
  while IFS= read -r -d '' source_file; do
    ((file_count++))
    if create_local_symlink "$source_file" "$target_dir" "commands"; then
      ((link_count++))
    fi
  done < <(find "$source_dir" -type f -print0)
  
  if (( file_count == 0 )); then
    warn "No commands files found in $source_dir"
  elif (( link_count == 0 )); then
    warn "No commands files could be linked (all may already exist, use --force to overwrite)"
  fi
  
  return 0
}

update_gitignore() {
  local gitignore_file="$1"
  local -a entries=(
    ".cursor/rules/*-local.mdc"
    ".cursor/commands/*-local.*"
  )
  
  # Use single cursor section approach
  local cursor_section="# Cursor symlinked files"
  local existing_entries=()
  local new_entries=()
  
  # Check existing entries if file exists
  if [[ -f "$gitignore_file" ]]; then
    for entry in "${entries[@]}"; do
      if grep -Fxq "$entry" "$gitignore_file" 2>/dev/null; then
        existing_entries+=("$entry")
      else
        new_entries+=("$entry")
      fi
    done
  else
    new_entries=("${entries[@]}")
  fi
  
  # Add new entries if needed
  if (( ${#new_entries[@]} > 0 )); then
    if [[ -f "$gitignore_file" ]]; then
      info "Adding ${#new_entries[@]} cursor entries to .gitignore"
      {
        [[ ${#existing_entries[@]} -eq 0 ]] && printf "\n%s\n" "$cursor_section"
        printf "%s\n" "${new_entries[@]}"
      } | run tee -a "$gitignore_file" >/dev/null
    else
      info "Creating .gitignore with cursor entries"
      {
        printf "%s\n" "$cursor_section"
        printf "%s\n" "${entries[@]}"
      } | run tee "$gitignore_file" >/dev/null
    fi
    ok "Updated .gitignore"
  else
    dbg ".gitignore already contains all cursor entries"
  fi
}

show_summary() {
  local rules_target="$1" commands_target="$2" gitignore_file="$3"
  
  info "Summary:"
  
  if [[ -d "$rules_target" ]]; then
    local rule_count
    rule_count=$(find "$rules_target" -name "*-local.mdc" -type l 2>/dev/null | wc -l | tr -d ' ')
    printf "  Rules directory: %s (%s rules)\n" "$rules_target" "$rule_count"
  fi
  
  if [[ -d "$commands_target" ]]; then
    local command_count
    command_count=$(find "$commands_target" -name "*-local.*" -type l 2>/dev/null | wc -l | tr -d ' ')
    printf "  Commands directory: %s (%s commands)\n" "$commands_target" "$command_count"
  fi
  
  printf "  Gitignore updated: %s\n" "$gitignore_file"
}

cmd_list_workspaces() {
  local workspaces_file
  workspaces_file=$(get_workspaces_file)
  
  if [[ ! -f "$workspaces_file" ]]; then
    info "No saved workspaces found"
    return 0
  fi
  
  info "Saved workspaces:"
  local count=0
  while IFS= read -r workspace_dir; do
    [[ -n "$workspace_dir" && ! "$workspace_dir" =~ ^[[:space:]]*# ]] || continue
    if [[ -d "$workspace_dir" ]]; then
      printf "  ✓ %s\n" "$workspace_dir"
      ((count++))
    else
      printf "  ✗ %s ${YELLOW}(not found)${RESET}\n" "$workspace_dir"
      ((count++))
    fi
  done < "$workspaces_file"
  
  if (( count == 0 )); then
    info "No workspaces in file"
  else
    printf "\nTotal: %d workspace%s\n" "$count" "$([[ $count -eq 1 ]] || printf "s")"
  fi
}

cmd_remove_workspace() {
  local workspace_to_remove="$1"
  
  if [[ -z "$workspace_to_remove" ]]; then
    err "workspace directory required for remove command"
    printf "Usage: %s remove <workspace-dir>\n" "$NAME"
    exit 2
  fi
  
  if ! remove_workspace "$workspace_to_remove"; then
    exit 1
  fi
}

cmd_process_all_workspaces() {
  local -a workspaces
  local workspace_list
  workspace_list=$(load_workspaces 2>/dev/null) || {
    err "no saved workspaces found"
    printf "Use '%s --save <workspace-dir>' to save workspaces or '%s <workspace-dir>' to process a single workspace.\n" "$NAME" "$NAME"
    exit 1
  }
  
  # Convert workspace list to array
  while IFS= read -r workspace_dir; do
    [[ -n "$workspace_dir" ]] && workspaces+=("$workspace_dir")
  done <<< "$workspace_list"
  
  info "Processing ${#workspaces[@]} saved workspace(s)"
  
  local workspace_dir failed=0 processed=0
  for workspace_dir in "${workspaces[@]}"; do
    printf "\n"
    info "Processing workspace: $workspace_dir"
    
    if setup_cursor_workspace "$workspace_dir"; then
      ((processed++))
    else
      ((failed++))
      warn "failed to process workspace: $workspace_dir"
    fi
  done
  
  printf "\n"
  if (( failed > 0 )); then
    warn "Processed $processed workspace(s), failed $failed"
    exit 1
  else
    ok "Successfully processed all $processed workspace(s)"
  fi
}

cmd_self_test() {
  info "Running self-test"
  
  # Check dependencies
  command -v bash >/dev/null || { err "bash missing"; exit 3; }
  command -v realpath >/dev/null || { err "realpath missing"; exit 3; }
  
  # Check shellcheck if available
  if command -v shellcheck >/dev/null; then
    ok "shellcheck available"
  else
    warn "shellcheck missing"
  fi
  
  # Test dry-run
  DRY_RUN=true run echo "test" >/dev/null
  ok "dry-run working"
  
  # Test sources exist
  local config_source
  config_source=$(get_config_dir)
  local rules_source="$config_source/rules"
  local commands_source="$config_source/commands"
  local found_sources=0
  
  if [[ -d "$rules_source" ]]; then
    local rule_count
    rule_count=$(find "$rules_source" -name "*.mdc" -type f | wc -l | tr -d ' ')
    ok "rules source found: $rules_source ($rule_count rules)"
    ((found_sources++))
  else
    warn "rules source not found: $rules_source"
  fi
  
  if [[ -d "$commands_source" ]]; then
    local command_count
    command_count=$(find "$commands_source" -type f | wc -l | tr -d ' ')
    ok "commands source found: $commands_source ($command_count commands)"
    ((found_sources++))
  else
    warn "commands source not found: $commands_source"
  fi
  
  # At least one source must exist
  if (( found_sources == 0 )); then
    err "neither rules nor commands source directories found"
    exit 4
  fi
  
  # Test workspace file functions
  local test_workspace="/tmp/test-cursor-workspace-$$"
  local workspaces_file
  workspaces_file=$(get_workspaces_file)
  local backup_file="${workspaces_file}.backup.$$"
  
  # Backup existing workspaces file if it exists
  if [[ -f "$workspaces_file" ]]; then
    run cp "$workspaces_file" "$backup_file"
  fi
  
  # Test save/load/remove functions
  DRY_RUN=false
  if mkdir -p "$test_workspace" 2>/dev/null && save_workspace "$test_workspace" >/dev/null 2>&1; then
    if load_workspaces | grep -q "$test_workspace" 2>/dev/null; then
      if remove_workspace "$test_workspace" >/dev/null 2>&1; then
        ok "workspace management functions working"
      else
        warn "workspace remove function failed"
      fi
    else
      warn "workspace load function failed"
    fi
  else
    warn "workspace save function failed"
  fi
  
  # Cleanup
  run rm -rf "$test_workspace" 2>/dev/null || true
  if [[ -f "$backup_file" ]]; then
    run mv "$backup_file" "$workspaces_file"
  else
    run rm -f "$workspaces_file" 2>/dev/null || true
  fi
  
  ok "self-test passed"
}

main() {
  _init_colors
  parse_args "$@"
  
  local cmd="${ARGS[0]-}"
  
  case "$cmd" in
    update)
      cmd_process_all_workspaces
      ;;
    list)
      cmd_list_workspaces
      ;;
    remove)
      cmd_remove_workspace "${ARGS[1]-}"
      ;;
    self-test)
      cmd_self_test
      ;;
    ""|-h|--help)
      print_help
      ;;
    *)
      # Treat first argument as workspace directory
      if ! setup_cursor_workspace "$cmd"; then
        exit 1
      fi
      ;;
  esac
}

main "$@"
