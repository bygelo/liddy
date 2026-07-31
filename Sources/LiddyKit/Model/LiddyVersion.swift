import Foundation

/// The one place a version number is written down.
///
/// The app, the CLI and the helper all report this, and `Script/build-app.sh`
/// reads it out of this file to stamp `Info.plist` — so a build cannot ship a
/// Finder version that disagrees with what `liddy --version` prints. The release
/// workflow rewrites this line from the tag it was triggered by, which is what
/// makes `v0.1.0` and the binary the same claim rather than two claims that
/// happen to match today.
///
/// Keep the literal on one line and in this exact shape: the workflow's `sed`
/// matches it.
public enum LiddyVersion {
    public static let current = "0.1.0"
}
