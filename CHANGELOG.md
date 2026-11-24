# Changelog

Todos los cambios relevantes se documentan aquí. El formato sigue
[Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el proyecto usa
[Versionado Semántico](https://semver.org/lang/es/).

## [Unreleased]

## [1.6.0] - 2026-11-24

### Cambiado

- **Toma codifica mientras graba.** Los codificadores de hardware del Mac escriben el MP4 y el
  HEVC a la vez que llegan los fotogramas, así que al parar ya están terminados: guardar en MP4
  o HEVC pasa de ~1 s por cada 7 s de vídeo a ser instantáneo. Una sola pasada de compresión en
  lugar de dos: más nitidez con un tamaño parecido (PSNR +1,3 a +1,7 dB, SSIM 0,993 → 0,997;
  el MP4 pesa hasta un 8 % más en pantallas tranquilas).
- **GIF de 4 a 5 veces más rápido y hasta un 33 % más ligero.** Se crea desde una fuente casi
  sin pérdida grabada en paralelo, compara fotogramas con SIMD en todos los núcleos (14× más
  rápido, mismo resultado exacto) y, si sueles elegir GIF, empieza mientras miras la miniatura.

### Corregido

- **Colores exactos.** Los vídeos y los GIF salían con los tonos medios un ~9 % más oscuros que
  la pantalla en Chrome, Slack, Windows y en todos los GIF: la grabación convertía los colores a
  la curva de vídeo BT.709. Ahora se conservan tal cual (sRGB) y se ven igual en todas partes.
- **Las grabaciones ya no se pierden al parar.** Desde la 1.3.0, Toma quitaba la salida de
  grabación antes de detener la captura. En macOS 26.6 eso interrumpe la captura y el vídeo a
  menudo no se terminaba de escribir: al parar salía «La grabación se interrumpió». Ahora Toma
  escribe y cierra sus propios archivos al parar, sin depender de ese aviso del sistema.

## [1.5.0] - 2026-11-24

### Añadido

- **Confirmar la zona antes de grabar** (desactivado por defecto, en el menú). Tras arrastrar una
  zona, Toma enseña una imagen de exactamente lo que se va a grabar, la marca en rojo en la
  pantalla, dice dónde se guardará (y deja cambiar la carpeta ahí mismo) y pregunta si grabar,
  volver a dibujarla o cancelar. Nada se graba hasta pulsar «Grabar».
- **La ventana de bienvenida** permite elegir la carpeta y activar la confirmación de la zona.

## [1.4.0] - 2026-11-13

### Cambiado

- **macOS 15.3 o posterior.** Toma abre en Sequoia 15.3 y en las versiones que hay desde ahí
  hasta macOS 26.

### Corregido

- Al parar, la grabación se cierra aunque Sequoia no avise de que el archivo ya está listo.
  En macOS 26 el aviso sigue llegando y el resultado es el mismo.

## [1.3.0] - 2026-11-05

### Añadido

- **Interfaz en inglés**. Toma sigue el idioma del sistema: español si lo prefieres, inglés en
  cualquier otro caso. Los textos viven en `Resources/<idioma>.lproj/Localizable.strings`.
- **Actualizaciones desde la app**. Toma busca la última versión en GitHub una vez al día. Si hay
  una nueva, el menú muestra «Actualizar a Toma x.y.z…»: descarga el DMG, comprueba su SHA-256 y la
  firma (mismo Developer ID que la app en uso), reemplaza la app y se reabre. También hay
  «Buscar actualizaciones…».

### Cambiado

- Los archivos nuevos se llaman «Screen Recording 2026-10-15 at 21.03.12» en inglés; en español
  se mantiene «Grabación de pantalla 2026-10-15 a las 21.03.12».

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

[Unreleased]: https://github.com/felipebasurto/toma/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/felipebasurto/toma/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/felipebasurto/toma/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/felipebasurto/toma/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/felipebasurto/toma/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/felipebasurto/toma/compare/v1.1...v1.2.0
[1.1.0]: https://github.com/felipebasurto/toma/releases/tag/v1.1
[1.0.0]: https://github.com/felipebasurto/toma/commits/main
