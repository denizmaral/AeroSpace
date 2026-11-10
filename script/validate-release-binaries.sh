#!/usr/bin/env bash
cd "$(dirname "$0")/.."
source ./script/setup.sh

expected_layout=$(cat <<EOF
.release/MarSpace.app
.release/MarSpace.app/Contents
.release/MarSpace.app/Contents/_CodeSignature
.release/MarSpace.app/Contents/_CodeSignature/CodeResources
.release/MarSpace.app/Contents/MacOS
.release/MarSpace.app/Contents/MacOS/MarSpace
.release/MarSpace.app/Contents/Resources
.release/MarSpace.app/Contents/Resources/AppIcon.icns
.release/MarSpace.app/Contents/Resources/Assets.car
.release/MarSpace.app/Contents/Frameworks
.release/MarSpace.app/Contents/Frameworks/libswiftCompatibilitySpan.dylib
.release/MarSpace.app/Contents/Info.plist
.release/MarSpace.app/Contents/PkgInfo
EOF
)

check-equals() {
    if test "$2" != "$3"; then
        echo "ERROR: $1 doesn't match the expected value"
        echo "Diff:"
        diff -u --color --label expected --label actual <(echo "$2") <(echo "$3") || true
        exit 1
    fi
}

check-equals ".release/MarSpace.app layout" "$expected_layout" "$(find .release/MarSpace.app)"

check-universal-binary() {
    if ! file "$1" | grep --fixed-string -q "Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64"; then
        echo "$1 is not a universal binary"
        exit 1
    fi
}

check-contains-hash() {
    hash=$(git rev-parse HEAD)
    if ! strings "$1" | grep --fixed-string "$hash" > /dev/null; then
        echo "$1 doesn't contain $hash"
        exit 1
    fi
}

check-no-rpath-dylibs() {
    if otool -L "$1" | grep --fixed-string '@rpath/'; then
        echo "$1 links @rpath dylibs that aren't shipped next to it"
        exit 1
    fi
}

check-rpaths() {
    for arch in x86_64 arm64; do
        check-equals "$1 ($arch) rpaths" "$2" "$(xcrun objdump --macho --rpaths --no-leading-headers --arch "$arch" "$1")"
    done
}

check-dylibs() {
    for arch in x86_64 arm64; do
        check-equals "$1 ($arch) dylibs" "$2" "$(xcrun objdump --macho --dylibs-used --no-leading-headers --arch "$arch" "$1" |
            sed -E 's/ \(compatibility version [^)]*, weak\)$/ (weak)/; s/ \(compatibility version [^)]*\)$//' |
            # Allow anything from /usr/lib/swift. Different Xcode versions link slightly different dylibs
            sed -E '\|^./usr/lib/swift/|d' |
            # Xcode 26 links it weak, Xcode 27 links it strong #macos27
            sed -E 's|^(.@rpath/libswiftCompatibilitySpan\.dylib) \(weak\)$|\1|')"
    done
}

check-no-rpath-dylibs .release/aerospace

expected_app_rpaths=$(cat <<EOF
/usr/lib/swift
@executable_path/../Frameworks
EOF
)
check-rpaths .release/MarSpace.app/Contents/MacOS/MarSpace "$expected_app_rpaths"

expected_cli_rpaths=$(cat <<EOF
/usr/lib/swift
@loader_path
EOF
)
check-rpaths .release/aerospace "$expected_cli_rpaths"

expected_app_dylibs=$(cat <<EOF
	/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation
	/usr/lib/libobjc.A.dylib
	/usr/lib/libSystem.B.dylib
	/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
	/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices
	/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon
	/System/Library/Frameworks/Combine.framework/Versions/A/Combine
	/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio
	/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
	/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics
	/System/Library/Frameworks/ServiceManagement.framework/Versions/A/ServiceManagement
	/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI
	/usr/lib/libc++.1.dylib
	@rpath/libswiftCompatibilitySpan.dylib
EOF
)
check-dylibs .release/MarSpace.app/Contents/MacOS/MarSpace "$expected_app_dylibs"

expected_cli_dylibs=$(cat <<EOF
	/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation
	/usr/lib/libobjc.A.dylib
	/usr/lib/libSystem.B.dylib
	/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
	/usr/lib/libc++.1.dylib
EOF
)
check-dylibs .release/aerospace "$expected_cli_dylibs"

check-universal-binary .release/MarSpace.app/Contents/MacOS/MarSpace
check-universal-binary .release/aerospace

codesign -v .release/MarSpace.app
codesign -v .release/aerospace

check-contains-hash .release/MarSpace.app/Contents/MacOS/MarSpace
check-contains-hash .release/aerospace
