#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/FactorialMacApp.xcodeproj/project.pbxproj"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
APPCAST_WORK_DIR="$ROOT_DIR/build/appcast"
DOCS_DIR="$ROOT_DIR/docs"
APP_NAME="FactorialMacApp.app"
RELEASE_NAME="FactorialClock"
APP_BUNDLE_ID="com.mikolatero.factorialclock"
export APP_BUNDLE_ID

# Lee un build setting SOLO del target de la app (identificado por su bundle id),
# para no capturar los valores del target de tests.
read_build_setting() {
    local key="$1"
    SETTING_KEY="$key" /usr/bin/perl -0ne '
        my $key = $ENV{SETTING_KEY};
        while (/buildSettings = \{.*?\n\t\t\t\};/sg) {
            my $block = $&;
            next unless $block =~ /PRODUCT_BUNDLE_IDENTIFIER = \Q$ENV{APP_BUNDLE_ID}\E;/;
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

MARKETING_VERSION="$(read_build_setting MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$(read_build_setting CURRENT_PROJECT_VERSION)"

if [[ -z "$MARKETING_VERSION" || -z "$CURRENT_PROJECT_VERSION" ]]; then
    echo "No se pudo leer MARKETING_VERSION o CURRENT_PROJECT_VERSION desde $PROJECT_FILE" >&2
    exit 1
fi

ZIP_NAME="$RELEASE_NAME-$MARKETING_VERSION-$CURRENT_PROJECT_VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
DOWNLOAD_URL_PREFIX="https://github.com/mikolatero/factorial-mac-app/releases/download/v$MARKETING_VERSION/"
DOWNLOAD_URL="$DOWNLOAD_URL_PREFIX$ZIP_NAME"
RELEASE_INFO_PATH="$DIST_DIR/release.env"

mkdir -p "$DIST_DIR" "$APPCAST_WORK_DIR" "$DOCS_DIR"
rm -f "$APPCAST_WORK_DIR"/*.zip "$APPCAST_WORK_DIR"/appcast.xml

xcodebuild \
    -project "$ROOT_DIR/FactorialMacApp.xcodeproj" \
    -scheme FactorialMacApp \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO \
    build

APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME"

if [[ ! -d "$APP_PATH" ]]; then
    echo "No se encontro la app compilada en $APP_PATH" >&2
    exit 1
fi

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
cp "$ZIP_PATH" "$APPCAST_WORK_DIR/$ZIP_NAME"

if [[ -n "${SPARKLE_TOOLS_DIR:-}" && -x "$SPARKLE_TOOLS_DIR/generate_appcast" ]]; then
    GENERATE_APPCAST="$SPARKLE_TOOLS_DIR/generate_appcast"
else
    GENERATE_APPCAST="$(find "$DERIVED_DATA_DIR/SourcePackages" -path '*/bin/generate_appcast' -type f -perm -111 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$GENERATE_APPCAST" || ! -x "$GENERATE_APPCAST" ]]; then
    echo "No se encontro generate_appcast. Ejecuta xcodebuild -resolvePackageDependencies o define SPARKLE_TOOLS_DIR." >&2
    exit 1
fi

GENERATE_HELP="$("$GENERATE_APPCAST" --help 2>&1 || true)"
GENERATE_ARGS=()

if grep -q -- "--download-url-prefix" <<< "$GENERATE_HELP"; then
    GENERATE_ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
fi

if grep -q -- "--disable-delta-updates" <<< "$GENERATE_HELP"; then
    GENERATE_ARGS+=(--disable-delta-updates)
fi

"$GENERATE_APPCAST" "${GENERATE_ARGS[@]}" "$APPCAST_WORK_DIR"

if [[ ! -f "$APPCAST_WORK_DIR/appcast.xml" ]]; then
    echo "generate_appcast no genero $APPCAST_WORK_DIR/appcast.xml" >&2
    exit 1
fi

cp "$APPCAST_WORK_DIR/appcast.xml" "$DOCS_DIR/appcast.xml"

cat > "$RELEASE_INFO_PATH" <<EOF
MARKETING_VERSION=$MARKETING_VERSION
CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION
ZIP_NAME=$ZIP_NAME
ZIP_PATH=$ZIP_PATH
DOWNLOAD_URL=$DOWNLOAD_URL
APPCAST_PATH=$DOCS_DIR/appcast.xml
APP_PATH=$APP_PATH
EOF

echo "Zip listo: $ZIP_PATH"
echo "Appcast listo: $DOCS_DIR/appcast.xml"
echo "Release info: $RELEASE_INFO_PATH"
echo "Sube el zip a: $DOWNLOAD_URL"
