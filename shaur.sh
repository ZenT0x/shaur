#!/bin/bash

# Name: Shaur - Simple Helper for AUR packages
# Version: 1.0
# Description: Interactive script to manage AUR repositories

# Define the folder containing AUR repos
BUILD_DIR="$HOME/builds"

# Define a temporary directory to store statuses
TEMP_DIR="/tmp/shaur_$$"
mkdir -p "$TEMP_DIR"

# Variable to store background process PID
BACKGROUND_PID=""

# Colors for better readability
COLOR_RESET="\033[0m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_RED="\033[0;31m"
COLOR_BLUE="\033[0;34m"
COLOR_CYAN="\033[0;36m"
COLOR_GRAY="\033[0;37m"

# Function to detect color support
detect_color_support() {
    # Check if colors should be disabled by force
    if [ -n "$NO_COLOR" ] || [ "$TERM" = "dumb" ]; then
        return 1
    fi
    
    # Check if terminal supports colors
    if [ -t 1 ]; then
        # Check for true color support
        if [ "$COLORTERM" = "truecolor" ] || [ "$COLORTERM" = "24bit" ]; then
            return 0
        fi
        
        # Check for at least 8 colors
        if [ -n "$TERM" ] && tput colors 2>/dev/null >/dev/null; then
            if [ "$(tput colors)" -ge 8 ]; then
                return 0
            fi
        fi
        
        # Check common color-supporting terminal types
        case "$TERM" in
            xterm*|rxvt*|screen*|tmux*|linux*|vt100*|ansi)
                return 0
                ;;
        esac
    fi
    
    return 1
}

# Enable or disable color output based on terminal support
USE_COLORS=false
if detect_color_support; then
    USE_COLORS=true
fi

# Function to print colored text
print_color() {
    local color="$1"
    local text="$2"
    
    if [ "$USE_COLORS" = true ]; then
        echo -e "${color}${text}${COLOR_RESET}"
    else
        echo "$text"
    fi
}

# Check if the builds directory exists
if [ ! -d "$BUILD_DIR" ]; then
    print_color "$COLOR_RED" "Error: The directory $BUILD_DIR does not exist."
    exit 1
fi

# Check if git is installed
if ! command -v git &> /dev/null; then
    print_color "$COLOR_RED" "Error: Git is not installed. Please install git to use this script."
    exit 1
fi

# Check if makepkg is installed
if ! command -v makepkg &> /dev/null; then
    print_color "$COLOR_YELLOW" "Warning: makepkg is not installed. Package building functions will not work."
fi

# Cleanup function on exit
cleanup() {
    # Don't print cleanup message if script is exiting normally
    local exit_type="${1:-normal}"
    
    if [ "$exit_type" != "silent" ]; then
        print_color "$COLOR_BLUE" "Cleaning up..."
    fi
    
    # Kill background process if it's running
    if [ -n "$BACKGROUND_PID" ] && ps -p $BACKGROUND_PID > /dev/null 2>&1; then
        if [ "$exit_type" != "silent" ]; then
            print_color "$COLOR_BLUE" "Terminating background process..."
        fi
        kill $BACKGROUND_PID &>/dev/null
        # Give it a moment to terminate cleanly
        sleep 0.2
    fi
    
    # Remove temporary directory
    rm -rf "$TEMP_DIR" 2>/dev/null
    
    # Reset terminal settings if needed
    if [ -n "$OLD_STTY_CFG" ]; then
        stty "$OLD_STTY_CFG" 2>/dev/null || true
    fi
    
    # Clear screen on normal exit
    if [ "$exit_type" = "normal" ]; then
        clear
    fi
    
    exit 0
}

# Store original stty settings
OLD_STTY_CFG=$(stty -g 2>/dev/null || echo "")

# Register cleanup function to run on exit
trap 'cleanup normal' EXIT
trap 'cleanup interrupted' INT TERM

# Function to find repositories and count those without PKGBUILD
find_repos() {
    repos=()
    repos_without_pkgbuild=0
    
    # Use find to handle special characters in filenames
    while IFS= read -r -d $'\0' dir; do
        if [ -d "$dir/.git" ]; then
            repo_name=$(basename "$dir")
            repos+=("$repo_name")
            
            # Check if PKGBUILD exists
            if [ ! -f "$dir/PKGBUILD" ]; then
                ((repos_without_pkgbuild++))
            fi
        fi
    done < <(find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    
    # Sort repositories alphabetically
    IFS=$'\n' repos=($(sort <<<"${repos[*]}"))
    unset IFS
}

# Function to calculate the sync status of a repository
calculate_repo_sync_status() {
    local repo="$1"
    local repo_path="$BUILD_DIR/$repo"
    
    # Check if directory exists
    if [ ! -d "$repo_path" ]; then
        echo "[Not found]"
        return
    fi
    
    # Change to repository directory
    cd "$repo_path" || return
    
    # Check if repo is a git repository
    if [ ! -d ".git" ]; then
        echo "[Not a git repo]"
        return
    fi
    
    # Check if there are local changes
    if git status -s 2>/dev/null | grep -q .; then
        echo "[Modified]"
        return
    fi
    
    # Check if the repo is behind
    local branch=$(git branch --show-current 2>/dev/null)
    local remote_branch=$(git for-each-ref --format='%(upstream:short)' "refs/heads/$branch" 2>/dev/null)
    
    if [ -n "$remote_branch" ]; then
        # Using --quiet to reduce output
        git fetch --quiet 2>/dev/null || {
            echo "[Fetch failed]"
            return
        }
        
        local behind=$(git rev-list --count $branch..$remote_branch 2>/dev/null || echo "0")
        local ahead=$(git rev-list --count $remote_branch..$branch 2>/dev/null || echo "0")
        
        if [ "$behind" -gt 0 ]; then
            echo "[Behind $behind]"
        elif [ "$ahead" -gt 0 ]; then
            echo "[Ahead $ahead]"
        else
            echo "[Up to date]"
        fi
    else
        echo "[No remote]"
    fi
}

# Function to preload all statuses in background
preload_all_repo_statuses() {
    # Initialize all statuses with "Loading..."
    for repo in "${repos[@]}"; do
        echo "[Loading...]" > "$TEMP_DIR/$repo.status" 2>/dev/null
    done
    
    # Create a file to indicate that loading is in progress
    echo "0" > "$TEMP_DIR/loading_progress" 2>/dev/null
    rm -f "$TEMP_DIR/loading_status" 2>/dev/null
    
    # Launch calculation of statuses in background
    (
        # Store a marker to indicate this process is running
        echo $$ > "$TEMP_DIR/background_pid" 2>/dev/null
        
        total=${#repos[@]}
        count=0
        
        for repo in "${repos[@]}"; do
            # Check if the directory still exists (in case the script was terminated)
            if [ ! -d "$TEMP_DIR" ]; then
                exit 0
            fi
            
            status=$(calculate_repo_sync_status "$repo")
            
            # Check again before writing
            if [ -d "$TEMP_DIR" ]; then
                echo "$status" > "$TEMP_DIR/$repo.status" 2>/dev/null
                
                ((count++))
                echo "$count" > "$TEMP_DIR/loading_progress" 2>/dev/null
            else
                exit 0
            fi
        done
        
        # Indicate that loading is complete
        if [ -d "$TEMP_DIR" ]; then
            echo "done" > "$TEMP_DIR/loading_status" 2>/dev/null
        fi
    ) &
    
    # Store the background process PID
    BACKGROUND_PID=$!
    
    # Also write it to a file in case we need it later
    echo $BACKGROUND_PID > "$TEMP_DIR/main_background_pid" 2>/dev/null
}

# Function to check if loading is done
is_loading_done() {
    if [ -f "$TEMP_DIR/loading_status" ] && [ "$(cat "$TEMP_DIR/loading_status" 2>/dev/null)" == "done" ]; then
        return 0  # True in bash terms
    else
        return 1  # False in bash terms
    fi
}

# Function to get loading progress
get_loading_progress() {
    if [ -f "$TEMP_DIR/loading_progress" ]; then
        cat "$TEMP_DIR/loading_progress" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Function to get repository status
get_repo_sync_status() {
    local repo="$1"
    if [ -f "$TEMP_DIR/$repo.status" ]; then
        cat "$TEMP_DIR/$repo.status" 2>/dev/null || echo "[Unknown]"
    else
        echo "[Unknown]"
    fi
}

# Function to get colored status
get_colored_status() {
    local status="$1"
    
    case "$status" in
        "[Up to date]")
            print_color "$COLOR_GREEN" "$status"
            ;;
        "[Behind"*)
            print_color "$COLOR_RED" "$status"
            ;;
        "[Ahead"*)
            print_color "$COLOR_YELLOW" "$status"
            ;;
        "[Modified]")
            print_color "$COLOR_YELLOW" "$status"
            ;;
        "[Loading...]")
            print_color "$COLOR_BLUE" "$status"
            ;;
        "[No remote]")
            print_color "$COLOR_GRAY" "$status"
            ;;
        *)
            echo "$status"
            ;;
    esac
}

# Function to update repository status after a Git operation
update_repo_status() {
    local repo="$1"
    local status=$(calculate_repo_sync_status "$repo")
    echo "$status" > "$TEMP_DIR/$repo.status" 2>/dev/null
}

# Function to wait for any key
wait_for_key() {
    local prompt="$1"
    echo ""
    print_color "$COLOR_CYAN" "$prompt"
    read -n 1 -s
}

# Function to display main menu and handle selection
show_main_menu() {
    local refresh_required=true
    
    while true; do
        # Main display loop
        if $refresh_required || ! is_loading_done; then
            clear
            print_color "$COLOR_GREEN" "Shaur - AUR Repository Manager"
            print_color "$COLOR_BLUE" "(${#repos[@]} repos found, $repos_without_pkgbuild without PKGBUILD)"
            
            # Check loading status
            if is_loading_done; then
                print_color "$COLOR_GREEN" "Repository statuses: Loaded"
                refresh_required=false
            else
                progress=$(get_loading_progress)
                print_color "$COLOR_YELLOW" "Repository statuses: Loading... ($progress/${#repos[@]})"
                refresh_required=true
            fi
            
            echo ""
            print_color "$COLOR_CYAN" "Available actions:"
            echo "1. List all repositories"
            echo "2. Select all repositories"
            echo "3. Select a specific repository"
            echo "4. Exit"
            echo ""
            print_color "$COLOR_CYAN" "Press a key to select an option..."
        fi
        
        # Read user input with timeout to allow refreshing
        if ! is_loading_done; then
            # If still loading, use a short timeout to keep refreshing
            read -t 0.5 -n 1 choice
            if [ $? -gt 128 ]; then
                # Timeout occurred, refresh the screen
                continue
            fi
        else
            # If loading is done, wait indefinitely for input
            read -n 1 -s choice
            # After any action, we want to refresh at least once
            refresh_required=true
        fi
        
        case $choice in
            1)
                list_repos
                refresh_required=true
                ;;
            2)
                select_all_repos_menu
                refresh_required=true
                ;;
            3)
                select_repo_interactive
                refresh_required=true
                ;;
            4|q|Q)
                cleanup "normal"  # This will call exit
                ;;
        esac
    done
}

# Function to refresh repository statuses (called internally, not from menu)
refresh_repo_statuses() {
    # First, terminate any existing background process
    if [ -n "$BACKGROUND_PID" ] && ps -p $BACKGROUND_PID > /dev/null 2>&1; then
        kill $BACKGROUND_PID 2>/dev/null
        sleep 0.1  # Short pause to let the process terminate
    fi
    
    # Remove loading completion indicator
    rm -f "$TEMP_DIR/loading_status" 2>/dev/null
    echo "0" > "$TEMP_DIR/loading_progress" 2>/dev/null
    
    # Reset all statuses
    for repo in "${repos[@]}"; do
        echo "[Loading...]" > "$TEMP_DIR/$repo.status" 2>/dev/null
    done
    
    # Launch new background process for status update
    preload_all_repo_statuses
}

# Function to list all repositories
list_repos() {
    clear
    print_color "$COLOR_GREEN" "List of ${#repos[@]} repositories:"
    echo ""
    
    for i in "${!repos[@]}"; do
        repo="${repos[$i]}"
        status_text=$(get_repo_sync_status "$repo")
        
        # Display repo number and name
        printf "%3d. %-40s " "$((i+1))" "$repo"
        
        # Display status with color
        get_colored_status "$status_text"
        
        # Add PKGBUILD indicator
        if [ ! -f "$BUILD_DIR/$repo/PKGBUILD" ]; then
            print_color "$COLOR_RED" "   (no PKGBUILD)"
        fi
    done
    
    echo ""
    wait_for_key "Press any key to return to menu..."
}

# Function to extract a variable from PKGBUILD
extract_pkgbuild_var() {
    local pkgbuild="$1"
    local var_name="$2"
    grep -oP "^$var_name=\K.*" "$pkgbuild" 2>/dev/null | head -1 | tr -d "\"'" || echo "N/A"
}

# Function to get repository information
get_repo_info() {
    local repo="$1"
    local repo_path="$BUILD_DIR/$repo"
    local status_text=$(get_repo_sync_status "$repo")
    
    print_color "$COLOR_GREEN" "Repository information: $repo"
    get_colored_status "$status_text"
    print_color "$COLOR_BLUE" "------------------------"
    
    # Check if repository exists
    if [ ! -d "$repo_path" ]; then
        print_color "$COLOR_RED" "Repository directory not found!"
        return
    fi
    
    # Repository size
    local size=$(du -sh "$repo_path" 2>/dev/null | cut -f1)
    echo "Repository size: $size"
    
    # Last commit status
    cd "$repo_path" || return
    local last_commit=$(git log -1 --format="%cd" --date=relative 2>/dev/null || echo 'N/A')
    echo "Last commit: $last_commit"
    
    # Branch info
    local branch=$(git branch --show-current 2>/dev/null)
    if [ -n "$branch" ]; then
        echo "Current branch: $branch"
    fi
    
    # PKGBUILD information
    local pkgbuild="$repo_path/PKGBUILD"
    if [ -f "$pkgbuild" ]; then
        echo ""
        print_color "$COLOR_GREEN" "PKGBUILD information:"
        print_color "$COLOR_BLUE" "------------------------"
        
        local pkgname=$(extract_pkgbuild_var "$pkgbuild" "pkgname")
        local pkgver=$(extract_pkgbuild_var "$pkgbuild" "pkgver")
        local pkgrel=$(extract_pkgbuild_var "$pkgbuild" "pkgrel")
        local pkgdesc=$(extract_pkgbuild_var "$pkgbuild" "pkgdesc")
        
        echo "Name: $pkgname"
        if [ "$pkgver" != "N/A" ] && [ "$pkgrel" != "N/A" ]; then
            echo "Version: $pkgver-$pkgrel"
        elif [ "$pkgver" != "N/A" ]; then
            echo "Version: $pkgver"
        fi
        echo "Description: $pkgdesc"
        
        # Try to extract dependencies
        if grep -q "^depends=" "$pkgbuild" 2>/dev/null; then
            local deps=$(grep -oP "^depends=\(\K[^)]*" "$pkgbuild" 2>/dev/null | tr -d "\"'" | tr '\n' ' ' || echo 'N/A')
            echo "Dependencies: $deps"
        fi
    else
        echo ""
        print_color "$COLOR_RED" "No PKGBUILD found in this repository"
    fi
}

# Function to display menu for all repositories
select_all_repos_menu() {
    while true; do
        clear
        print_color "$COLOR_GREEN" "Select an action for all repositories:"
        echo ""
        echo "1. git pull"
        echo "2. PKGEXT='.pkg.tar' makepkg -sirc"
        echo "3. git clean -dfx"
        echo "4. Execute all actions (pull, makepkg, clean)"
        echo "5. Return to main menu"
        echo ""
        print_color "$COLOR_CYAN" "Press a key to select an option..."
        
        read -n 1 -s action_choice
        
        case $action_choice in
            1)
                run_git_pull_all
                ;;
            2)
                run_makepkg_all
                ;;
            3)
                run_git_clean_all
                ;;
            4)
                run_all_actions
                ;;
            5|q|Q)
                return
                ;;
        esac
    done
}

# Functions to execute actions on all repositories
run_git_pull_all() {
    clear
    print_color "$COLOR_GREEN" "Executing git pull on all repositories..."
    echo ""
    
    for repo in "${repos[@]}"; do
        print_color "$COLOR_BLUE" "=== $repo: git pull ==="
        cd "$BUILD_DIR/$repo" || continue
        git pull
        update_repo_status "$repo"  # Update status after operation
        echo ""
    done
    
    echo ""
    print_color "$COLOR_GREEN" "Operation completed."
    wait_for_key "Press any key to return to menu..."
}

run_makepkg_all() {
    clear
    print_color "$COLOR_GREEN" "Executing PKGEXT='.pkg.tar' makepkg -sirc on all repositories..."
    echo ""
    
    for repo in "${repos[@]}"; do
        print_color "$COLOR_BLUE" "=== $repo: makepkg ==="
        cd "$BUILD_DIR/$repo" || continue
        
        if [ -f "PKGBUILD" ]; then
            PKGEXT='.pkg.tar' makepkg -sirc
            update_repo_status "$repo"  # Update status after operation
        else
            print_color "$COLOR_RED" "No PKGBUILD found, cannot execute makepkg."
        fi
        echo ""
        
        print_color "$COLOR_CYAN" "Continue with next repository? (Press any key to continue, q to return to menu)"
        read -n 1 -s continue_choice
        if [[ "$continue_choice" == "q" || "$continue_choice" == "Q" ]]; then
            break
        fi
    done
    
    echo ""
    print_color "$COLOR_GREEN" "Operation completed."
    wait_for_key "Press any key to return to menu..."
}

run_git_clean_all() {
    clear
    print_color "$COLOR_GREEN" "Executing git clean -dfx on all repositories..."
    echo ""
    
    for repo in "${repos[@]}"; do
        print_color "$COLOR_BLUE" "=== $repo: git clean -dfx ==="
        cd "$BUILD_DIR/$repo" || continue
        git clean -dfx
        update_repo_status "$repo"  # Update status after operation
        echo ""
    done
    
    echo ""
    print_color "$COLOR_GREEN" "Operation completed."
    wait_for_key "Press any key to return to menu..."
}

run_all_actions() {
    clear
    print_color "$COLOR_GREEN" "Executing all actions on all repositories..."
    echo ""
    
    for repo in "${repos[@]}"; do
        print_color "$COLOR_BLUE" "=== Processing $repo ==="
        cd "$BUILD_DIR/$repo" || continue
        
        echo "Executing git pull..."
        git pull
        
        if [ -f "PKGBUILD" ]; then
            echo "Executing PKGEXT='.pkg.tar' makepkg -sirc..."
            PKGEXT='.pkg.tar' makepkg -sirc
        else
            print_color "$COLOR_RED" "No PKGBUILD found, cannot execute makepkg."
        fi
        
        echo "Executing git clean -dfx..."
        git clean -dfx
        
        update_repo_status "$repo"  # Update status after all operations
        
        print_color "$COLOR_BLUE" "=== Finished processing $repo ==="
        echo ""
        
        print_color "$COLOR_CYAN" "Continue with next repository? (Press any key to continue, q to return to menu)"
        read -n 1 -s continue_choice
        if [[ "$continue_choice" == "q" || "$continue_choice" == "Q" ]]; then
            break
        fi
    done
    
    echo ""
    print_color "$COLOR_GREEN" "Operation completed."
    wait_for_key "Press any key to return to menu..."
}

# Function for interactive repository selection with arrows
select_repo_interactive() {
    if [ ${#repos[@]} -eq 0 ]; then
        print_color "$COLOR_RED" "No repositories available."
        wait_for_key "Press any key to continue..."
        return
    fi
    
    local index=0
    local key
    
    # Configure terminal for key reading
    OLD_STTY_CFG=$(stty -g 2>/dev/null || echo "")
    stty -echo -icanon min 1 time 0 2>/dev/null || true
    
    while true; do
        clear
        print_color "$COLOR_GREEN" "Repository navigation (${index+1}/${#repos[@]})"
        echo ""
        print_color "$COLOR_CYAN" "Use arrows ← → to navigate"
        print_color "$COLOR_CYAN" "Enter to select, q to quit"
        echo ""
        
        # Display current repository
        repo="${repos[$index]}"
        status_text=$(get_repo_sync_status "$repo")
        
        printf "→ %-40s " "$repo"
        get_colored_status "$status_text"
        
        if [ ! -f "$BUILD_DIR/$repo/PKGBUILD" ]; then
            print_color "$COLOR_RED" "   (no PKGBUILD)"
        fi
        
        # Read a key
        key=$(dd bs=1 count=1 2>/dev/null)
        
        # Process escape sequences
        if [[ $key = $'\e' ]]; then
            read -t 0.1 -n 2 seq
            
            if [[ $seq = '[C' ]]; then  # Right arrow
                ((index = (index + 1) % ${#repos[@]}))
            elif [[ $seq = '[D' ]]; then  # Left arrow
                ((index = (index - 1 + ${#repos[@]}) % ${#repos[@]}))
            fi
        elif [[ $key = '' ]]; then  # Enter key
            stty $OLD_STTY_CFG 2>/dev/null || true  # Restore terminal configuration
            process_selected_repo "$index"
            # Reconfigure terminal again when we return
            stty -echo -icanon min 1 time 0 2>/dev/null || true
        elif [[ $key = 'q' || $key = 'Q' ]]; then  # q key to quit
            stty $OLD_STTY_CFG 2>/dev/null || true  # Restore terminal configuration
            return
        fi
    done
    
    # Ensure terminal is restored before returning
    stty $OLD_STTY_CFG 2>/dev/null || true
}

# Function to process selected repository - displays actions menu for a specific repo
process_selected_repo() {
    local index=$1
    local repo=${repos[$index]}
    local return_to_actions=true
    
    while $return_to_actions; do
        clear
        # Display repository information
        get_repo_info "$repo"
        
        echo ""
        print_color "$COLOR_GREEN" "=== Actions for repository $repo ==="
        echo ""
        echo "1. git pull"
        echo "2. PKGEXT='.pkg.tar' makepkg -sirc"
        echo "3. git clean -dfx"
        echo "4. Execute all actions (pull, makepkg, clean)"
        echo "5. Return to repository selection"
        echo ""
        print_color "$COLOR_CYAN" "Press a key to select an option..."
        
        read -n 1 -s action_choice
        
        case $action_choice in
            1)
                clear
                print_color "$COLOR_BLUE" "=== $repo: git pull ==="
                cd "$BUILD_DIR/$repo" || {
                    print_color "$COLOR_RED" "Failed to change to repository directory."
                    wait_for_key "Press any key to return to actions..."
                    continue
                }
                git pull
                update_repo_status "$repo"  # Update status after operation
                sleep 0.5
                ;;
            2)
                clear
                print_color "$COLOR_BLUE" "=== $repo: PKGEXT='.pkg.tar' makepkg -sirc ==="
                cd "$BUILD_DIR/$repo" || {
                    print_color "$COLOR_RED" "Failed to change to repository directory."
                    wait_for_key "Press any key to return to actions..."
                    continue
                }
                if [ -f "PKGBUILD" ]; then
                    PKGEXT='.pkg.tar' makepkg -sirc
                    update_repo_status "$repo"  # Update status after operation
                else
                    print_color "$COLOR_RED" "No PKGBUILD found, cannot execute makepkg."
                    wait_for_key "Press any key to return to actions..."
                    continue
                fi
                sleep 0.5
                ;;
            3)
                clear
                print_color "$COLOR_BLUE" "=== $repo: git clean -dfx ==="
                cd "$BUILD_DIR/$repo" || {
                    print_color "$COLOR_RED" "Failed to change to repository directory."
                    wait_for_key "Press any key to return to actions..."
                    continue
                }
                git clean -dfx
                update_repo_status "$repo"  # Update status after operation
                echo "Cleaned"
                sleep 0.5
                ;;
            4)
                clear
                print_color "$COLOR_BLUE" "=== Executing all actions on $repo ==="
                cd "$BUILD_DIR/$repo" || {
                    print_color "$COLOR_RED" "Failed to change to repository directory."
                    wait_for_key "Press any key to return to actions..."
                    continue
                }
                
                print_color "$COLOR_YELLOW" "Executing git pull..."
                git pull
                
                if [ -f "PKGBUILD" ]; then
                    print_color "$COLOR_YELLOW" "Executing PKGEXT='.pkg.tar' makepkg -sirc..."
                    PKGEXT='.pkg.tar' makepkg -sirc
                else
                    print_color "$COLOR_RED" "No PKGBUILD found, cannot execute makepkg."
                fi
                
                print_color "$COLOR_YELLOW" "Executing git clean -dfx..."
                git clean -dfx
                
                update_repo_status "$repo"  # Update status after all operations
                wait_for_key "Press any key to return to actions..."
                ;;
            5|q|Q)
                return_to_actions=false
                ;;
        esac
    done
}

# Display version and help information
display_version() {
    print_color "$COLOR_GREEN" "Shaur - Simple Helper for AUR packages"
    print_color "$COLOR_BLUE" "Version: 1.0"
    echo "Repository: $BUILD_DIR"
    echo -n "Color support: "
    if [ "$USE_COLORS" = true ]; then
        print_color "$COLOR_GREEN" "Enabled"
    else
        echo "Disabled"
    fi
    echo ""
}

# Main program
display_version
print_color "$COLOR_BLUE" "Searching for git repositories in $BUILD_DIR..."
find_repos

if [ ${#repos[@]} -eq 0 ]; then
    print_color "$COLOR_RED" "No git repositories found in $BUILD_DIR."
    exit 1
fi

# Display number of repositories and those without PKGBUILD without waiting for input
print_color "$COLOR_GREEN" "${#repos[@]} repositories found, $repos_without_pkgbuild without PKGBUILD."
print_color "$COLOR_BLUE" "Loading repository statuses in background..."

# Preload repository statuses in background
preload_all_repo_statuses

# Main menu loop
show_main_menu
