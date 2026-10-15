# Changelog

Todos los cambios relevantes se documentan aquí. El formato sigue
[Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el proyecto usa
[Versionado Semántico](https://semver.org/lang/es/).

## [Unreleased]

## [1.2.0] - 2026-10-15

### Añadido

- Instalador **Toma.dmg**: arrastra Toma a Aplicaciones.
- Icono propio de la app y del disco.
- Binario universal: Apple silicon e Intel.
- Web en [toma.felipebasurto.com](https://toma.felipebasurto.com).
- `./build.sh dmg` genera el disco. La versión vive en el archivo `VERSION`.

## [1.1.0] - 2026-10-15

### Añadido

- **Guardar en**: elige la carpeta desde el menú. Por defecto, la de las capturas de pantalla.
- **HEVC**: tercer formato, la mitad de peso que MP4.
- **Copiar**: el botón de la miniatura deja el archivo en el portapapeles.
- **Tamaño del GIF**: nítido (resolución completa, 20 fps) o ligero (640 px, 15 fps).
- **Sonido**: sin sonido, el del Mac, o el del Mac y el micrófono. Todas las pistas se
  mezclan en una sola, porque muchos reproductores solo leen la primera.
- La miniatura muestra la duración del clip y una descripción de cada formato.
- Anillo de progreso en la barra de menús mientras se guarda, y ✓ al copiar.

### Cambiado

- MP4 y HEVC se recodifican según la calidad deseada: de 5 a 10 veces más ligeros con el
  texto igual de nítido.
- El formato que sueles elegir se codifica mientras miras la miniatura, así que guardarlo
  es inmediato.
- Codificador de GIF propio. Guarda solo lo que cambia, mantiene exactos los colores de la
  interfaz, difumina los degradados sin bandas y es el doble de rápido que ImageIO.
- La grabación ya no consume CPU extra: 0,13 s de CPU para 4 s a 60 fps.

### Corregido

- La miniatura no llegaba a aparecer: se quedaba fuera de la pantalla.
- Las ventanas de Toma ya se ven en capturas y en videollamadas. Siguen sin aparecer en sus
  propias grabaciones.
- Si una exportación falla, la grabación se guarda en MP4 en lugar de perderse.

## [1.0.0] - 2026-10-15

### Añadido

- Primera versión. <kbd>⌥⇧⌘4</kbd>, arrastra una zona y graba. Los modificadores son los de ⇧⌘4.
- Miniatura tras grabar con MP4 o GIF y arrastrar para compartir.
- Grabación a resolución nativa (Retina) con ScreenCaptureKit, sin que Toma salga en el vídeo.

[Unreleased]: https://github.com/felipebasurto/toma/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/felipebasurto/toma/compare/v1.1...v1.2.0
[1.1.0]: https://github.com/felipebasurto/toma/releases/tag/v1.1
[1.0.0]: https://github.com/felipebasurto/toma/commits/main
