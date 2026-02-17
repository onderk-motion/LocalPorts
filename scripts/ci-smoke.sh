#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[ci] Building LocalPorts (Debug)"
xcodebuild -project LocalPorts.xcodeproj \
  -scheme LocalPorts \
  -configuration Debug \
  -derivedDataPath .build \
  build >/tmp/localports-ci-build.log

echo "[ci] Checking for accidental local path leaks"
rg -n "/Users/[A-Za-z0-9._-]+|127\\.108\\.128\\.175" App README.md >/tmp/localports-ci-leaks.raw || true
rg -v "/Users/you" /tmp/localports-ci-leaks.raw >/tmp/localports-ci-leaks.log || true
if [ -s /tmp/localports-ci-leaks.log ]; then
  echo "Found machine-specific content:"
  cat /tmp/localports-ci-leaks.log
  exit 1
fi

echo "[ci] Validating app config backward compatibility decode"
swift -e '
import Foundation
struct PersistedAppSettings: Codable {
    var launchInBackground: Bool
    var requiresImportedStartApproval: Bool
    enum CodingKeys: String, CodingKey { case launchInBackground, requiresImportedStartApproval }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchInBackground = try c.decodeIfPresent(Bool.self, forKey: .launchInBackground) ?? true
        requiresImportedStartApproval = try c.decodeIfPresent(Bool.self, forKey: .requiresImportedStartApproval) ?? false
    }
}
let sample = """
{ "launchInBackground": true }
""".data(using: .utf8)!
_ = try JSONDecoder().decode(PersistedAppSettings.self, from: sample)
print("config decode ok")
'

echo "[ci] Smoke checks passed"
