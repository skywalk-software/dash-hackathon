#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild build -project DashHackathon.xcodeproj -scheme DashHackathon \
  -destination 'platform=macOS' -derivedDataPath .build CODE_SIGN_IDENTITY=-
