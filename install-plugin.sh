#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -n "${NVIM_DATA_DIR+x}" ]]; then
    if [[ -z "$NVIM_DATA_DIR" ]]; then
        echo "NVIM_DATA_DIR is set but empty" >&2
        exit 1
    fi
else
    case "$(uname -s)" in
        Darwin)
            NVIM_DATA_DIR="$HOME/.local/share/nvim"
            ;;
        Linux)
            if [[ -n "${XDG_DATA_HOME:-}" ]]; then
                NVIM_DATA_DIR="$XDG_DATA_HOME/nvim"
            else
                NVIM_DATA_DIR="$HOME/.local/share/nvim"
            fi
            ;;
        *)
            echo "Unsupported OS: $(uname -s)" >&2
            exit 1
            ;;
    esac
fi

PLUGIN_DIR="$NVIM_DATA_DIR/lazy/agents.nvim"

mkdir -p "$PLUGIN_DIR"
PLUGIN_DIR_PHYSICAL="$(cd -- "$PLUGIN_DIR" && pwd -P)"

if [[ "$PLUGIN_DIR_PHYSICAL" == "$SOURCE_DIR" ]]; then
    echo "Install target is the source checkout; refusing to remove files in $SOURCE_DIR" >&2
    exit 1
fi

case "$SOURCE_DIR/" in
    "$PLUGIN_DIR_PHYSICAL"/*)
        echo "Source checkout is inside the install target; refusing to remove $PLUGIN_DIR_PHYSICAL" >&2
        exit 1
        ;;
esac

echo "Installing agents.nvim to $PLUGIN_DIR_PHYSICAL"

echo "Clearing existing files"
find "$PLUGIN_DIR_PHYSICAL" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

echo "Copying top-level files"
find "$SOURCE_DIR" \
    -maxdepth 1 \
    -type f \
    ! -name ".*" \
    ! -name "install-plugin.sh" \
    ! -name "nvim.log" \
    -exec cp {} "$PLUGIN_DIR_PHYSICAL/" \;

for dir in lua plugin doc docs tests; do
    if [[ -d "$SOURCE_DIR/$dir" ]]; then
        echo "Copying $dir/"
        cp -R "$SOURCE_DIR/$dir" "$PLUGIN_DIR_PHYSICAL/"
    fi
done

echo "Installed agents.nvim at $PLUGIN_DIR_PHYSICAL"
echo "Restart Neovim or reload your plugin manager."
echo "Smoke command: :Agents launch"
