#!/bin/zsh
# Builds a universal Tidy.app and zips it for a GitHub Release. Prints the SHA256 for the Homebrew cask.
set -e
cd "${0:A:h}"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null)/Tidy
rm -rf Tidy.app && mkdir -p Tidy.app/Contents/MacOS
cp $BIN Tidy.app/Contents/MacOS/Tidy
sed -n "/<<'PLIST'/,/^PLIST/p" build.sh | sed '1d;$d' > Tidy.app/Contents/Info.plist
codesign --force --sign - Tidy.app
rm -f Tidy.zip && ditto -c -k --keepParent Tidy.app Tidy.zip
shasum -a 256 Tidy.zip
