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

## Integracion con Factorial

Esta v1 no guarda contrasenas ni usa API keys. Reutiliza una sesion web iniciada por el usuario y ejecuta el fichaje mediante WebKit. Si Factorial cambia los textos o estructura del boton de fichaje, habra que ajustar los selectores en `FactorialClockingClient`.

## Tests

```sh
xcodebuild test -project FactorialMacApp.xcodeproj -scheme FactorialMacApp -destination 'platform=macOS'
```
