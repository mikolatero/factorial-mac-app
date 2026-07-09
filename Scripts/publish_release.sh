#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/FactorialMacApp.xcodeproj/project.pbxproj"
INFO_PLIST="$ROOT_DIR/FactorialMacApp/Info.plist"
PACKAGE_RESOLVED="$ROOT_DIR/FactorialMacApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
RELEASE_INFO_PATH="$ROOT_DIR/dist/release.env"
REPOSITORY="mikolatero/factorial-mac-app"
APP_BUNDLE_ID="com.sys4net.factorialclock"

usage() {
    echo "Uso: Scripts/publish_release.sh \"Mensaje del cambio\"" >&2
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

if [[ $# -lt 1 || -z "${1//[[:space:]]/}" ]]; then
    usage
    exit 1
fi

RELEASE_MESSAGE="$*"

cd "$ROOT_DIR"

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "No se encontro '$1' en PATH."
}

require_command gh
require_command git
require_command jq
require_command plutil
require_command xcodebuild

CURRENT_BRANCH="$(git branch --show-current)"
[[ "$CURRENT_BRANCH" == "main" ]] || fail "Estas en '$CURRENT_BRANCH'. Cambia a main antes de publicar."

if ! gh auth status >/dev/null 2>&1; then
    fail "GitHub CLI no esta autenticado. Ejecuta: gh auth login -h github.com"
fi

if ! gh auth setup-git >/dev/null 2>&1; then
    fail "No se pudo configurar Git para usar las credenciales de gh. Ejecuta: gh auth setup-git"
fi

read_app_build_setting() {
    local key="$1"
    SETTING_KEY="$key" /usr/bin/perl -0ne '
        my $key = $ENV{SETTING_KEY};
        while (/buildSettings = \{.*?\n\t\t\t\};/sg) {
            my $block = $&;
            next unless $block =~ /PRODUCT_BUNDLE_IDENTIFIER = com\.sys4net\.factorialclock;/;
            if ($block =~ /\Q$key\E = ([^;]+);/) {
                my $value = $1;
                $value =~ s/^"//;
                $value =~ s/"$//;
                print $value;
                exit;
            }
        }
    ' "$PROJECT_FILE"
}

increment_patch_version() {
    local version="$1"
    local major minor patch
    IFS=. read -r major minor patch extra <<< "$version"

    [[ -z "${extra:-}" ]] || fail "MARKETING_VERSION '$version' no tiene formato semver soportado."
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || fail "MARKETING_VERSION '$version' no tiene formato numerico."

    if [[ -z "${patch:-}" ]]; then
        printf "%s.%s.1" "$major" "$minor"
    else
        [[ "$patch" =~ ^[0-9]+$ ]] || fail "MARKETING_VERSION '$version' no tiene patch numerico."
        printf "%s.%s.%s" "$major" "$minor" "$((patch + 1))"
    fi
}

set_app_build_settings() {
    local version="$1"
    local build="$2"

    NEW_MARKETING_VERSION="$version" NEW_CURRENT_PROJECT_VERSION="$build" PROJECT_FILE="$PROJECT_FILE" /usr/bin/perl -0 -e '
        my $path = $ENV{PROJECT_FILE};
        open my $fh, "<", $path or die "open $path: $!";
        local $/;
        my $content = <$fh>;
        close $fh;

        my $updated = 0;
        $content =~ s@(buildSettings = \{.*?\n\t\t\t\};)@
            my $block = $1;
            if ($block =~ /PRODUCT_BUNDLE_IDENTIFIER = com\.sys4net\.factorialclock;/) {
                $block =~ s!MARKETING_VERSION = [^;]+;!MARKETING_VERSION = $ENV{NEW_MARKETING_VERSION};!;
                $block =~ s!CURRENT_PROJECT_VERSION = [^;]+;!CURRENT_PROJECT_VERSION = $ENV{NEW_CURRENT_PROJECT_VERSION};!;
                $updated++;
            }
            $block;
        @gse;

        die "No app build settings updated\n" if $updated != 2;

        open my $out, ">", $path or die "write $path: $!";
        print {$out} $content;
        close $out;
    '
}

CURRENT_MARKETING_VERSION="$(read_app_build_setting MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$(read_app_build_setting CURRENT_PROJECT_VERSION)"

[[ -n "$CURRENT_MARKETING_VERSION" ]] || fail "No se pudo leer MARKETING_VERSION del target app."
[[ "$CURRENT_PROJECT_VERSION" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION '$CURRENT_PROJECT_VERSION' no es numerico."

NEXT_MARKETING_VERSION="$(increment_patch_version "$CURRENT_MARKETING_VERSION")"
NEXT_PROJECT_VERSION="$((CURRENT_PROJECT_VERSION + 1))"
TAG="v$NEXT_MARKETING_VERSION"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    fail "El tag local $TAG ya existe."
fi

if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
    fail "El tag remoto $TAG ya existe."
fi

PROJECT_BACKUP="$(mktemp)"
cp "$PROJECT_FILE" "$PROJECT_BACKUP"
PUBLISH_COMMITTED=0

restore_project_on_error() {
    local exit_code="$1"
    if [[ "$exit_code" -ne 0 && "$PUBLISH_COMMITTED" -eq 0 && -f "$PROJECT_BACKUP" ]]; then
        cp "$PROJECT_BACKUP" "$PROJECT_FILE"
        echo "Version restaurada porque la publicacion fallo antes del commit." >&2
    fi
    rm -f "$PROJECT_BACKUP"
}

trap 'restore_project_on_error $?' EXIT

echo "Publicando $TAG (build $NEXT_PROJECT_VERSION)"

set_app_build_settings "$NEXT_MARKETING_VERSION" "$NEXT_PROJECT_VERSION"

git diff --check
plutil -lint "$INFO_PLIST" "$PROJECT_FILE" >/dev/null
jq empty "$PACKAGE_RESOLVED"

xcodebuild test \
    -project "$ROOT_DIR/FactorialMacApp.xcodeproj" \
    -scheme FactorialMacApp \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR"

"$ROOT_DIR/Scripts/prepare_update.sh"

if [[ ! -f "$RELEASE_INFO_PATH" ]]; then
    fail "No se genero $RELEASE_INFO_PATH."
fi

# shellcheck disable=SC1090
source "$RELEASE_INFO_PATH"

[[ "${MARKETING_VERSION:-}" == "$NEXT_MARKETING_VERSION" ]] || fail "Release info version inesperada: ${MARKETING_VERSION:-}"
[[ "${CURRENT_PROJECT_VERSION:-}" == "$NEXT_PROJECT_VERSION" ]] || fail "Release info build inesperado: ${CURRENT_PROJECT_VERSION:-}"
[[ -f "${ZIP_PATH:-}" ]] || fail "No existe el zip esperado: ${ZIP_PATH:-}"
[[ -f "${APPCAST_PATH:-}" ]] || fail "No existe el appcast esperado: ${APPCAST_PATH:-}"
grep -Fq "${DOWNLOAD_URL:-}" "$APPCAST_PATH" || fail "El appcast no apunta a $DOWNLOAD_URL."

test -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" || fail "La app no contiene Sparkle.framework."
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_PATH/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_PATH/Contents/Info.plist" >/dev/null

CODESIGN_OUTPUT="$(codesign -dv "$APP_PATH" 2>&1)"
grep -Fq "Signature=adhoc" <<< "$CODESIGN_OUTPUT" || fail "La app no quedo firmada ad-hoc."

BINARY_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/FactorialMacApp")"
[[ " $BINARY_ARCHS " == *" x86_64 "* ]] || fail "El binario no contiene x86_64."
[[ " $BINARY_ARCHS " == *" arm64 "* ]] || fail "El binario no contiene arm64."

git add -A

if git diff --cached --quiet; then
    fail "No hay cambios staged para commitear."
fi

git commit -m "$RELEASE_MESSAGE" -m "Release $TAG"
PUBLISH_COMMITTED=1

git tag -a "$TAG" -m "Release $TAG"
git push origin main
git push origin "$TAG"

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP_PATH" --repo "$REPOSITORY" --clobber
    gh release edit "$TAG" --repo "$REPOSITORY" --title "$TAG" --notes "$RELEASE_MESSAGE"
else
    gh release create "$TAG" "$ZIP_PATH" --repo "$REPOSITORY" --title "$TAG" --notes "$RELEASE_MESSAGE"
fi

gh release view "$TAG" --repo "$REPOSITORY" >/dev/null

echo "Publicado $TAG"
echo "Asset: $DOWNLOAD_URL"
