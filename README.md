# LimpiadorMac

App nativa para macOS (SwiftUI) que analiza a fondo el disco, encuentra lo que ocupa espacio sin necesidad y **avisa de lo que no conviene borrar**. Hecha para un MacBook Air M2 con el disco casi lleno.

No borra nada sin confirmación. Cada elemento explica qué es, qué contiene, por qué es (o no) seguro, qué cuesta liberarlo y cómo se deshace. Lo que marca solo es siempre algo que se regenera o se vuelve a descargar; lo que puede ser valioso se enseña con su tamaño, pero nunca se marca solo.

Además de borrar, **libera sin borrar**: guarda comprimidos los archivos que llevan días sin cambiar (también tus apps cerradas), une copias idénticas para que el disco las guarde una sola vez y deja en iCloud los archivos que no abres hace meses.

## Qué encuentra

| Categoría | Ejemplos |
|---|---|
| Emuladores | Emuladores de Android (completos o «restablecer» sin borrarlos) y, aparte, su **arranque rápido** (`default_boot`, se marca con el emulador apagado) y los snapshots que guardaste a propósito. Emuladores de prueba que crean tus scripts fuera de `~/.android`. Imágenes del sistema que no usa ningún emulador, plataformas del SDK para las que no compila ningún proyecto, versiones viejas de build-tools/NDK/CMake (una build-tools que nombra el `build.gradle` o el último análisis de lint de un proyecto, para revisar; si de algún proyecto no se sabe cuál usa, solo con «Liberar al máximo»), descargas a medias del SDK. Sistemas iOS para simuladores y los inutilizables (`xcrun simctl runtime delete --unusable`) |
| Cachés de desarrollo | Gradle **por versión** (transformaciones, que se marcan si llevan 24 h sin usarse y ningún daemon de esa versión funciona; la caché de dependencias y los wrappers que usan tus proyectos, solo con «Liberar al máximo»), npm, Xcode, CocoaPods, pip, Poetry, uv, RubyGems, Bundler, NuGet, Kotlin/Native… Todo `~/.cache`. La caché del SDK de Flutter y las versiones de FVM. Versiones antiguas de Node, Python, Ruby, Rust y SDKMAN que no son la predeterminada; versiones anteriores de programas que se actualizan solos y los `.old` que dejan. **Homebrew** con su comando oficial (`brew cleanup`, leyendo antes `Cellar` sin ejecutar brew) y Docker (`docker builder prune`). Ollama: las piezas que ya no usa ningún modelo y las descargas a medias (marcadas), y cada modelo con lo que libera de verdad (para revisar). Hugging Face: las revisiones de un modelo que ya no usa ninguna rama |
| Cachés de aplicaciones | Cachés de apps (también las de contenedores y grupos de la App Store), cachés internas de apps Electron/Chromium, cachés seguras de apps de Apple, adjuntos de Mail ya abiertos y vídeos de fondos de pantalla |
| Temporales del sistema | Temporales y cachés que macOS guarda para tu usuario en `/var/folders`, agrupados por app, y los **temporales sueltos** que dejan las apps (los de ChatGPT/Codex). Clang, Metal y node-compile-cache, cada uno con su umbral y solo si su programa no está funcionando. Lo tuyo en `/tmp` de más de 24 h, salvo que tenga **resultados únicos** (informes, tablas, parches… sin copia idéntica en tus carpetas) |
| Restos de apps borradas | Datos, cachés, registros y agentes de inicio de apps desinstaladas, agrupados por app. Usa la firma de las apps instaladas para reconocer sus carpetas compartidas. Sin «Acceso total al disco», una lista de las apps desinstaladas que probablemente dejaron carpetas en los contenedores (sin tamaño: solo se informa) |
| Apps que no usas | Apps sin señales de uso en 3 meses, o que nunca abriste a los 30 días de llegar; nunca se marcan solas |
| Compilaciones | Por proyecto, separando los **intermedios de compilación** (se marcan si nada cambió en 24 h, nadie trabaja en el proyecto y no hay nada que no se regenere) de las salidas, los informes y las entregas, que se quedan para revisar: mientras trabajas en un proyecto, sus salidas (APK, `dist`, informes, resultados de pruebas, cobertura) van aparte y no se marcan nunca, ni con «Liberar al máximo». `node_modules`, `dist`, `.gradle`, `Pods`, cachés de Python, Unity, .NET, Terraform… Repositorios git con el historial sin empaquetar (`git gc` sin perder nada, solo con «Liberar al máximo») y avisos de otras copias del mismo repositorio y de puntos de restauración de Codex |
| Carpetas ocultas | Carpetas ocultas y `~/.local/share`, separando las cachés de una herramienta de su historial y configuración (una «caché» o «tmp» que nombra su `config.toml`, `settings.json`… es para revisar). Conversaciones de Codex de hace más de un mes. Programas de npm que el PATH tapa |
| Instaladores | `.dmg`, `.pkg`, `.apk`… indicando si la app ya está instalada o si hay una versión más nueva; actualizaciones `.ipsw`; instaladores de macOS; copias sueltas de apps que ya están en Aplicaciones (solo si son la misma versión, compilación y desarrollador; otra versión es para revisar); apps del Escritorio o de Descargas que son copia de una compilación tuya |
| Archivos olvidados | Descargas a medias, capturas de pantalla antiguas, lo que no abres en Descargas hace 3 meses, carpetas que llamaste «Eliminar» u «Old», carpetas sin cambios en un año y las **copias locales de iCloud Drive** que no abres hace 3 meses |
| Duplicados | Archivos idénticos (SHA-256): borrar la copia que sobra o **unirlas** como clones de APFS (siguen todas en su sitio y el disco guarda una) |
| Registros y fallos | Registros de apps, reportes de fallos, volcados de memoria de Java (`.hprof`) y registros de más de 20 MB fuera de Library |
| Archivos grandes | Más de 50 MB en tus carpetas y más de 200 MB escondidos en `~/Library`, sin repetir lo que ya ofreció otra categoría |
| Comprimir sin borrar | Conversaciones de Codex y Claude Code, runtimes y programas de herramientas y el SDK de Android que llevan días sin cambiar. Con «Liberar al máximo», también tus **apps cerradas** (Android Studio, ChatGPT…) y tus informes y entregas grandes |

## Liberar sin borrar

- **Compresión transparente de APFS** (la misma con la que macOS guarda sus apps): cada archivo se copia comprimido con `ditto --noclone --hfsCompression`, se compara byte a byte con el original, recibe sus permisos, atributos, ACL y fechas, y solo entonces se intercambia con él de golpe (`renamex_np`). Mientras el intercambio se puede deshacer, la copia no se deja escribir (así nada de lo que escriba otro programa se queda fuera). Si algo lo abre o lo cambia a mitad, se deshace; si la app se cierra de golpe, el original sigue intacto y la próxima limpieza, sea cual sea, recoge los restos (los temporales nunca se ofrecen como copias ni como archivos grandes). Salir con ⌘Q mientras se limpia espera a que termine el grupo de archivos en curso. Se leen igual y, si un programa vuelve a escribir en uno, macOS lo descomprime solo. El ahorro se calcula con una muestra de cada archivo, trozo a trozo (los trozos que casi no se comprimen, como imágenes en base64 dentro de una conversación, cuentan enteros): con conversaciones reales y programas, el total se desvía entre un 6 % por debajo y un 5 % por encima de lo que ahorra `ditto` de verdad. Nunca: lo abierto, lo reciente, los clones, bases de datos, discos virtuales, emuladores, `.git`, fotos, vídeos, zip ni lo de más de 512 MiB.
- **Apps** (solo con «Liberar al máximo»): las tuyas de `/Applications` y `~/Applications`, cerradas, sin actualizarse en el último día, que no son de Apple ni de la App Store, que no vienen ya comprimidas y en las que se ahorra al menos un 15 %. Antes se comprueba su firma y después otra vez (`SecStaticCodeCheckValidity`, como `codesign --verify --deep --strict`): comprimir no cambia ni un byte, y si la firma no validara se descomprimen solas al momento. No se tocan mientras están abiertas, mientras algo suyo funciona o mientras un actualizador (ShipIt, Sparkle…) trabaja con ellas. Al actualizarse vuelven a ocupar lo de antes. macOS solo deja modificar apps con el permiso **«Gestión de apps»**: si falta, se intenta con un solo archivo, no se toca nada más y se dice dónde activarlo. Para deshacerlo: **Análisis › Descomprimir una app**.
- **Tu material** (solo con «Liberar al máximo»): carpetas de 100 MB o más de informes (`build/reports`), entregas y resultados que no se marcan para borrar; dentro, solo lo que lleva 7 días sin cambiar.
- **Unir copias idénticas** como clones de APFS: cada copia sigue en su sitio, con su nombre, permisos y fechas.
- **iCloud Drive** (solo con «Liberar al máximo»): quita la copia local de lo que ya está subido, sin cambios ni conflictos y que nadie abrió en 3 meses. Sigue en iCloud y en su carpeta; se vuelve a descargar al abrirlo (clic derecho › «Descargar ahora» para tenerlo otra vez).

## Liberar al máximo

El botón **«Liberar al máximo»** reparte todo en bloques y dice lo que cuesta cada uno antes de hacerlo: lo que se regenera solo (lo mismo que el modo normal), lo que se libera sin borrar, lo que cuesta volver a descargar o recompilar, las apps abiertas que bloquean algo («Cerrar y limpiar», como ⌘Q y nunca a la fuerza), lo que marcaste tú, lo que nunca se marca (Revisar y Cuidado) y lo que se queda fuera por ahora (en uso o reciente). Se limpia en este orden: comandos oficiales, lo Seguro de mayor a menor sin pasar por la Papelera (salvo las apps, que van a ella), lo que marcaste tú (a la Papelera), comprimir y unir. Se puede detener entre un elemento y otro. Lo que entregas y los informes de un proyecto en el que trabajas no entran nunca; los de un proyecto que no tocas hace más de un mes, sí, y se dice. El resultado separa lo medido, lo comprimido, lo que está en la Papelera y lo purgable, y ofrece «Vaciar solo lo de esta limpieza».

## Medir de verdad

- **Libre de verdad**: no cuenta lo purgable (lo que macOS libera solo cuando le hace falta), que se enseña aparte.
- **Lo que libera cada elemento**: sin lo que comparte con clones de APFS que se quedan.
- **Lo liberado** se mide en el disco antes y después de limpiar (y se calcula, para explicar las diferencias).
- **Instantáneas locales de Time Machine**: se avisa de que retienen lo borrado y, con confirmación, se puede pedir a macOS que las adelgace (`tmutil thinlocalsnapshots / … 4`; las copias del disco de Time Machine no se tocan).
- Sin «Acceso total al disco», cuánto del disco no se pudo revisar.

## Seguridad

- **Evaluador de riesgo**: sube a *Cuidado* lo que contiene keystores de Android, claves o contraseñas, repositorios git, documentos o fotos, apps compiladas para publicar, respaldos o cosas en la nube.
- **Lo que no se regenera**: nunca da por seguro lo que vive dentro de un proyecto git, archivos de programas, entregas con sumas de verificación ni carpetas `build/`/`dist/` con bases de datos, modelos, trazas, emuladores o instaladores versionados.
- **En uso**: apps abiertas (por su identificador, sin confundir un ayudante con su app), programas por la ruta real de su ejecutable, archivos abiertos, carpetas de trabajo, sockets y `.pid` vivos (leídos con libproc), emuladores encendidos (también por sus candados), Gradle por versión y editores de JetBrains con el proyecto abierto. Lo que está en uso no se marca, y se vuelve a comprobar en el último momento antes de tocar cada cosa; lo que cambió después del análisis se salta. Si no se puede saber qué está funcionando, no se toca nada.
- **Rutas protegidas**: nunca toca la carpeta personal, `Library`, llaveros, `.ssh`, `.git` ni llaves de firma, aunque se seleccionen. Lo que se comprime nunca sale de tu carpeta personal (ni de tus apps, al comprimirlas) ni entra en Mail, Mensajes, Fotos, iCloud o los contenedores de las apps.
- **Deshacer**: lo que va a la Papelera se puede devolver a su sitio con un clic. Lo marcado como *Revisar* o *Cuidado* siempre va a la Papelera, y las apps (`.app`) también, aunque elijas eliminar definitivamente o uses «Liberar al máximo». Las apps comprimidas se descomprimen desde el menú Análisis.
- **Historial** de todo lo borrado, comprimido o ejecutado en `~/Library/Logs/LimpiadorMac/historial.log`.
- Ninguna acción que borra responde a la tecla Enter: hay que hacer clic.

## Cómo funciona

1. `Indice`: recorre la carpeta personal, los temporales de tu usuario en `/var/folders` y lo tuyo en `/tmp` en paralelo con `fts` y guarda, para cada carpeta, su tamaño real, lo que comparte con clones, su última actividad y qué contiene.
2. `Escaner`: cada categoría consulta el índice; lo que se puede comprimir se busca a la vez, en segundo plano.
3. `Evaluador`: aplica las reglas de seguridad y explica cada decisión.
4. `Limpiador` (con `Compresor`, `Clonador` y `Nube`) e `Historial`: limpian con comprobaciones de último momento y permiten deshacer.

## Compilar

Requisitos: macOS 14 o superior y Xcode (Swift 5.10+).

```bash
./crear-app.sh
```

Crea `LimpiadorMac.app` en la carpeta del proyecto.

### Firma estable (para no perder los permisos)

macOS recuerda el «Acceso total al disco» y la «Gestión de apps» por la firma de la app. Con la firma ad hoc de siempre, cada compilación es «otra app» y hay que volver a dar los permisos. Para evitarlo, crea una vez un certificado propio:

1. Abre **Acceso a Llaveros** (con Spotlight).
2. Menú **Acceso a Llaveros › Asistente para certificados › Crear un certificado…**
3. Nombre: `LimpiadorMac Local`. Tipo de identidad: **Raíz autofirmada**. Tipo de certificado: **Firma de código**. Crear.

`crear-app.sh` lo encuentra solo y firma con él (para usar otro nombre: `LIMPIADOR_FIRMA="Mi certificado" ./crear-app.sh`). La primera vez puede preguntar si `codesign` puede usar la llave: «Permitir siempre». Después de esa primera compilación da los permisos una vez más; a partir de ahí se conservan. Si no encuentra la identidad, firma ad hoc como antes y lo avisa. El script nunca crea certificados ni cambia ajustes.

Puedes comprobarlo con `codesign -d -r- LimpiadorMac.app`: con la firma estable dice `certificate leaf = H"…"` en vez de `cdhash`.

## Permisos

- **Acceso total al disco** (Ajustes del Sistema › Privacidad y seguridad): para ver los contenedores de las apps, la Papelera, Mail, Mensajes y lo demás que macOS protege (unos 30 GB en este Mac). Solo deja leer. La app lo vuelve a comprobar al volver a ella y ofrece analizar otra vez.
- **Gestión de apps** (misma sección): solo para comprimir apps. Sin él, las apps se dejan como están.

## Diagnóstico y pruebas

Para ver el análisis en la terminal, sin abrir ventanas y sin borrar nada:

```bash
.build/release/LimpiadorMac --diagnostico --motivos
```

Con `--rutas` imprime las rutas de los elementos que tienen varias, y con `--maximo` lo que haría «Liberar al máximo», por bloques (sin ejecutar nada).

Para probar las reglas con una carpeta personal de prueba en lugar de la tuya (solo en modo diagnóstico):

```bash
LIMPIADOR_CASA=/ruta/a/carpeta-de-prueba .build/release/LimpiadorMac --diagnostico
```

Con una casa de prueba también se pueden sustituir `/tmp` (`LIMPIADOR_TMP`), los temporales de `/var/folders` (`LIMPIADOR_TEMPORALES`, una carpeta con `T` y `C`), el PATH de la terminal (`LIMPIADOR_PATH`) y Homebrew (`LIMPIADOR_HOMEBREW`); con `LIMPIADOR_SIN_CTIME=1` no se exige la antigüedad del cambio de estado al comprimir. En una casa de prueba solo se miran las apps de su `Applications`, nunca las de verdad.
