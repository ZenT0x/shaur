# Shaur

A simple bash tool to manage your AUR repositories efficiently.

## Overview

Shaur helps you maintain multiple AUR packages on Arch Linux with an interactive terminal interface. It provides status checks, batch operations, and easy navigation through your AUR repos.
Shaur works with a directory structure where you have a dedicated folder (default: `$HOME/builds`) containing multiple AUR packages, each as its own git repository.

## Features

- Interactive TUI for AUR repo management
- Repository status tracking (up-to-date, behind, ahead, modified)
- Batch operations (git pull, makepkg, clean)
- Individual package management
- Color-coded interface with auto-detection

## Installation

```bash
curl -o shaur https://raw.githubusercontent.com/username/shaur/main/shaur
chmod +x shaur
./shaur.sh
```

## Customization

Edit these variables at the top of the script:
- `BUILD_DIR`: Path to your AUR repositories
- `USE_COLORS`: Enable/disable color output
