#!/bin/sh
# Builds the DocC archive for LSL and LSLCore into .build/documentation.
#
# swift-docc-plugin would do this in one command, but it is a package dependency and
# would appear in every consumer's resolved graph; this package's value is being
# dependency-free (ARCHITECTURE.md, dependency rules). `docc` ships with Xcode, so
# driving it from the symbol graphs directly costs nothing.
#
#   Scripts/build-docs.sh [--serve]

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

graphs=.build/documentation/symbol-graphs
archive=.build/documentation/SwiftLSL.doccarchive

# dump-symbol-graph extracts every module in the package, test targets included, and
# fails outright if one cannot be loaded. On a clean checkout the test modules have not
# been built, so they must be built first even though their graphs are then discarded.
swift build --build-tests
swift package dump-symbol-graph --minimum-access-level public >/dev/null

rm -rf "$graphs" "$archive"
mkdir -p "$graphs"
# The test target emits a symbol graph too; only the two products belong in the archive.
for module in LSL LSLCore; do
    cp ".build/$(uname -m)-apple-macosx/symbolgraph/$module.symbols.json" "$graphs/"
done

xcrun docc convert Sources/LSL/LSL.docc \
    --fallback-display-name SwiftLSL \
    --fallback-bundle-identifier fi.iki.pnr.SwiftLSL \
    --additional-symbol-graph-dir "$graphs" \
    --warnings-as-errors \
    --output-path "$archive"

echo "built $archive"

if [ "${1:-}" = "--serve" ]; then
    xcrun docc preview Sources/LSL/LSL.docc \
        --fallback-display-name SwiftLSL \
        --fallback-bundle-identifier fi.iki.pnr.SwiftLSL \
        --additional-symbol-graph-dir "$graphs"
fi
