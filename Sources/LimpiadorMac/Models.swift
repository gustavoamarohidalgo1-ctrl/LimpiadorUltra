import Foundation

/// Qué tan seguro es borrar un elemento.
enum Riesgo: Int, Comparable, Hashable {
    case seguro, revisar, cuidado

    static func < (a: Riesgo, b: Riesgo) -> Bool { a.rawValue < b.rawValue }

    var etiqueta: String {
        switch self {
        case .seguro: return "Seguro"
        case .revisar: return "Revisar"
        case .cuidado: return "Cuidado"
        }
    }

    var veredicto: String {
        switch self {
        case .seguro: return "Puedes borrarlo"
        case .revisar: return "Revísalo antes de borrar"
        case .cuidado: return "No lo borres sin revisar"
        }
    }

    var explicacion: String {
        switch self {
        case .seguro: return "Se regenera solo o no se necesita. Puedes borrarlo sin problema."
        case .revisar: return "Probablemente no lo necesitas, pero confirma antes de borrarlo."
        case .cuidado: return "Puede contener datos que quieras conservar."
        }
    }

    var icono: String {
        switch self {
        case .seguro: return "checkmark.shield.fill"
        case .revisar: return "exclamationmark.triangle.fill"
        case .cuidado: return "xmark.octagon.fill"
        }
    }
}

/// Qué tan grave es cada razón que da el analizador.
enum NivelMotivo: Int, Comparable, Hashable {
    case bien, info, aviso, peligro

    static func < (a: NivelMotivo, b: NivelMotivo) -> Bool { a.rawValue < b.rawValue }
}

/// Una razón concreta de por qué algo es (o no) seguro de borrar.
struct Motivo: Hashable {
    var nivel: NivelMotivo
    var icono: String
    /// Versión corta para la fila de la lista.
    var etiqueta: String
    /// Explicación completa para el panel de detalle.
    var texto: String

    static func bien(_ icono: String, _ etiqueta: String, _ texto: String) -> Motivo {
        Motivo(nivel: .bien, icono: icono, etiqueta: etiqueta, texto: texto)
    }

    static func info(_ icono: String, _ etiqueta: String, _ texto: String) -> Motivo {
        Motivo(nivel: .info, icono: icono, etiqueta: etiqueta, texto: texto)
    }

    static func aviso(_ icono: String, _ etiqueta: String, _ texto: String) -> Motivo {
        Motivo(nivel: .aviso, icono: icono, etiqueta: etiqueta, texto: texto)
    }

    static func peligro(_ icono: String, _ etiqueta: String, _ texto: String) -> Motivo {
        Motivo(nivel: .peligro, icono: icono, etiqueta: etiqueta, texto: texto)
    }
}

/// Lo que hay dentro de una carpeta, contado mientras se indexa el disco.
struct Contenido: Hashable {
    var documentos: Int32 = 0
    var fotos: Int32 = 0
    var videos: Int32 = 0
    var audio: Int32 = 0
    var codigo: Int32 = 0
    var bases: Int32 = 0
    var bibliotecas: Int32 = 0

    mutating func sumar(_ o: Contenido) {
        documentos += o.documentos
        fotos += o.fotos
        videos += o.videos
        audio += o.audio
        codigo += o.codigo
        bases += o.bases
        bibliotecas += o.bibliotecas
    }

    /// Hay suficientes archivos personales como para avisar.
    var esPersonal: Bool {
        documentos > 0 || fotos >= 10 || videos >= 3 || audio >= 5 || bibliotecas > 0
    }

    var resumenPersonal: String {
        var partes: [String] = []
        if bibliotecas > 0 { partes.append(bibliotecas == 1 ? "una biblioteca de fotos o vídeo" : "\(bibliotecas) bibliotecas de fotos o vídeo") }
        if documentos > 0 { partes.append(documentos == 1 ? "1 documento" : "\(documentos) documentos") }
        if fotos > 0 { partes.append(fotos == 1 ? "1 foto" : "\(fotos) fotos") }
        if videos > 0 { partes.append(videos == 1 ? "1 vídeo" : "\(videos) vídeos") }
        if audio > 0 { partes.append(audio == 1 ? "1 audio" : "\(audio) audios") }
        return Formato.lista(partes)
    }

    var vacio: Bool { self == Contenido() }
}

/// Algo que puede estar usando un elemento en este momento.
/// Aparte de esto, cualquier elemento cuenta como «en uso» si un programa tiene abierto algo de sus rutas
/// (ver `Procesos.quienUsa(_:)`).
enum EnUso: Hashable {
    /// Una app o servicio. `claves` son identificadores (com.empresa.app) o nombres.
    case app(nombre: String, claves: [String])
    /// Un emulador de Android: encendido si hay un proceso con `-avd <avd>`. Con `carpeta` (la del .avd) también
    /// cuenta como encendido si un programa tiene algo abierto dentro o si un candado del emulador (*.lock) es de un
    /// proceso vivo.
    case emulador(avd: String, carpeta: String? = nil)
    case simulador(udid: String)
    /// Cualquier daemon de Gradle: para lo que comparten todas las versiones (dependencias, temporales…).
    case gradle
    /// Un daemon de Gradle de esa versión (o uno cuya versión no se pudo leer), o un programa con archivos
    /// abiertos en las cachés o en la distribución de esa versión.
    case gradleVersion(String)
    /// Un programa de terminal: se busca `patron` en la lista de procesos.
    case proceso(nombre: String, patron: String)
    /// Una carpeta o archivo concreto (`raiz`): está en uso si algún programa trabaja dentro (su carpeta actual),
    /// tiene un archivo abierto ahí, se ejecuta desde ahí, tiene cargada una librería de ahí o la menciona al arrancar.
    case rutas(nombre: String, raiz: String)
    /// Programas por el nombre exacto de su ejecutable (clang, swift-frontend…): en uso si alguno está en marcha.
    case programas(nombre: String, ejecutables: Set<String>)
    /// Un proyecto de código (`raiz`, su carpeta): en uso como `.rutas` o si un editor de JetBrains que está abierto
    /// (Android Studio, IntelliJ…) lo tiene abierto, según su lista de proyectos recientes.
    case proyecto(nombre: String, raiz: String)
    /// Algo de /tmp (`raiz`, una carpeta o un archivo): en uso como `.rutas` (que también ve los sockets que un
    /// programa vivo escucha ahí dentro) o si dentro hay un archivo *.pid con el número de un proceso vivo.
    case carpetaTemporal(nombre: String, raiz: String)
    /// Una app instalada (`ruta`, su .app): en uso si está abierta (por su identificador `id`), si algún programa se
    /// ejecuta desde dentro o tiene algo suyo abierto (como `.rutas`), o si un actualizador está trabajando (ShipIt,
    /// Sparkle, Microsoft AutoUpdate…): mientras se actualiza no se toca.
    case appInstalada(nombre: String, id: String, ruta: String)

    var descripcion: String {
        switch self {
        case .app(let nombre, _): return nombre
        case .emulador(let avd, _): return "El emulador \(avd.replacingOccurrences(of: "_", with: " "))"
        case .simulador: return "El simulador"
        case .gradle: return "Gradle (Android Studio)"
        case .gradleVersion(let v): return "Gradle \(v)"
        case .proceso(let nombre, _): return nombre
        case .rutas(let nombre, _): return nombre
        case .programas(let nombre, _): return nombre
        case .proyecto(let nombre, _): return nombre
        case .carpetaTemporal(let nombre, _): return nombre
        case .appInstalada(let nombre, _, _): return nombre
        }
    }
}

/// En qué modo se puede marcar solo un elemento Seguro. El modo normal solo marca los de nivel `.normal`; los demás
/// quedan preparados para «Liberar al máximo» (`PlanMaximo`), que muestra lo que cuesta cada nivel antes de marcarlo.
enum NivelMarcado: Int, Comparable, Hashable {
    /// Se regenera solo, sin esperas que se noten. Lo único que puede pedir internet es una caché de descargas (npm, pip,
    /// Homebrew…): se vuelve a bajar sola, y solo lo que haga falta, la próxima vez que instales algo.
    case normal
    /// Cuesta algo que el modo normal no gasta: volver a descargar, recompilar lo que se usó hace unas horas…
    case maximo
    /// Solo cerrando antes una app que lo tiene abierto. El análisis no lo pone: qué bloquea cada app abierta se mira al
    /// momento (`CierreDeApps`), y lo que libera se ofrece app por app con «Cerrar y limpiar».
    case cerrarApp
    /// Solo con la contraseña de administrador (todavía no hay nada de este nivel).
    case administrador
    /// Nunca se marca solo: lo que no es Seguro, y las salidas de compilación de un proyecto en el que trabajas.
    case nunca

    static func < (a: NivelMarcado, b: NivelMarcado) -> Bool { a.rawValue < b.rawValue }
}

/// Lo que cuesta liberar algo, para explicarlo antes de hacerlo.
enum Coste: Hashable {
    /// Se vuelve a descargar (necesita internet).
    case descarga(bytes: Int64)
    /// La próxima compilación de ese proyecto se hace desde cero (más lenta).
    case recompilacion(proyecto: String)
    /// El emulador arranca en frío la próxima vez (uno o dos minutos más).
    case arranqueEnFrio
    /// Vuelve a ocupar lo mismo cuando esa app se actualice.
    case seDeshaceAlActualizar(app: String)
    /// Gasta un rato de procesador (comprimir, volver a generar índices…).
    case tiempoCPU
    /// Se borran también las salidas de la compilación de ese proyecto (lo que entregas, los informes y los resultados de
    /// pruebas): se rehacen al compilar o al pasar las pruebas, pero no es una caché.
    case borraSalidas(proyecto: String)

    var texto: String {
        switch self {
        case .descarga(let bytes):
            return bytes > 0 ? "Se vuelve a descargar (unos \(Formato.bytes(bytes)); necesita internet)" : "Se vuelve a descargar (necesita internet)"
        case .recompilacion(let proyecto): return "La próxima compilación de \(proyecto) se hace desde cero (más lenta)"
        case .arranqueEnFrio: return "El emulador arranca en frío la próxima vez (uno o dos minutos más)"
        case .seDeshaceAlActualizar(let app): return "Vuelve a ocupar lo mismo cuando \(app) se actualice"
        case .tiempoCPU: return "Tarda un rato de procesador"
        case .borraSalidas(let proyecto):
            return "Se borra también lo que entrega \(proyecto) (APK, AAB, dist…) y sus informes y resultados de pruebas; se rehacen al compilar o al pasar las pruebas"
        }
    }
}

/// Categorías en las que el analizador agrupa lo que encuentra.
enum Categoria: String, CaseIterable, Identifiable, Hashable {
    case emuladores
    case desarrollo
    case cachesApps
    case sistema
    case restos
    case apps
    case proyectos
    case herramientas
    case instaladores
    case olvidados
    case grandes
    case duplicados
    case registros
    case papelera
    case comprimir

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .emuladores: return "Emuladores"
        case .desarrollo: return "Cachés de desarrollo"
        case .cachesApps: return "Cachés de aplicaciones"
        case .sistema: return "Temporales del sistema"
        case .restos: return "Restos de apps borradas"
        case .apps: return "Apps que no usas"
        case .proyectos: return "Compilaciones"
        case .herramientas: return "Carpetas ocultas"
        case .instaladores: return "Instaladores olvidados"
        case .olvidados: return "Archivos olvidados"
        case .grandes: return "Archivos grandes"
        case .duplicados: return "Archivos duplicados"
        case .registros: return "Registros y fallos"
        case .papelera: return "Papelera"
        case .comprimir: return "Comprimir sin borrar"
        }
    }

    var subtitulo: String {
        switch self {
        case .emuladores:
            return "Emuladores de Android (también los de prueba que crean tus scripts), sus datos internos, imágenes del sistema y sistemas iOS para simuladores."
        case .desarrollo:
            return "Cachés de Gradle, npm, Xcode y otras herramientas, separadas por versión y según lo que usan tus proyectos."
        case .cachesApps:
            return "Archivos temporales de navegadores y apps, incluidas las cachés internas que guardan junto a sus datos."
        case .sistema:
            return "Temporales y cachés que macOS guarda para tu usuario fuera de tu carpeta personal (/var/folders), agrupados por app, y lo tuyo en /tmp."
        case .restos:
            return "Lo que dejaron las apps que ya no están instaladas, agrupado por app: datos, cachés, registros y agentes de inicio."
        case .apps:
            return "Apps que llevan meses sin abrirse o que nunca abriste, según el registro de uso de macOS."
        case .proyectos:
            return "Carpetas regenerables de tus proyectos (build, node_modules…), agrupadas por proyecto. Tu código no se toca."
        case .herramientas:
            return "Carpetas ocultas de tu carpeta personal, separando sus cachés de su historial y configuración."
        case .instaladores:
            return "Instaladores (.dmg, .pkg, .apk…), actualizaciones de iPhone descargadas y copias sueltas de apps. Te digo si la app ya está instalada."
        case .olvidados:
            return "Descargas a medias, capturas de pantalla antiguas, descargas que no abres hace meses, carpetas que llamaste «Eliminar», «Old» o «tmp», carpetas que nadie toca hace más de un año y archivos de iCloud Drive que no abres hace meses (se puede quitar su copia local sin borrarlos de iCloud)."
        case .grandes:
            return "Archivos de más de 100 MB en tus carpetas y los más pesados que hay escondidos en Library."
        case .duplicados:
            return "Archivos idénticos byte a byte. Puedes borrar las copias que sobran (siempre se conserva una) o unirlas sin borrar ninguna: siguen todas en su sitio y el disco las guarda una sola vez. Los clones que ya no ocupan espacio extra no se cuentan."
        case .registros:
            return "Registros (logs) de apps y reportes de fallos. Solo sirven para diagnosticar errores."
        case .papelera:
            return "Lo que ya enviaste a la Papelera sigue ocupando espacio hasta que la vacías."
        case .comprimir:
            return "Archivos que llevan días sin cambios y se pueden guardar comprimidos (la compresión de APFS, la misma de macOS): ocupan menos y se leen igual. También tus apps cerradas y tus informes y entregas grandes, solo con «Liberar al máximo». No se borra nada."
        }
    }

    var icono: String {
        switch self {
        case .emuladores: return "iphone.gen3"
        case .desarrollo: return "hammer.fill"
        case .cachesApps: return "square.stack.3d.up.fill"
        case .sistema: return "gearshape.2.fill"
        case .restos: return "puzzlepiece.extension.fill"
        case .apps: return "square.grid.2x2.fill"
        case .proyectos: return "shippingbox.fill"
        case .herramientas: return "eye.slash.fill"
        case .instaladores: return "opticaldiscdrive.fill"
        case .olvidados: return "tray.full.fill"
        case .grandes: return "doc.fill"
        case .duplicados: return "doc.on.doc.fill"
        case .registros: return "list.bullet.rectangle.fill"
        case .papelera: return "trash.fill"
        case .comprimir: return "rectangle.compress.vertical"
        }
    }
}

/// Qué hacer con un elemento al limpiarlo.
enum AccionLimpieza: Hashable {
    /// Borra las rutas del elemento (a la Papelera o definitivamente).
    case borrar
    /// Elimina un simulador de iOS con `xcrun simctl delete`.
    case eliminarSimulador(udid: String)
    /// Borra el contenido de un simulador de iOS, sin eliminar el dispositivo.
    case vaciarSimulador(udid: String)
    /// Elimina un sistema iOS para simuladores con `xcrun simctl runtime delete`.
    case eliminarRuntime(id: String)
    /// Vacía la Papelera del usuario.
    case vaciarPapelera
    /// Empaqueta el historial de un repositorio git con `git gc`: no borra nada de lo que git guarda.
    case compactarGit(repo: String)
    /// Elimina los temporales sueltos de una app («.com.openai.codex.AbC123»: `prefijo` más el sufijo de 6 letras que
    /// pone mkstemp) que hay directamente en `carpeta`. Al limpiar vuelve a listarlos y salta los que algún programa
    /// tiene abiertos y los que cambiaron hace menos de `minHoras`.
    case borrarSueltos(carpeta: String, prefijo: String, minHoras: Double)
    /// Guarda comprimidos (compresión transparente de APFS) los archivos que cumplen las reglas de `Compresor` en esas
    /// carpetas. No borra nada: se leen igual. Al limpiar se vuelven a buscar y se salta lo que esté abierto.
    case comprimir(Compresion)
    /// Convierte copias idénticas en clones de APFS (`Clonador`): todas siguen en su sitio, con su nombre, sus permisos y
    /// sus fechas, pero el disco guarda su contenido una sola vez. No borra nada.
    case clonar(Clonacion)
    /// Ejecuta el comando oficial de una herramienta («brew cleanup», «xcrun simctl runtime delete --unusable», «docker
    /// builder prune -f»…) con esas variables de entorno y, como mucho, `limite` segundos. Lo que borra lo decide la
    /// herramienta (no pasa por la Papelera); su salida queda en el historial.
    case comando(programa: String, argumentos: [String], entorno: [String: String], limite: TimeInterval)
    /// Quita la copia local de archivos de iCloud Drive que ya están subidos y sin cambios (`Nube`): siguen en iCloud y en
    /// la carpeta (con su nombre), y se vuelven a descargar solos al abrirlos. Al limpiar se vuelven a buscar uno por uno.
    case quitarDescarga(QuitarDescarga)

    /// Borra algo para siempre, sin pasar por la Papelera.
    var esIrreversible: Bool {
        switch self {
        case .borrar, .compactarGit, .comprimir, .clonar, .quitarDescarga: return false
        case .eliminarSimulador, .vaciarSimulador, .eliminarRuntime, .vaciarPapelera, .borrarSueltos, .comando: return true
        }
    }

    /// No borra nada: solo cambia cómo se guarda (comprimir, unir copias idénticas, dejar en iCloud solo la copia de la
    /// nube). Lo de dentro no corre ningún riesgo.
    var noBorraNada: Bool {
        switch self {
        case .comprimir, .clonar, .quitarDescarga: return true
        default: return false
        }
    }

    /// Une copias idénticas (para los textos de la interfaz, que distinguen comprimir de unir).
    var une: Bool {
        if case .clonar = self { return true }
        return false
    }

    /// Quita la copia local de archivos de iCloud (no se comprime nada: cuesta volver a descargarlos al abrirlos).
    var quitaDescarga: Bool {
        if case .quitarDescarga = self { return true }
        return false
    }

    /// Empaqueta el historial de git (`git gc` sin podar): no borra nada de lo que git guarda.
    var compactaGit: Bool {
        if case .compactarGit = self { return true }
        return false
    }

    /// Comprime apps instaladas (E11): para los textos que hablan de la firma y del permiso «Gestión de apps».
    var comprimeApps: Bool {
        if case .comprimir(let c) = self { return c.apps }
        return false
    }

    /// El comando tal como se escribiría en la terminal, para enseñarlo antes de ejecutarlo (nil si no es un comando).
    var lineaDeComando: String? {
        guard case .comando(let programa, let argumentos, _, _) = self else { return nil }
        return ([Rutas.nombre(programa)] + argumentos).joined(separator: " ")
    }
}

struct Elemento: Identifiable, Hashable {
    let id = UUID()
    var nombre: String
    /// Qué es.
    var detalle: String
    /// Qué pasa si lo borras.
    var consecuencia: String
    var rutas: [URL]
    var tamanosRutas: [Int64] = []
    /// Lo que ocupa en disco.
    var tamano: Int64 = 0
    /// Tamaño que no sale de las rutas (por ejemplo, un sistema iOS que gestiona Xcode).
    var tamanoFijo: Int64? = nil
    /// Lo que se libera de verdad al borrarlo: lo que ocupa menos lo que comparte con clones de APFS que se quedan
    /// (dos copias pueden compartir los mismos bloques, y borrar una no libera nada). nil si no se midió
    /// (simuladores, la Papelera…): entonces se cuenta lo que ocupa.
    var liberable: Int64? = nil
    /// Lo mismo, ruta por ruta (para no contar dos veces lo que está en dos elementos).
    var liberablesRutas: [Int64] = []
    /// De lo que ocupa, lo que comparte con archivos de fuera que se quedan (clones): no se libera al borrarlo.
    /// El resto de la diferencia entre lo que ocupa y lo que libera son copias de dentro que el disco guarda una vez.
    var retenido: Int64 = 0
    var ultimoUso: Date? = nil
    var categoria: Categoria
    var riesgo: Riesgo
    var seleccionado: Bool = false
    /// Lo que recomendó el análisis (para «Seleccionar lo recomendado»).
    var recomendado = false
    /// Lo que el análisis marcaría en su nivel si nada lo estuviera usando: es Seguro, cumple las reglas de quien lo
    /// encontró (24 h quieto, ningún proyecto lo usa…) y no tiene más avisos que los de «algo lo usa ahora» o «no pude
    /// comprobarlo», que se vuelven a mirar en el momento. El modo normal marca los de nivel `.normal` que nada usa;
    /// «Liberar al máximo», también los de nivel `.maximo`; y «Cerrar y limpiar», los que bloquea una app abierta.
    var marcable = false
    var accion: AccionLimpieza = .borrar
    var motivos: [Motivo] = []
    var enUso: EnUso? = nil
    /// Durante el análisis se comprobó que algo lo está usando.
    var abiertoAhora = false
    /// Quién lo estaba usando (una app, un programa o un proceso con archivos abiertos ahí dentro).
    var usadoPor: String? = nil
    /// App o herramienta a la que pertenece.
    var dueno: String? = nil
    /// Disco montado que hay que expulsar antes de borrar (instaladores abiertos).
    var imagenMontada: String? = nil
    var contenido = Contenido()
    /// En qué modo se puede marcar solo. El modo normal nunca marca los de otro nivel (ver `NivelMarcado`).
    var nivel: NivelMarcado = .normal
    /// Lo que cuesta liberarlo (descargas, recompilaciones…).
    var costes: [Coste] = []
    /// Lo último que cambió dentro según el análisis, en lo que solo se marca si lleva un tiempo quieto (intermedios
    /// de compilación, transformaciones de Gradle): al limpiar, si algo cambió después, no se toca.
    var cambioAnalizado: Date? = nil
    /// Al comprimir o unir copias: qué archivos se cambiarían y cuánto se espera ahorrar con cada uno (`tamano` es ese
    /// ahorro).
    var prevision: PrevisionCompresion? = nil
    /// Las copias que tienen que seguir en su sitio para poder borrarlo sin perder nada: lo de /tmp se ofrece como Seguro
    /// porque sus resultados (informes, tablas…) también están en tus carpetas. Al limpiar se vuelven a mirar.
    var copiasExigidas: [CopiaExigida] = []
    /// El usuario lo desmarcó a mano después de que el análisis (o «Liberar al máximo») lo marcara: «Liberar al máximo»
    /// y «Cerrar y limpiar» lo respetan y no lo vuelven a incluir.
    var desmarcadoAMano = false

    var rutaPrincipal: URL { rutas[0] }

    /// Las rutas en las que un archivo abierto por otro programa hace que el elemento entero esté «en uso». Los
    /// temporales sueltos (`.borrarSueltos`) no cuentan su carpeta, ni lo que se comprime (`.comprimir`) o se deja solo
    /// en iCloud (`.quitarDescarga`) las suyas: la acción salta uno a uno los archivos que están abiertos. Al unir copias cuentan todas: si una está abierta, el
    /// grupo no se toca. En un comando, lo que va a quitar (las versiones viejas de Homebrew, por ejemplo).
    var rutasVigiladas: [URL] {
        switch accion {
        case .borrarSueltos, .comprimir, .quitarDescarga: return []
        default: return rutas
        }
    }

    /// Al borrarlo va a la Papelera aunque se pida eliminarlo: lo que no es Seguro y las apps (`Limpiador.esApp`).
    var vaSiempreALaPapelera: Bool {
        accion == .borrar && (riesgo != .seguro || rutas.contains(where: Limpiador.esApp))
    }

    /// Lo que se libera al borrarlo (lo que ocupa, si no se sabe).
    var bytesLiberables: Int64 { liberable.map { min(max(0, $0), tamano) } ?? tamano }

    /// Comparte una parte notable de su espacio con clones: libera bastante menos de lo que ocupa.
    var comparteEspacio: Bool { tamano - bytesLiberables > max(1_000_000, tamano / 20) }

    /// Lo que se libera al borrar la ruta `i` (lo que ocupa, si no se sabe).
    func liberable(ruta i: Int) -> Int64 {
        if i < liberablesRutas.count { return liberablesRutas[i] }
        return i < tamanosRutas.count ? tamanosRutas[i] : 0
    }

    var diasSinUso: Int? {
        guard let ultimoUso else { return nil }
        return Calendar.current.dateComponents([.day], from: ultimoUso, to: Date()).day
    }

    /// Solo los motivos que piden atención, del más grave al más leve.
    var avisos: [Motivo] { motivos.filter { $0.nivel >= .aviso } }
}

/// Un archivo de tus carpetas que es copia idéntica de otro que se va a borrar (un resultado que un programa dejó en /tmp):
/// mientras siga igual, borrar el otro no pierde nada.
struct CopiaExigida: Hashable, Sendable {
    /// La copia, en tus carpetas.
    let ruta: String
    /// El archivo que se borra y del que es copia (para decirlo).
    let de: String
    let tamano: Int64
    /// `Huella.parcial` de su contenido cuando se comparó.
    let huella: String

    /// Sigue ahí y es igual: un archivo normal del mismo tamaño y con la misma huella.
    var sigueIgual: Bool {
        var st = stat()
        guard lstat(ruta, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int64(st.st_size) == tamano else { return false }
        return Huella.parcial(URL(fileURLWithPath: ruta), tamano: tamano) == huella
    }
}

/// Sumas de tamaños que cuentan cada ruta una sola vez, aunque esté en dos elementos
/// (el emulador entero y su «Restablecer») o dentro de otra carpeta ya contada.
enum Totales {
    /// Por defecto suma lo que se libera de verdad (sin lo que comparten con clones); con `liberable: false`, lo que ocupa.
    /// Lo que se comprime o se une cuenta lo que se espera ahorrar, sin los archivos que otro elemento de la lista borra.
    static func sumaSinRepetir(_ lista: [Elemento], liberable: Bool = true) -> Int64 {
        var total: Int64 = 0
        var pares: [(String, Int64)] = []
        var sinBorrar: [(prevision: PrevisionCompresion, une: Bool)] = []
        for el in lista {
            if let p = el.prevision, el.accion.noBorraNada {
                sinBorrar.append((p, el.accion.une))
                continue
            }
            if el.accion != .borrar || el.tamanoFijo != nil {
                total += liberable ? el.bytesLiberables : el.tamano
                continue
            }
            for (i, u) in el.rutas.enumerated() {
                let ocupa = i < el.tamanosRutas.count ? el.tamanosRutas[i] : 0
                pares.append((u.path, liberable ? el.liberable(ruta: i) : ocupa))
            }
        }
        total += sinRepetir(pares)
        guard !sinBorrar.isEmpty else { return total }
        // Comprimir o unir algo que otro elemento de la lista borra no ahorra nada. Y lo que se cambia por un clon de otra
        // copia ya no ahorra además comprimiéndolo: deja de ocupar entero.
        let borradas = Set(lista.filter { $0.accion == .borrar }.flatMap { $0.rutas.map(\.path) })
        let unidas = Set(sinBorrar.filter { $0.une && $0.prevision.ahorro(sin: borradas) > 0 }
            .flatMap { $0.prevision.archivos.map(\.ruta) })
        let tampocoComprimir = borradas.union(unidas)
        return sinBorrar.reduce(total) { $0 + $1.prevision.ahorro(sin: $1.une ? borradas : tampocoComprimir) }
    }

    /// Suma pares (ruta, bytes) sin contar dos veces una ruta ni lo que está dentro de otra ya contada.
    static func sinRepetir(_ pares: [(String, Int64)]) -> Int64 {
        var total: Int64 = 0
        var contadas = Set<String>()
        for (ruta, bytes) in pares.sorted(by: { $0.0.count < $1.0.count })
        where !contadas.contains(ruta) && !dentroDe(ruta, contadas) {
            contadas.insert(ruta)
            total += bytes
        }
        return total
    }

    /// ¿Alguna carpeta superior de `ruta` está en el conjunto?
    static func dentroDe(_ ruta: String, _ conjunto: Set<String>) -> Bool {
        var actual = Substring(ruta)
        while let barra = actual.lastIndex(of: "/"), barra > actual.startIndex {
            actual = actual[..<barra]
            if conjunto.contains(String(actual)) { return true }
        }
        return false
    }
}

struct InfoDisco {
    var total: Int64
    /// Libre de verdad (volumeAvailableCapacity): lo que se puede escribir ya, sin esperar a que macOS purgue nada.
    var libre: Int64
    /// Libre «para uso importante»: el libre de verdad más lo purgable. Es la cifra que enseña el Finder.
    var libreImportante: Int64
    /// Lo que ocupa el volumen de datos (/System/Volumes/Data): tus archivos, las apps y los datos del sistema.
    /// 0 si no se pudo leer.
    var usadoDatos: Int64

    /// Espacio ocupado por cosas que macOS borra solo cuando le hace falta (copias de iCloud, recursos que vuelve
    /// a descargar…). Hasta entonces no se puede usar, así que no se cuenta como libre.
    var purgable: Int64 { max(0, libreImportante - libre) }
    var usado: Int64 { max(0, total - libre) }
    var fraccionUsada: Double { total > 0 ? Double(usado) / Double(total) : 0 }
    var fraccionPurgable: Double { total > 0 ? Double(purgable) / Double(total) : 0 }

    static func actual() -> InfoDisco {
        // Una URL nueva en cada lectura: una URL guarda en caché los valores que ya leyó.
        let url = URL(fileURLWithPath: "/")
        let claves: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                           .volumeAvailableCapacityForImportantUsageKey]
        let v = try? url.resourceValues(forKeys: claves)
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let libre = Int64(v?.volumeAvailableCapacity ?? 0)
        let importante = v?.volumeAvailableCapacityForImportantUsage ?? libre
        return InfoDisco(total: total, libre: libre, libreImportante: max(libre, importante),
                         usadoDatos: espacioUsado(volumen: "/System/Volumes/Data") ?? 0)
    }

    /// Solo el libre de verdad: es lo que se lee varias veces seguidas al medir lo liberado.
    static func libreAhora() -> Int64 {
        Int64((try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0)
    }

    /// Lo que ocupa un volumen, como lo cuenta `df` (ATTR_VOL_SPACEUSED). En APFS, statfs da lo ocupado en todo el
    /// contenedor (System, Preboot, VM… incluidos), no lo de este volumen.
    static func espacioUsado(volumen: String) -> Int64? {
        var lista = attrlist()
        lista.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        lista.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        lista.volattr = attrgroup_t(UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED))
        // largo (4) + atributos devueltos (5 × 4) + espacio usado (8)
        var buf = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        let r = withUnsafeMutableBytes(of: &buf) { b in getattrlist(volumen, &lista, b.baseAddress, b.count, 0) }
        guard r == 0 else { return nil }
        return withUnsafeBytes(of: &buf) { b in
            let devueltos = b.load(fromByteOffset: 8, as: UInt32.self)
            guard devueltos & UInt32(ATTR_VOL_SPACEUSED) != 0 else { return nil }
            return b.loadUnaligned(fromByteOffset: 24, as: Int64.self)
        }
    }
}

/// Mide el espacio libre después de liberar. APFS tarda unos segundos en devolver los bloques de lo borrado,
/// así que se lee cada medio segundo hasta que dos lecturas seguidas casi no cambian, como mucho 6 s.
enum Medidor {
    /// `leer` y `esperar` solo se cambian en las pruebas.
    static func estabilizar(cada intervalo: TimeInterval = 0.5, tolerancia: Int64 = 10_000_000, maximo: TimeInterval = 6,
                            leer: () -> Int64 = { InfoDisco.libreAhora() },
                            esperar: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Int64 {
        var anterior = leer()
        var esperado: TimeInterval = 0
        while esperado + intervalo <= maximo + 0.001 {
            esperar(intervalo)
            esperado += intervalo
            let actual = leer()
            if abs(actual - anterior) < tolerancia { return actual }
            anterior = actual
        }
        return anterior
    }
}

struct ResultadoLimpieza: Identifiable {
    let id = UUID()
    var elementosLimpiados: Int
    /// Lo que ocupaba lo que se limpió, vaya a la Papelera o se elimine.
    var bytesLimpiados: Int64
    /// Libre de verdad (sin lo purgable) antes y después; el de después, ya estabilizado.
    var libreAntes: Int64
    var libreDespues: Int64
    var errores: [String]
    var modo: ModoLimpieza
    /// Elementos que no se tocaron porque algo los estaba usando.
    var omitidos: [String] = []
    /// Elementos que iban a eliminarse definitivamente pero se enviaron a la Papelera por seguridad.
    var forzadosAPapelera = 0
    /// Apps (.app) que iban a eliminarse definitivamente y fueron a la Papelera: una app nunca se elimina para siempre.
    var appsAPapelera = 0
    /// Cuántas cosas se pueden devolver a su sitio con «Deshacer».
    var restaurables = 0
    /// Los elementos que de verdad se limpiaron (lo que falló se queda en la lista).
    var exitosos = Set<Elemento.ID>()
    /// Lo que debería haberse liberado según lo que se eliminó (sin lo que comparte con clones que se quedan),
    /// más lo ahorrado comprimiendo.
    var liberadoCalculado: Int64 = 0
    /// Lo que se movió a la Papelera: sigue ocupando hasta que se vacíe.
    var enPapelera: Int64 = 0
    /// Lo ahorrado sin borrar nada (comprimiendo o convirtiendo copias en clones). Ya va sumado en `liberadoCalculado`.
    var comprimido: Int64 = 0
    /// De `comprimido`, lo ahorrado uniendo copias idénticas (clones de APFS).
    var unido: Int64 = 0
    /// Instantáneas locales de Time Machine que había al limpiar: retienen lo borrado hasta que caducan.
    var instantaneas = 0
    /// Se pidió detener la limpieza: lo ya hecho se queda hecho y estos elementos no se empezaron (o se dejaron a mitad).
    var detenido = false
    var sinTerminar: [String] = []
    /// Fue «Liberar al máximo»: lo Seguro se eliminó sin pasar por la Papelera, de mayor a menor.
    var maximo = false
    /// Lo purgable al terminar: espacio que macOS libera solo cuando le hace falta (no se cuenta como liberado).
    var purgable: Int64 = 0
    /// Lo que se limpió y vuelve a crecer con el uso («el arranque rápido del emulador al cerrarlo»…), para decirlo.
    var volveraACrecer: [String] = []
    /// Lo que esta limpieza movió a la Papelera (con lo que identifica cada cosa allí): «Vaciar solo lo de esta limpieza»
    /// borra esto y nada más de lo que haya en la Papelera.
    var papelera: LimpiezaGuardada?
    /// Las apps que se comprimieron (su ruta): se pueden descomprimir si alguna no se abre bien (`AppsComprimidas`).
    var appsComprimidas: [String] = []
    /// macOS no dejó modificar alguna app: falta el permiso «Gestión de apps».
    var sinPermisoApps = false
    /// De lo calculado, lo liberado quitando copias locales de iCloud (siguen en la nube).
    var quitadoDeICloud: Int64 = 0

    /// Lo que de verdad ganó el disco: el libre de verdad de después menos el de antes.
    var liberadoMedido: Int64 { max(0, libreDespues - libreAntes) }

    /// La medida y la cuenta difieren más de un 15 %: otros programas escribieron mientras tanto,
    /// o clones e instantáneas retienen parte del espacio.
    var difiere: Bool {
        let (m, c) = (liberadoMedido, liberadoCalculado)
        guard max(m, c) >= 50_000_000 else { return false }
        return Double(abs(m - c)) > 0.15 * Double(max(m, c))
    }
}

enum ModoLimpieza: String, CaseIterable, Identifiable {
    case papelera
    case definitivo

    var id: String { rawValue }

    var titulo: String {
        switch self {
        case .papelera: return "Mover a la Papelera"
        case .definitivo: return "Eliminar definitivamente"
        }
    }

    var descripcion: String {
        switch self {
        case .papelera:
            return "Puedes deshacerlo con un clic. El espacio se libera cuando vacías la Papelera."
        case .definitivo:
            return "El espacio se libera al instante. Por seguridad, lo marcado como Revisar o Cuidado va igual a la Papelera."
        }
    }
}

enum Formato {
    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.allowsNonnumericFormatting = false   // «0 KB», no «Zero KB»
        return f.string(fromByteCount: b)
    }

    /// Lee un tamaño escrito como lo escriben Docker y otras herramientas («1.2GB», «512kB», «0B», «3,4 MB»; unidades
    /// decimales, y también KiB, MiB…). nil si no lo entiende.
    static func bytes(deTexto texto: String) -> Int64? {
        let t = texto.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let cifra = t.prefix { $0.isNumber || $0 == "." }
        guard let valor = Double(cifra) else { return nil }
        let unidad = t.dropFirst(cifra.count).trimmingCharacters(in: .whitespaces).lowercased()
        let factores: [String: Double] = ["": 1, "b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
                                          "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776]
        guard let f = factores[unidad] else { return nil }
        return Int64(valor * f)
    }

    static func numero(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "es_PE")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func haceCuanto(_ fecha: Date?) -> String {
        guard let fecha else { return "Sin fecha" }
        let segundos = Date().timeIntervalSince(fecha)
        if segundos < 3600 { return "Hace \(max(1, Int(segundos / 60))) min" }
        if segundos < 86400 { return "Hace \(Int(segundos / 3600)) h" }
        let dias = Int(segundos / 86400)
        if dias == 1 { return "Ayer" }
        if dias < 30 { return "Hace \(dias) días" }
        let meses = dias / 30
        if meses < 12 { return meses == 1 ? "Hace 1 mes" : "Hace \(meses) meses" }
        let anios = dias / 365
        return anios == 1 ? "Hace 1 año" : "Hace \(anios) años"
    }

    static func rutaCorta(_ url: URL) -> String { rutaCorta(url.path) }

    static func rutaCorta(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    /// "a, b y c"
    static func lista(_ partes: [String]) -> String {
        switch partes.count {
        case 0: return ""
        case 1: return partes[0]
        default: return partes.dropLast().joined(separator: ", ") + " y " + partes.last!
        }
    }

    /// "a, b, c y 4 más"
    static func listaCorta(_ partes: [String], maximo: Int = 3) -> String {
        guard partes.count > maximo else { return lista(partes) }
        return partes.prefix(maximo).joined(separator: ", ") + " y \(partes.count - maximo) más"
    }
}
