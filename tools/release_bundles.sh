# shellcheck shell=bash
# The release bundles (#695), in one place for the publisher and for
# verify-release.
#
# Every release after LAST_WITHOUT ships one bundle per platform in SYSTEMS,
# named singular-<version>-<system>.tar.gz and listed in the release's one
# SHA256SUMS. Releases up to LAST_WITHOUT were published before bundles
# existed and keep their old rule. The platforms are the ones the flake's
# release-bundle output and the release-bundles workflow's matrix build; a
# platform missing from either one fails the publisher, which refuses to
# publish a release without every bundle listed here.
# shellcheck disable=SC2034
SYSTEMS="x86_64-linux aarch64-darwin"
LAST_WITHOUT="0.12.0"

# bundles_required VERSION: succeeds when a release of this version ships bundles.
bundles_required() {
  [ "$1" != "$LAST_WITHOUT" ] \
    && [ "$(printf '%s\n%s\n' "$1" "$LAST_WITHOUT" | LC_ALL=C sort -V | tail -n 1)" = "$1" ]
}

# native_system: the bundle system name of the machine running this.
native_system() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) echo x86_64-linux ;;
    Linux/aarch64 | Linux/arm64) echo aarch64-linux ;;
    Darwin/arm64) echo aarch64-darwin ;;
    Darwin/x86_64) echo x86_64-darwin ;;
    *) echo "unknown-$(uname -s)-$(uname -m)" ;;
  esac
}
