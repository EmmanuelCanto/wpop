#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Uso: Scripts/prepare_release.sh VERSION [NOTAS_DE_VERSION]" >&2
  echo "Ejemplo: Scripts/prepare_release.sh 4.0 release-notes.md" >&2
  exit 64
fi

version="${1#v}"
release_notes_path="${2:-}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="${project_root}/.build/DerivedData"
release_directory="${project_root}/dist/${version}"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/wpop-release.XXXXXX")"

cleanup() {
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT

if [[ ! "${version}" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  echo "La versión debe tener un formato como 4.0 o 4.1.2." >&2
  exit 64
fi

if [[ -e "${release_directory}" ]]; then
  echo "Ya existe ${release_directory}." >&2
  echo "Muévelo o elimínalo conscientemente antes de volver a generar el release." >&2
  exit 73
fi

if [[ -n "${release_notes_path}" && ! -f "${release_notes_path}" ]]; then
  echo "No existe el archivo de notas: ${release_notes_path}" >&2
  exit 66
fi

project_version="$(
  xcodebuild \
    -project "${project_root}/Wpop.xcodeproj" \
    -scheme FloatingWindow \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -showBuildSettings |
    awk -F ' = ' '/MARKETING_VERSION =/ { print $2; exit }'
)"

if [[ "${project_version}" != "${version}" ]]; then
  echo "La versión del proyecto es ${project_version}; se solicitó ${version}." >&2
  echo "Actualiza MARKETING_VERSION y CURRENT_PROJECT_VERSION antes de publicar." >&2
  exit 65
fi

echo "Compilando Wpop ${version}…"
xcodebuild \
  -project "${project_root}/Wpop.xcodeproj" \
  -scheme FloatingWindow \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "${derived_data_path}" \
  build

app_path="${derived_data_path}/Build/Products/Release/Wpop.app"
if [[ ! -d "${app_path}" ]]; then
  echo "No se encontró la aplicación compilada en ${app_path}." >&2
  exit 70
fi

actual_version="$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "${app_path}/Contents/Info.plist"
)"
if [[ "${actual_version}" != "${version}" ]]; then
  echo "Wpop.app contiene la versión ${actual_version}; se esperaba ${version}." >&2
  exit 65
fi

app_architectures="$(lipo -archs "${app_path}/Contents/MacOS/Wpop")"
if [[ " ${app_architectures} " != *" arm64 "* ||
      " ${app_architectures} " != *" x86_64 "* ]]; then
  echo "Wpop.app no es universal: ${app_architectures}" >&2
  exit 65
fi

generate_appcast="$(
  find "${derived_data_path}/SourcePackages/artifacts" \
    -type f \
    -path "*/Sparkle/bin/generate_appcast" \
    -print \
    -quit
)"

if [[ ! -x "${generate_appcast}" ]]; then
  echo "No se encontró generate_appcast de Sparkle." >&2
  exit 69
fi

generate_appcast_command=("${generate_appcast}")
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  if [[ ! -f "${SPARKLE_PRIVATE_KEY_FILE}" ]]; then
    echo "No existe SPARKLE_PRIVATE_KEY_FILE: ${SPARKLE_PRIVATE_KEY_FILE}" >&2
    exit 66
  fi

  generate_appcast_command+=(
    --ed-key-file
    "${SPARKLE_PRIVATE_KEY_FILE}"
  )
fi

mkdir -p "${release_directory}"

echo "Creando Wpop.dmg…"
ditto "${app_path}" "${temporary_directory}/Wpop.app"
hdiutil create \
  -volname Wpop \
  -srcfolder "${temporary_directory}/Wpop.app" \
  -format UDZO \
  "${release_directory}/Wpop.dmg"

if [[ -n "${release_notes_path}" ]]; then
  cp "${release_notes_path}" "${release_directory}/Wpop.md"
fi

echo "Firmando la actualización y generando appcast.xml…"
"${generate_appcast_command[@]}" \
  --download-url-prefix \
  "https://github.com/EmmanuelCanto/wpop/releases/download/${version}/" \
  --link "https://github.com/EmmanuelCanto/wpop" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "${release_directory}/appcast.xml" \
  "${release_directory}"

if [[ ! -s "${release_directory}/appcast.xml" ]]; then
  echo "Sparkle no generó appcast.xml." >&2
  exit 70
fi

echo
echo "Release listo en ${release_directory}:"
echo "  Wpop.dmg"
echo "  appcast.xml"
echo
echo "Crea el release ${version} en GitHub y adjunta ambos archivos."
