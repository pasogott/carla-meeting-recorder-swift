set shell := ["bash", "-euo", "pipefail", "-c"]

@default:
    just --list

@test:
    cd Carla && swift test

@build:
    xcodebuild -project Carla/Carla.xcodeproj -scheme Carla -configuration Debug -destination 'platform=macOS' build

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
