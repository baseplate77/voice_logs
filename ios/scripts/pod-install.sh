#!/usr/bin/env bash
# Wrapper around `pod install` that resolves three Xcode-26 / Ruby-3.4
# incompatibilities so the bare `pod install` command works on this repo:
#
# 1. Xcode 16+ writes `objectVersion = 70` in .pbxproj. Released CocoaPods
#    1.16.2 ships an older xcodeproj that can't parse it — fix is to use
#    Xcodeproj from its master branch (pinned in Gemfile).
# 2. Homebrew's `pod` ships its own gem bundle, so we use `bundle exec` to
#    pick up our project's pinned versions instead.
# 3. CFPropertyList 3.0.8 does `require 'kconv'`, but Ruby 3.4 dropped
#    `kconv` from stdlib and 3.0.9+ requires Ruby <3.2, while xcodeproj
#    caps CFPropertyList <4.0. We supply an empty `kconv.rb` shim via
#    RUBYLIB so the require succeeds (Kconv itself is never used).
#
# Run from the repo's ios/ directory.

set -euo pipefail

ios_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ios_dir"

ruby_bin="/opt/homebrew/opt/ruby/bin"
if [[ ! -x "$ruby_bin/bundle" ]]; then
  echo "Homebrew Ruby not found at $ruby_bin. Install with: brew install ruby"
  exit 1
fi

export PATH="$ruby_bin:$PATH"
export RUBYLIB="$ios_dir/.bundle/shims${RUBYLIB:+:$RUBYLIB}"

"$ruby_bin/bundle" install
"$ruby_bin/bundle" exec pod install "$@"
