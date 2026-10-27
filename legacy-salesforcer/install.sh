#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_app="$project_dir/build/SOQL Quick.app"
install_dir="$HOME/Applications"
target_app="$install_dir/SOQL Quick.app"

if [[ ! -d "$source_app" ]]; then
  "$project_dir/build.sh"
fi
mkdir -p "$install_dir"
ditto "$source_app" "$target_app"
mdimport "$target_app" >/dev/null 2>&1 || true
echo "Installed: $target_app"
