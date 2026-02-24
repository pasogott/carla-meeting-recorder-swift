set shell := ["bash", "-euo", "pipefail", "-c"]

@default:
    just --list

@test:
    cd Carla && swift test

@build:
    xcodebuild -project Carla/Carla.xcodeproj -scheme Carla -configuration Debug -destination 'platform=macOS' build

# Quit and reopen the latest local Debug build (use after granting permissions).
@reopen:
    osascript -e 'tell application "Carla" to quit' >/dev/null 2>&1 || true
    pkill -x Carla >/dev/null 2>&1 || true
    test -d "$(pwd)/Carla/.build/xcode/Build/Products/Debug/Carla.app"
    open "$(pwd)/Carla/.build/xcode/Build/Products/Debug/Carla.app"

# Remove old Carla installs, reset TCC permissions, rebuild Carla, then open the freshly built app.
@run-fresh:
    echo "[1/5] Quitting running Carla instance (if any)…"
    osascript -e 'tell application "Carla" to quit' >/dev/null 2>&1 || true
    pkill -x Carla >/dev/null 2>&1 || true

    echo "[2/5] Removing old Carla installations…"
    for app in "/Applications/Carla.app" "$HOME/Applications/Carla.app"; do if [[ -d "$app" ]]; then echo "  - deleting $app"; rm -rf "$app"; fi; done

    echo "[3/5] Resetting macOS privacy permissions for at.cyberheld.carla…"
    tccutil reset All "at.cyberheld.carla" || true
    tccutil reset ScreenCapture "at.cyberheld.carla" || true
    tccutil reset Microphone "at.cyberheld.carla" || true
    tccutil reset Camera "at.cyberheld.carla" || true
    tccutil reset Accessibility "at.cyberheld.carla" || true

    echo "[4/5] Building Carla (Debug)…"
    xcodebuild \
      -project Carla/Carla.xcodeproj \
      -scheme Carla \
      -configuration Debug \
      -destination 'platform=macOS' \
      -derivedDataPath "$(pwd)/Carla/.build/xcode" \
      build

    test -d "$(pwd)/Carla/.build/xcode/Build/Products/Debug/Carla.app"

    echo "[5/5] Opening $(pwd)/Carla/.build/xcode/Build/Products/Debug/Carla.app…"
    open "$(pwd)/Carla/.build/xcode/Build/Products/Debug/Carla.app"

@check-clean:
    test -z "$(git status --porcelain)" || (echo "Working tree is not clean. Commit or stash changes first." >&2; exit 1)

@release-env:
    if [[ -f .release-secrets.env ]]; then echo ".release-secrets.env already present"; exit 0; fi
    if [[ -n "${APPLE_DEVELOPER_ID_CERT_FILE:-}" || -n "${APPLE_DEVELOPER_ID_CERT:-}" ]]; then echo "Using signing env from current shell"; exit 0; fi
    ./scripts/generate-release-env.sh .release-secrets.env

@changelog tag:
    ./scripts/release-changelog.sh "{{tag}}"

@release-notes tag output='dist/release-notes.md':
    ./scripts/release-notes.sh "{{tag}}" "{{output}}"

@release tag='':
    just check-clean
    just test
    just build
    just release-env
    RESOLVED_TAG="{{tag}}"; if [[ -z "$RESOLVED_TAG" ]]; then source ./scripts/release_lib.sh; RESOLVED_TAG="$(next_carla_tag)"; fi; echo "Preparing release: $RESOLVED_TAG"; just changelog "$RESOLVED_TAG"; git add CHANGELOG.md; if ! git diff --cached --quiet; then git commit -m "docs(changelog): release $RESOLVED_TAG"; fi; git push origin HEAD; ./scripts/release.sh "$RESOLVED_TAG"; NOTES_FILE="dist/release-notes-$RESOLVED_TAG.md"; just release-notes "$RESOLVED_TAG" "$NOTES_FILE"; gh release edit "$RESOLVED_TAG" --notes-file "$NOTES_FILE"; echo "Release completed: $RESOLVED_TAG"; echo "Release notes source: $NOTES_FILE"
