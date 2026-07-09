# Factorial Clock

App macOS nativa en SwiftUI para fichar en Factorial desde la barra superior.

## Requisitos

- Xcode 26.5 o compatible
- macOS 14+
- Cuenta de Factorial con acceso web

## Ejecutar

Abre `FactorialMacApp.xcodeproj` en Xcode y ejecuta el esquema `FactorialMacApp`.

La app se muestra como icono de reloj en la barra superior de macOS. Desde `Ajustes` puedes:

- Iniciar sesion en Factorial con MFA usando WebKit.
- Configurar el lugar de trabajo.
- Crear varias plantillas de horario y elegir una activa.
- Bloquear fichajes automaticos por vacaciones o festivos manuales.
- Pausar/reanudar automatizacion.
- Activar apertura al iniciar sesion.
- Enrutar WebKit por un proxy HTTP local desde la pestana `Red`.
- Preparar la sesion con un resolvedor local compatible con FlareSolverr o TRAWL.

## Integracion con Factorial

Esta v1 no guarda contrasenas ni usa API keys. Reutiliza una sesion web iniciada por el usuario y ejecuta el fichaje mediante WebKit. Si Factorial cambia los textos o estructura del boton de fichaje, habra que ajustar los selectores en `FactorialClockingClient`.

## Proxy HTTP

En `Ajustes` > `Red` puedes activar un proxy HTTP para la sesion WebKit, por ejemplo `http://127.0.0.1:8080`. El endpoint debe comportarse como proxy HTTP/CONNECT.

En esa misma pestana puedes activar un resolvedor local:

- `FlareSolverr /v1`: llama a `POST /v1` con `cmd: request.get`.
- `TRAWL /scrape`: llama a `POST /scrape` con la URL objetivo.

La app importa las cookies y el user agent devueltos por el resolvedor en la sesion WebKit antes de cargar Factorial. Si la llamada directa de fichaje recibe HTTP 403, 429 o 503, refresca esa sesion con el resolvedor y reintenta una vez.

## Tests

```sh
xcodebuild test -project FactorialMacApp.xcodeproj -scheme FactorialMacApp -destination 'platform=macOS'
```

## Auto-update interno

La app usa Sparkle 2 para actualizarse sin Apple Developer Program. Los updates se firman con la clave EdDSA de Sparkle y se publican con:

- feed: `https://mikolatero.github.io/factorial-mac-app/appcast.xml`
- zip: GitHub Release `v<MARKETING_VERSION>`

La primera instalacion puede mostrar el aviso de Gatekeeper porque la app no esta notarizada. Para uso interno, abre la app con clic derecho > Abrir o elimina la cuarentena si hace falta:

```sh
xattr -dr com.apple.quarantine /Applications/FactorialMacApp.app
```

### Preparar la clave de Sparkle

Despues de resolver dependencias, genera la clave una vez:

```sh
xcodebuild -resolvePackageDependencies -project FactorialMacApp.xcodeproj -scheme FactorialMacApp -derivedDataPath build/DerivedData
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

El comando guarda la clave privada en tu llavero y muestra la clave publica. Esa clave publica esta en `SUPublicEDKey` dentro de `FactorialMacApp/Info.plist`. No exportes ni commitees la clave privada.

### Publicar una version automaticamente

Renueva la sesion de GitHub CLI si ha caducado:

```sh
gh auth login -h github.com
```

Despues de cada cambio, Codex debe ejecutar:

```sh
Scripts/publish_release.sh "Describe el cambio"
```

Ese comando sube `MARKETING_VERSION` con patch semver, incrementa `CURRENT_PROJECT_VERSION`, ejecuta tests, genera zip/appcast, commitea, pushea `main`, crea el tag `v<MARKETING_VERSION>` y publica el asset en GitHub Releases.

El zip queda como `dist/FactorialClock-<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>.zip` y el appcast apunta al asset del release.

El script compila con destino macOS generico para generar una app universal `arm64`/`x86_64` cuando Xcode tenga ambos SDKs disponibles.
