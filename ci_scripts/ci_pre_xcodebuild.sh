#!/bin/sh
# Xcode Cloud runs this before every xcodebuild action.
set -e

# Since Xcode 26 the Metal toolchain is a separate download, and Xcode Cloud
# images don't include it, so compiling DustEffect.metal fails with
# "CompileMetalFile failed". Fetch it when it isn't already there.
if xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q "Status: installed"; then
    echo "Metal toolchain already installed."
else
    echo "Downloading the Metal toolchain..."
    xcodebuild -downloadComponent MetalToolchain
fi

# Archives take their build number from Xcode Cloud's own counter, so every
# build gets a new one while the version (MARKETING_VERSION) stays as committed.
# This only edits Xcode Cloud's temporary checkout; nothing is pushed back.
# Set the counter's next value in App Store Connect > Xcode Cloud > Settings >
# Build Number, above the highest build already uploaded.
if [ "$CI_XCODEBUILD_ACTION" = "archive" ] && [ -n "$CI_BUILD_NUMBER" ]; then
    project="$CI_PRIMARY_REPOSITORY_PATH/LongScreenshot.xcodeproj/project.pbxproj"
    sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER;/" "$project"
    echo "Build number set to $CI_BUILD_NUMBER."
fi
