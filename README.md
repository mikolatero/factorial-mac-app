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
