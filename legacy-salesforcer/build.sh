#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
app_dir="$build_dir/SOQL Quick.app"
contents_dir="$app_dir/Contents"
module_cache="${TMPDIR:-/private/tmp}/soql-quick-swift-module-cache"
sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
icon_source="$project_dir/Assets/SOQL-Quick-icon-1024.png"

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$module_cache"
CLANG_MODULE_CACHE_PATH="$module_cache" SWIFT_MODULECACHE_PATH="$module_cache" swiftc "$project_dir/Sources/Tabular.swift" "$project_dir/Sources/Metadata.swift" "$project_dir/Sources/Completion.swift" "$project_dir/Sources/SchemaSidebar.swift" "$project_dir/Sources/main.swift" \
  -o "$contents_dir/MacOS/SOQL Quick" \
  -sdk "$sdk" \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework Carbon
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Backend/query_backend.R" "$contents_dir/Resources/query_backend.R"
cp "$project_dir/Backend/metadata_backend.R" "$contents_dir/Resources/metadata_backend.R"
cp "$project_dir/Backend/backend_common.R" "$contents_dir/Resources/backend_common.R"
python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).convert("RGBA").save(sys.argv[2], format="ICNS")' "$icon_source" "$contents_dir/Resources/SOQLQuick.icns"
chmod +x "$contents_dir/MacOS/SOQL Quick" "$contents_dir/Resources/query_backend.R" "$contents_dir/Resources/metadata_backend.R"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
