#!/bin/bash
set -e

APP_NAME="MiddleClick"
BUILD_DIR=".build/release"
OUT_DIR="build"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

echo "==> Compilation en mode release..."
swift build -c release

echo "==> Construction du bundle .app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

if [ -d "AppIcon.iconset" ]; then
    echo "==> Génération de l'icône (.iconset -> .icns)..."
    iconutil -c icns AppIcon.iconset -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    echo "==> Pas d'AppIcon.iconset trouvé, l'app utilisera l'icône par défaut."
fi

echo "==> Signature ad-hoc (identité stable pour les autorisations macOS)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "==> Terminé : $APP_BUNDLE"
echo "Ouvre-le avec : open \"$APP_BUNDLE\""
echo ""
echo "IMPORTANT : comme c'est un nouveau binaire (chemin et identité"
echo "différents de ceux utilisés par 'swift run'), macOS va redemander"
echo "les autorisations Accessibilité et Surveillance des saisies pour"
echo "ce nouveau $APP_NAME.app. Pense à retirer les anciennes entrées"
echo "(liées à swift-frontend / .build/) dans Réglages Système si elles"
echo "traînent encore, pour éviter la confusion."
