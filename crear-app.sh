#!/bin/zsh
# Compila LimpiadorMac y la empaqueta como LimpiadorMac.app
set -e
cd "$(dirname "$0")"

echo "→ Compilando…"
swift build -c release

FINAL="LimpiadorMac.app"
APP="LimpiadorMac.nueva.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LimpiadorMac "$APP/Contents/MacOS/"
cp Recursos/Info.plist "$APP/Contents/"

echo "→ Creando ícono…"
TMP=$(mktemp -d)
swift Recursos/icono.swift "$TMP/icono.png"
mkdir "$TMP/AppIcon.iconset"
for t in 16 32 128 256 512; do
  sips -z $t $t "$TMP/icono.png" --out "$TMP/AppIcon.iconset/icon_${t}x${t}.png" >/dev/null
  sips -z $((t*2)) $((t*2)) "$TMP/icono.png" --out "$TMP/AppIcon.iconset/icon_${t}x${t}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

# Firma. macOS recuerda los permisos («Acceso total al disco», «Gestión de apps») por la firma de la app. Con una
# firma ad hoc («-») la firma cambia en cada compilación y macOS los olvida. Con una identidad de firma estable (un
# certificado de tu llavero) los recuerda entre compilaciones. Por defecto se busca «LimpiadorMac Local»; con
# LIMPIADOR_FIRMA se puede usar otra. El certificado lo creas tú una vez (ver README); este script nunca crea ninguno.
IDENT="${LIMPIADOR_FIRMA:-LimpiadorMac Local}"
FIRMADA=""
# Sin -v: un certificado propio (autofirmado) no es «de confianza» para el sistema, pero firma igual.
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENT\""; then
  echo "→ Firmando con «$IDENT»…"
  if codesign --force --deep --timestamp=none --sign "$IDENT" "$APP"; then
    FIRMADA="$IDENT"
  else
    echo "⚠︎ No pude firmar con «$IDENT» (¿el llavero está bloqueado o no diste permiso?). Firmo ad hoc."
  fi
fi
if [ -z "$FIRMADA" ]; then
  [ -n "$LIMPIADOR_FIRMA" ] || echo "→ No encontré la identidad de firma «$IDENT»."
  echo "→ Firmando ad hoc…"
  codesign --force --deep --sign - "$APP"
  echo "⚠︎ Con firma ad hoc, macOS olvida el «Acceso total al disco» y la «Gestión de apps» de LimpiadorMac en cada"
  echo "  compilación. Para que los recuerde, crea una vez un certificado de firma de código en Acceso a Llaveros ›"
  echo "  Asistente para certificados › Crear un certificado (nombre «$IDENT», tipo «Firma de código») y vuelve a"
  echo "  ejecutar este script. Lo explica el README."
fi

# Cambio de golpe: la app anterior se reemplaza en un instante.
rm -rf "$FINAL.vieja"
[ -d "$FINAL" ] && mv "$FINAL" "$FINAL.vieja"
mv "$APP" "$FINAL"
rm -rf "$FINAL.vieja"

echo "✓ Listo: $(pwd)/$FINAL (versión $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$FINAL/Contents/Info.plist"), firma: ${FIRMADA:-ad hoc})"
