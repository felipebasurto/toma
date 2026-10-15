<h1 align="center">
  <img src="https://raw.githubusercontent.com/felipebasurto/toma/main/docs/assets/toma-hero.svg" alt="Toma: ⇧⌘4, pero en vídeo. Graba una zona de la pantalla del Mac. MP4, HEVC o GIF." width="100%">
</h1>

<div align="center">

**⇧⌘4, pero en vídeo.**
Graba una zona de la pantalla del Mac y guárdala en MP4, HEVC o GIF. Nada más.

[![Versión](https://img.shields.io/github/v/release/felipebasurto/toma?label=versi%C3%B3n&color=2383E2)](https://github.com/felipebasurto/toma/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-26%2B-37352F)](https://github.com/felipebasurto/toma/releases/latest)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138)](https://swift.org)
[![Licencia](https://img.shields.io/github/license/felipebasurto/toma?label=licencia&color=787774)](LICENSE)

[Web](https://toma.felipebasurto.com) ·
[Descargar](https://github.com/felipebasurto/toma/releases/latest/download/Toma.dmg) ·
[Arquitectura](docs/arquitectura.md) ·
[Changelog](CHANGELOG.md)

</div>

Toma vive en la barra de menús. Pulsas un atajo, dibujas un rectángulo y graba. No tiene
ventana de ajustes, ni cuenta, ni editor. Solo graba una zona de la pantalla y la guarda bien.

## Instalar

1. Descarga **[Toma.dmg](https://github.com/felipebasurto/toma/releases/latest/download/Toma.dmg)** y arrastra Toma a Aplicaciones.
2. Ábrela. Como Toma no está notarizada, la primera vez macOS la bloquea: ve a **Ajustes › Privacidad y seguridad** y pulsa **Abrir igualmente**.
3. Concede el permiso de **Grabación de pantalla** y vuelve a abrir Toma.

Requiere macOS 26 o posterior. Es universal (Apple silicon e Intel) y ocupa menos de 1 MB.

## Uso

<p align="center">
  <img src="docs/assets/tarjeta.png" alt="La miniatura de Toma tras grabar: el clip en bucle, su duración y los formatos MP4, HEVC y GIF, con un botón de copiar." width="380">
</p>

| | |
|---|---|
| <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>4</kbd> | Empieza: arrastra una zona. Graba en cuanto sueltas. |
| <kbd>Espacio</kbd> mientras arrastras | Mueve la zona. |
| <kbd>⇧</kbd> mientras arrastras | Fija un eje. |
| <kbd>⌥</kbd> mientras arrastras | Crece desde el centro. |
| <kbd>Esc</kbd> | Cancela la selección. |
| <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>4</kbd> otra vez, o **■ 0:07** en la barra | Termina la grabación. |

Al terminar aparece una miniatura abajo a la derecha, como con las capturas:

- **MP4 · HEVC · GIF**: pulsa uno para guardar en ese formato.
- **Copiar**: deja el archivo en el portapapeles, listo para pegar en Slack, Mail o WhatsApp.
- **Arrastrar**: suelta la miniatura en cualquier app o carpeta.
- **No hacer nada**: a los 6 s se guarda en el último formato que usaste.
- **×**: descarta la grabación.

Si pulsas el atajo con la miniatura en pantalla, Toma guarda la grabación y empieza otra.

## Formatos

| | Para qué | 4 s de texto desplazándose, 1120 × 720 |
|---|---|---|
| **MP4** | H.264, funciona en todas partes | 0,46 MB |
| **HEVC** | La mitad de peso, ideal en Apple y navegadores modernos | 0,25 MB |
| **GIF** | Animación sin reproductor, para README, chats y docs | Nítido o ligero |

Toma graba primero un original de alta calidad y lo recodifica según la calidad deseada,
no según un tamaño fijo. El texto sigue nítido y una pantalla quieta casi no pesa. El formato
que sueles elegir se empieza a codificar mientras miras la miniatura, así que guardarlo es inmediato.

El GIF usa un codificador propio pensado para pantallas. Cada fotograma solo guarda lo que
cambió y los colores de la interfaz se mantienen exactos. Los degradados se difuminan con
suavidad, sin bandas.

## Opciones

En el menú de la barra, cada una muestra su valor:

- **Guardar en**: una carpeta tuya, o la misma que usan las capturas de pantalla (por defecto).
- **Tamaño del GIF**: *Nítido* (resolución completa, 20 fps) o *Ligero* (640 px, 15 fps).
- **Sonido**: sin sonido, el sonido del Mac, o el del Mac y tu micrófono.
- **Abrir al iniciar sesión**.

## Privacidad

Todo ocurre en tu Mac. Toma no se conecta a internet, no tiene analíticas y no guarda nada
fuera de la carpeta que eliges. Las copias al portapapeles se borran pasado un día. Las ventanas
de Toma nunca aparecen en sus propias grabaciones.

## Compilar desde el código

Necesitas Xcode 26 (Swift 6.2). No hay dependencias.

```bash
git clone https://github.com/felipebasurto/toma.git
cd toma
./build.sh        # → Toma.app
./build.sh dmg    # → Toma.app y Toma.dmg
```

Si tienes un certificado de desarrollo, `build.sh` firma con él y el permiso de Grabación de
pantalla se mantiene entre compilaciones.

## Cómo está hecho

Son unas 2.300 líneas de Swift en un solo módulo, organizadas por lo que cada parte sabe:

| Archivo | Qué sabe |
|---|---|
| `Toma.swift` | El estado (una máquina con un solo verbo: `toggle()`) y la historia de una grabación. |
| `Region.swift` | Coordenadas: una zona solo puede existir si se puede grabar tal cual. |
| `Recording.swift` | ScreenCaptureKit y permisos. |
| `Library.swift` | Carpetas, nombres, formatos y recodificación. |
| `GIF.swift` | El codificador de GIF. |
| `Overlay.swift`, `ResultCard.swift`, `StatusItem.swift` | La interfaz. |

El porqué de cada decisión está en [docs/arquitectura.md](docs/arquitectura.md).

## Licencia

[MIT](LICENSE). Hecho por [Felipe Basurto](https://felipebasurto.com).
