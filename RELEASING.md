# Publicar Wpop sin App Store

Wpop se distribuye mediante GitHub Releases y el tap
`EmmanuelCanto/homebrew-wpop`. Las actualizaciones dentro de la aplicación usan
Sparkle 2 y una firma EdDSA, por lo que no requieren una suscripción de Apple
Developer.

La versión 4.0 es la primera que contiene Sparkle. Los usuarios de 3.0 deben
instalar 4.0 manualmente una sola vez, ya sea desde GitHub o con:

```bash
brew update
brew upgrade --cask wpop
```

A partir de 4.0, Wpop busca actualizaciones automáticamente y también ofrece
`Wpop > Buscar actualizaciones…`.

## Antes del primer release

La clave privada EdDSA está guardada en el llavero de macOS con la cuenta
`ed25519`. Respáldala en un volumen cifrado con la herramienta `generate_keys`
de Sparkle:

```bash
.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  -x /ruta/segura/wpop-ed25519-private-key
```

No publiques ni agregues ese respaldo al repositorio. La clave pública incluida
en la aplicación es:

```text
NHqGoolQWK+XncfI0RstLXghp+34C9xM8tFqJrdV7j0=
```

Perder la clave privada impediría publicar actualizaciones automáticas para las
instalaciones existentes.

## Crear un release

1. Actualiza `MARKETING_VERSION` y aumenta `CURRENT_PROJECT_VERSION` en las dos
   configuraciones del target. El número de compilación siempre debe crecer.
2. Opcionalmente crea un archivo Markdown con las notas de la versión.
3. Desde la raíz del repositorio ejecuta:

   ```bash
   Scripts/prepare_release.sh 4.1 release-notes.md
   ```

   Si no hay notas:

   ```bash
   Scripts/prepare_release.sh 4.1
   ```

   La primera vez, macOS pedirá permiso para que `generate_appcast` lea la
   clave `ed25519` del llavero; selecciona `Permitir siempre`. También se puede
   indicar un respaldo seguro sin copiarlo al repositorio:

   ```bash
   SPARKLE_PRIVATE_KEY_FILE=/ruta/segura/wpop-ed25519-private-key \
     Scripts/prepare_release.sh 4.1
   ```

4. El script compila `Wpop.app`, crea `dist/4.1/Wpop.dmg` y firma tanto el DMG
   como `dist/4.1/appcast.xml` usando la clave del llavero.
5. Crea un GitHub Release estable cuyo tag coincida exactamente con la versión,
   por ejemplo `4.1`. Adjunta `Wpop.dmg` y `appcast.xml` sin cambiar sus nombres.
   No marques el release como borrador ni prerelease cuando quieras ofrecerlo a
   todos los usuarios.

El feed configurado en Wpop siempre lee:

```text
https://github.com/EmmanuelCanto/wpop/releases/latest/download/appcast.xml
```

Por eso cada release estable debe contener ambos archivos. Después de publicar,
la automatización del tap detectará el nuevo `Wpop.dmg`, calculará su SHA-256 y
actualizará el cask.

## Comprobación rápida

Con la versión anterior instalada, abre `Wpop > Buscar actualizaciones…`.
Sparkle debe mostrar la nueva versión, descargarla, reemplazar la aplicación y
volver a abrirla. Debido a que el proyecto no está notarizado, una instalación
inicial descargada manualmente puede seguir mostrando el aviso normal de
Gatekeeper; las actualizaciones posteriores se validan con la firma EdDSA.
