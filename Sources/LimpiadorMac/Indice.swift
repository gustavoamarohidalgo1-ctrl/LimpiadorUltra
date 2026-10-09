import Darwin
import Foundation

// MARK: - Tipos del índice

/// En qué parte de la carpeta personal está algo. Decide qué búsquedas aplican.
enum Zona: UInt8 {
    /// Escritorio, Documentos, Descargas, Música… (lo que el usuario ve)
    case personal
    /// Carpetas que empiezan con punto
    case oculta
    /// ~/Library
    case library
    /// /Users/Shared
    case compartida
    /// Temporales y cachés de macOS para tu usuario (/var/folders)
    case sistema
}

enum TipoSensible: UInt8 {
    case keystore, certificado, llaveSSH, secreto, firebase
}

struct ArchivoSensible: Hashable {
    let ruta: String
    let tipo: TipoSensible
    /// En Library son credenciales de una app (su sesión); en tus carpetas, claves tuyas.
    let zona: Zona
    var nombre: String { (ruta as NSString).lastPathComponent }
}

/// Carpetas de proyectos que se regeneran solas.
enum TipoArtefacto: UInt8 {
    case node, pods, compilacion, gradle, cxx, kotlin, web, expo, dart, xcode, swiftpm, cargo, venv
    case python, unity, dotnet, terraform, pruebas

    var descripcion: String {
        switch self {
        case .node: return "dependencias de Node"
        case .pods: return "dependencias de CocoaPods"
        case .compilacion: return "resultado de compilación"
        case .gradle: return "caché de Gradle del proyecto"
        case .cxx: return "compilación nativa (NDK)"
        case .kotlin: return "datos temporales de Kotlin"
        case .web: return "caché de compilación web"
        case .expo: return "caché de Expo"
        case .dart: return "caché de Flutter/Dart"
        case .xcode: return "compilación de Xcode"
        case .swiftpm: return "compilación de Swift"
        case .cargo: return "compilación de Rust/Java"
        case .venv: return "entorno virtual de Python"
        case .python: return "caché de pruebas y análisis de Python"
        case .unity: return "caché de importación de Unity"
        case .dotnet: return "compilación de .NET"
        case .terraform: return "proveedores de Terraform"
        case .pruebas: return "informe de cobertura de pruebas"
        }
    }
}

struct Artefacto: Hashable {
    let ruta: String
    let tipo: TipoArtefacto
}

struct ArchivoIndexado: Hashable {
    let ruta: String
    /// Espacio que ocupa en disco.
    let bytes: Int64
    /// Tamaño lógico (el que se compara para buscar duplicados).
    let tamano: Int64
    let modificado: Int
    let dispositivo: Int32
    let inodo: UInt64
    let zona: Zona

    var url: URL { URL(fileURLWithPath: ruta) }
    var fecha: Date { Date(timeIntervalSince1970: TimeInterval(modificado)) }
    var nombre: String { (ruta as NSString).lastPathComponent }
    var carpeta: String { (ruta as NSString).deletingLastPathComponent }
}

/// Un archivo grande que es clon exacto de otros (APFS): sus datos solo se liberan al borrar todas las copias.
struct ArchivoClonado {
    let ruta: String
    let inodo: UInt64
    /// Identifica los datos que comparten las copias.
    let clon: UInt64
    /// Cuántos archivos comparten esos datos, estén donde estén.
    let copias: UInt32
    /// Lo que comparte con las demás copias (lo que no se libera si alguna se queda).
    let compartido: Int64
}

struct InfoCarpeta {
    var bytes: Int64 = 0
    /// De `bytes`, lo que los archivos de 1 MiB o más comparten con clones: no se libera mientras quede otra copia.
    var compartido: Int64 = 0
    var archivos: Int32 = 0
    /// Última modificación de cualquier archivo dentro (no solo la carpeta).
    var masReciente = 0
    /// La actividad real de un proyecto: la última modificación de un archivo, sin contar las carpetas (cambian al
    /// borrar o mover algo), node_modules, build…, ni lo que escriben git y los editores (.git, .idea, *.iml…).
    var masRecientePropio = 0
    var contenido = Contenido()
}

enum TipoCacheInterna: UInt8 { case cache, registros }

/// Una app desinstalada que probablemente dejó carpetas en los contenedores (sin Acceso total no se sabe cuánto ocupan).
struct ProbableResto: Hashable, Sendable {
    let nombre: String
    /// Los nombres de sus carpetas en Containers y Group Containers.
    let carpetas: [String]
}

/// Algo grande que conviene saber pero que no se ofrece limpiar (ver `Indice.notas`).
struct NotaGrande: Hashable, Sendable {
    let categoria: Categoria
    let titulo: String
    let texto: String
    /// Dónde está (para enseñarlo en el Finder).
    let ruta: String
    let bytes: Int64
}

// MARK: - Índice

/// Índice completo de la carpeta personal: tamaño, actividad y contenido de cada carpeta.
/// Se construye en una sola pasada paralela y todas las categorías lo consultan.
final class Indice: @unchecked Sendable {
    fileprivate(set) var carpetas: [String: InfoCarpeta] = [:]
    fileprivate(set) var hijos: [String: [String]] = [:]
    fileprivate(set) var grandes: [ArchivoIndexado] = []
    fileprivate(set) var duplicables: [ArchivoIndexado] = []
    fileprivate(set) var instaladores: [ArchivoIndexado] = []
    fileprivate(set) var comprimidos: [ArchivoIndexado] = []
    fileprivate(set) var artefactos: [Artefacto] = []
    fileprivate(set) var sensibles: [ArchivoSensible] = []
    fileprivate(set) var repos: Set<String> = []
    fileprivate(set) var releases: [String] = []
    fileprivate(set) var apps: [String] = []
    fileprivate(set) var cachesInternas: [(ruta: String, tipo: TipoCacheInterna)] = []
    fileprivate(set) var wrappersGradle: [String] = []
    /// Descargas a medias (.crdownload, .part, .download…) en tus carpetas.
    fileprivate(set) var parciales: [String] = []
    /// Volcados de memoria de Java (.hprof) que dejan Android Studio y otros programas al fallar.
    fileprivate(set) var volcados: [ArchivoIndexado] = []
    /// Registros (.log) de más de 20 MB fuera de Library.
    fileprivate(set) var registrosGrandes: [ArchivoIndexado] = []
    /// Lo tuyo en /tmp (carpetas y archivos).
    fileprivate(set) var tmp: [String] = []
    /// Las carpetas de las sesiones de agentes (Claude Code) en /tmp: se miden, pero solo se ofrecen para revisar.
    fileprivate(set) var sesionesDeAgentes: [String] = []
    /// Dentro de carpetas regenerables (build/…), lo que la compilación no crea: bases de datos, trazas, emuladores.
    fileprivate(set) var noRegenerables: [String] = []
    /// Todos los emuladores de Android (.avd) que hay en el disco, estén donde estén.
    fileprivate(set) var avds: [String] = []
    /// Las carpetas en las que hay restos de una compresión que se cortó («.limpiador-<UUID>»): la próxima limpieza los
    /// recoge (`Limpiador.recogerRestos`), aunque esa carpeta no esté apuntada.
    fileprivate(set) var raicesConRestos: [String] = []
    /// Archivos de 1 MiB o más que son clones exactos de otros.
    fileprivate(set) var clonados: [ArchivoClonado] = []
    /// Archivos de resultados (informes, tablas, imágenes…) de tus carpetas por nombre y tamaño (`Resultados.clave`),
    /// hasta tres rutas por clave: dicen dónde buscar copia de lo que un programa dejó en /tmp.
    fileprivate(set) var resultados: [UInt64: [String]] = [:]
    fileprivate(set) var archivosTotales = 0
    fileprivate(set) var bytesTotales: Int64 = 0
    fileprivate(set) var sinPermiso = 0
    fileprivate(set) var duracion: TimeInterval = 0
    fileprivate(set) var raices: [String] = []
    /// Sin Acceso total al disco: carpetas de ~/Library/Containers y Group Containers de apps que no están instaladas, por
    /// app. Sus nombres se pueden leer, pero no lo que ocupan ni lo que hay dentro: solo se informa (lo rellena el
    /// análisis de «Restos de apps borradas»).
    var probablesRestos: [ProbableResto] = []
    /// Otras nubes con carpeta en ~/Library/CloudStorage (OneDrive, Google Drive, Dropbox…): solo se informa de que
    /// tienen su propia opción para dejar los archivos solo en línea (lo rellena el análisis de «Archivos olvidados»).
    var otrasNubes: [String] = []
    /// Lo grande que no se ofrece limpiar porque no hay una forma segura de hacerlo desde aquí (los puntos de restauración
    /// de Codex de un repositorio, las Command Line Tools que Xcode ya trae…): se enseña en su categoría con lo que ocupa
    /// y cómo se quitaría a mano. Lo rellenan las categorías al analizar.
    var notas: [NotaGrande] = []

    // MARK: Consultas

    func info(_ ruta: String) -> InfoCarpeta? { carpetas[ruta] }

    /// Lo que se libera al borrar unas rutas, y lo que no porque lo comparten con clones que se quedan.
    struct Liberable {
        /// Lo que se libera al borrar cada ruta.
        var porRuta: [Int64]
        /// Lo que comparten con archivos de fuera (clones de APFS que se quedan): no se libera al borrarlas.
        var retenido: Int64
    }

    /// Lo que se liberaría de verdad al borrar cada ruta: lo que ocupa (`asignados`) menos lo que comparte con
    /// clones de APFS. Si todas las copias de un clon están dentro de estas rutas, sus datos sí se liberan, una vez
    /// (`asignados` cuenta cada copia, así que ahí también se libera menos de lo que suman).
    /// Lo que no se sabe (rutas fuera del índice, discos sin APFS, archivos pequeños) se da por privado.
    func liberables(de urls: [URL], asignados: [Int64]) -> Liberable {
        var libres: [Int64] = []
        var retenido: Int64 = 0
        for (i, u) in urls.enumerated() {
            let asignado = i < asignados.count ? asignados[i] : 0
            let compartido = min(asignado, compartido(de: u.path))
            libres.append(asignado - compartido)
            retenido += compartido
        }
        guard retenido > 0 else { return Liberable(porRuta: libres, retenido: 0) }

        // Clones exactos con todas sus copias dentro: al borrarlas a la vez, sus datos se liberan una vez,
        // y nada de lo que comparten se queda retenido fuera.
        var grupos: [UInt64: (copias: UInt32, inodos: Set<UInt64>, bytes: Int64, suma: Int64, ruta: Int)] = [:]
        for c in clonados {
            guard let i = urls.firstIndex(where: { c.ruta == $0.path || c.ruta.hasPrefix($0.path + "/") }) else { continue }
            var g = grupos[c.clon] ?? (c.copias, [], 0, 0, i)
            g.inodos.insert(c.inodo)
            g.bytes = max(g.bytes, c.compartido)
            g.suma += c.compartido
            grupos[c.clon] = g
        }
        for g in grupos.values where g.copias >= 2 && g.inodos.count >= Int(g.copias) {
            let asignado = g.ruta < asignados.count ? asignados[g.ruta] : 0
            libres[g.ruta] = min(asignado, libres[g.ruta] + g.bytes)
            retenido -= g.suma
        }
        return Liberable(porRuta: libres, retenido: max(0, retenido))
    }

    /// Lo que una ruta comparte con clones: de una carpeta, lo que sumó el índice; de un archivo, se pregunta al sistema.
    private func compartido(de ruta: String) -> Int64 {
        if let i = carpetas[ruta] { return i.compartido }
        var st = stat()
        guard lstat(ruta, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_flags & UInt32(UF_COMPRESSED) == 0,
              let p = Privado.consultar(ruta) else { return 0 }
        return max(0, Int64(st.st_blocks) * 512 - p.privado)
    }

    /// Cuánto del volumen de datos no se pudo revisar: lo que ocupa (`usadoDatos`) menos lo que sí se midió
    /// (este índice, lo de fuera de tu carpeta y la Papelera). Sin Acceso total al disco son sobre todo los
    /// contenedores de las apps, Mail, Mensajes y Fotos; con él, datos del sistema que solo puede leer root.
    /// nil si no se sabe (en una casa de prueba no casa con el disco).
    func sinRevisar(usadoDatos: Int64, papelera: Int64, fuera: [String: Int64]) -> Int64? {
        guard usadoDatos > 0, !Rutas.casaDePrueba else { return nil }
        return max(0, usadoDatos - bytesTotales - medidoFuera(fuera) - papelera)
    }

    /// Lo que se midió fuera de tu carpeta (`MedidaFuera`), sin lo que ya está en el índice (tus temporales de /private).
    func medidoFuera(_ medido: [String: Int64]) -> Int64 {
        let repetido = raices.filter { r in medido.keys.contains { r.hasPrefix($0 + "/") } }
            .reduce(Int64(0)) { $0 + (carpetas[$1]?.bytes ?? 0) }
        return max(0, medido.values.reduce(0, +) - repetido)
    }

    /// Espacio que ocupa una ruta (carpeta o archivo).
    func bytes(de url: URL) -> Int64 {
        if let i = carpetas[url.path] { return i.bytes }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            // Carpeta pequeña o fuera del índice: se mide aparte.
            return estaIndexada(url.path) ? 0 : Tamanos.de(url)
        }
        return Int64(st.st_blocks) * 512
    }

    func masReciente(de urls: [URL]) -> Date? {
        var mejor = 0
        for u in urls {
            if let i = carpetas[u.path] {
                mejor = max(mejor, i.masReciente)
            } else {
                var st = stat()
                if lstat(u.path, &st) == 0 { mejor = max(mejor, Int(st.st_mtimespec.tv_sec)) }
            }
        }
        return mejor > 0 ? Date(timeIntervalSince1970: TimeInterval(mejor)) : nil
    }

    func masRecientePropio(de ruta: String) -> Date? {
        guard let i = carpetas[ruta], i.masRecientePropio > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(i.masRecientePropio))
    }

    func contenido(de urls: [URL]) -> Contenido {
        var c = Contenido()
        for u in urls {
            if let i = carpetas[u.path] { c.sumar(i.contenido) }
        }
        return c
    }

    func sensibles(dentro urls: [URL]) -> [ArchivoSensible] {
        let bases = urls.map(\.path)
        return sensibles.filter { s in bases.contains { s.ruta == $0 || s.ruta.hasPrefix($0 + "/") } }
    }

    func repos(dentro urls: [URL]) -> [String] {
        let bases = urls.map(\.path)
        return repos.filter { r in bases.contains { r == $0 || r.hasPrefix($0 + "/") } }.sorted()
    }

    func releases(dentro urls: [URL]) -> [String] {
        let bases = urls.map(\.path)
        return releases.filter { r in bases.contains { r.hasPrefix($0 + "/") || r == $0 } }
    }

    func noRegenerables(dentro urls: [URL]) -> [String] {
        let bases = urls.map(\.path)
        return noRegenerables.filter { r in bases.contains { r.hasPrefix($0 + "/") } }
    }

    /// Archivos de tus carpetas (Escritorio, Documentos…, fuera de las carpetas de compilación y de dependencias) que se
    /// llaman igual y miden lo mismo que uno de resultados: posibles copias, hay que comparar su contenido.
    func posiblesCopias(clave: UInt64) -> [String] { resultados[clave] ?? [] }

    /// Subcarpetas registradas, de mayor a menor.
    func hijosOrdenados(de ruta: String) -> [(ruta: String, bytes: Int64)] {
        (hijos[ruta] ?? [])
            .compactMap { h in carpetas[h].map { (h, $0.bytes) } }
            .sorted { $0.1 > $1.1 }
    }

    func estaIndexada(_ ruta: String) -> Bool {
        raices.contains { ruta == $0 || ruta.hasPrefix($0 + "/") }
    }

    // MARK: Construcción

    struct Progreso {
        var archivos: Int
        var bytes: Int64
        var ruta: String
    }

    static func construir(accesoTotal: Bool, progreso: (Progreso) -> Void) -> Indice {
        let inicio = Date()
        let indice = Indice()
        let marcador = Marcador()
        let home = Rutas.home.path
        let omitir = rutasOmitidas(home: home, accesoTotal: accesoTotal)
        let candado = NSLock()

        // 1. Recorrido superficial: la carpeta personal hasta 2-3 niveles.
        //    Lo que hay más abajo se reparte en «unidades» que se recorren en paralelo.
        let superficial = Recorrido(marcador: marcador, home: home, accesoTotal: accesoTotal, omitir: omitir)
        var unidades: [Unidad] = []
        let libraryPrefijo = home + "/Library/"
        _ = superficial.recorrer(
            raiz: home, contexto: Acumulador(zona: .personal), umbral: 0,
            cortar: { ruta, nivel in nivel >= (ruta.hasPrefix(libraryPrefijo) ? 3 : 2) },
            alCortar: { unidades.append($0) })
        indice.absorber(superficial)
        if Rutas.existe(URL(fileURLWithPath: "/Users/Shared")) {
            unidades.append(Unidad(ruta: "/Users/Shared", contexto: Acumulador(zona: .compartida)))
        }
        for ruta in Rutas.temporalesDelSistema where Rutas.existe(ruta) {
            unidades.append(Unidad(ruta: ruta, contexto: Acumulador(zona: .sistema)))
        }
        indice.tmp = Rutas.tuyoEnTmp()
        indice.sesionesDeAgentes = Rutas.sesionesDeAgentes()
        let carpetasTmp = indice.tmp.filter { Rutas.esCarpeta(URL(fileURLWithPath: $0)) } + indice.sesionesDeAgentes
        for ruta in carpetasTmp {
            unidades.append(Unidad(ruta: ruta, contexto: Acumulador(zona: .sistema)))
        }

        // 2. Unidades en paralelo.
        let lista = unidades
        var resultados = [Acumulador?](repeating: nil, count: unidades.count)
        let grupo = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: grupo) {
            DispatchQueue.concurrentPerform(iterations: lista.count) { i in
                let r = Recorrido(marcador: marcador, home: home, accesoTotal: accesoTotal, omitir: omitir)
                marcador.actual(lista[i].ruta)
                let a = r.recorrer(raiz: lista[i].ruta, contexto: lista[i].contexto, umbral: 1_000_000,
                                   cortar: nil, alCortar: nil)
                candado.lock()
                resultados[i] = a
                indice.absorber(r)
                candado.unlock()
            }
        }
        while grupo.wait(timeout: .now() + 0.15) == .timedOut {
            let m = marcador.leer()
            progreso(Progreso(archivos: m.0, bytes: m.1, ruta: m.2))
        }

        // 3. Sumar cada unidad a sus carpetas superiores.
        for (i, u) in unidades.enumerated() {
            guard let a = resultados[i] else { continue }
            indice.carpetas[u.ruta] = a.info
            guard u.ruta.hasPrefix(home + "/") else { continue }
            var p = (u.ruta as NSString).deletingLastPathComponent
            while p.count >= home.count {
                if var info = indice.carpetas[p] {
                    info.bytes += a.bytes
                    info.compartido += a.compartido
                    info.archivos += a.archivos
                    info.masReciente = max(info.masReciente, a.masReciente)
                    if !a.esArtefacto && a.cuentaActividad {
                        info.masRecientePropio = max(info.masRecientePropio, a.masRecientePropio)
                    }
                    info.contenido.sumar(a.contenido)
                    indice.carpetas[p] = info
                }
                if p == home { break }
                p = (p as NSString).deletingLastPathComponent
            }
        }

        let m = marcador.leer()
        indice.archivosTotales = m.0
        indice.raices = [home, "/Users/Shared"] + Rutas.temporalesDelSistema + carpetasTmp
        indice.bytesTotales = indice.raices.reduce(0) { $0 + (indice.carpetas[$1]?.bytes ?? 0) }
        indice.duracion = Date().timeIntervalSince(inicio)
        progreso(Progreso(archivos: m.0, bytes: indice.bytesTotales, ruta: ""))
        return indice
    }

    private func absorber(_ r: Recorrido) {
        carpetas.merge(r.carpetas) { _, nuevo in nuevo }
        for (k, v) in r.hijos { hijos[k, default: []].append(contentsOf: v) }
        grandes += r.grandes
        duplicables += r.duplicables
        instaladores += r.instaladores
        comprimidos += r.comprimidos
        artefactos += r.artefactos
        sensibles += r.sensibles
        repos.formUnion(r.repos)
        releases += r.releases
        apps += r.apps
        cachesInternas += r.cachesInternas
        wrappersGradle += r.wrappersGradle
        parciales += r.parciales
        volcados += r.volcados
        registrosGrandes += r.registrosGrandes
        noRegenerables += r.noRegenerables
        avds += r.avds
        raicesConRestos += r.raicesConRestos
        clonados += r.clonados
        for (k, rutas) in r.resultados where (resultados[k]?.count ?? 0) < 3 {
            resultados[k, default: []] += rutas.prefix(3 - (resultados[k]?.count ?? 0))
        }
        sinPermiso += r.sinPermiso
    }

    /// Carpetas que no se recorren: datos privados de macOS (que además piden permisos)
    /// y, sin Acceso total al disco, las que el sistema bloquea.
    private static func rutasOmitidas(home: String, accesoTotal: Bool) -> Set<String> {
        var rel = [
            ".Trash", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies", "Library/HomeKit",
            "Library/IdentityServices", "Library/Metadata", "Library/Suggestions", "Library/Accounts",
            "Library/Calendars", "Library/Reminders", "Library/Biome", "Library/DuetExpertCenter",
            "Library/PersonalizationPortrait", "Library/Sharing", "Library/Daemon Containers",
            "Library/Autosave Information", "Library/Trial", "Library/Assistant", "Library/ContainerManager",
            "Library/Photos", "Library/Keychains", "Library/Application Support/com.apple.TCC",
            "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
            "Library/Application Support/CallHistoryTransactions", "Library/Application Support/Knowledge",
            "Library/Application Support/FileProvider", "Library/Application Support/CloudDocs",
            "Library/Application Support/com.apple.sharedfilelist", "Library/Application Support/DifferentialPrivacy",
        ]
        if !accesoTotal {
            rel += ["Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
                    "Library/Application Support/MobileSync"]
        }
        return Set(rel.map { home + "/" + $0 })
    }
}

// MARK: - Recorrido de una parte del disco

fileprivate struct Unidad {
    let ruta: String
    let contexto: Acumulador
}

/// Contadores de una carpeta mientras se recorre, más el contexto que heredan sus hijos.
fileprivate struct Acumulador {
    var bytes: Int64 = 0
    var compartido: Int64 = 0
    var archivos: Int32 = 0
    var masReciente = 0
    var masRecientePropio = 0
    var contenido = Contenido()

    var zona: Zona
    /// Contar documentos, fotos, claves… (no dentro de node_modules, apps o .git).
    var clasificar = true
    /// Dentro de un artefacto (build, node_modules…): solo se buscan apps para publicar y lo que la compilación no crea.
    var enArtefacto = false
    /// Dentro de una app, framework… compilado: lo que hay es parte del programa.
    var enPaquete = false
    /// Dentro de dependencias descargadas (node_modules, Pods…): nada de lo que hay es tuyo.
    var enTerceros = false
    /// Dentro de build/reports, fuera de los informes que escribe Gradle: lo que hay lo puso alguien.
    var enInformes = false
    /// Guardar las subcarpetas en el índice (no dentro de apps ni de .git).
    var registrarHijos = true
    var registrarse = true
    var esArtefacto = false
    var enCacheInterna = false
    /// Lo que cambia dentro cuenta como actividad del proyecto (no en .git, .idea… ver `Recorrido.sinActividad`).
    var cuentaActividad = true

    init(zona: Zona) { self.zona = zona }

    var info: InfoCarpeta {
        InfoCarpeta(bytes: bytes, compartido: compartido, archivos: archivos, masReciente: masReciente,
                    masRecientePropio: masRecientePropio, contenido: contenido)
    }

    func hijo() -> Acumulador {
        var h = Acumulador(zona: zona)
        h.clasificar = clasificar
        h.enArtefacto = enArtefacto
        h.enPaquete = enPaquete
        h.enTerceros = enTerceros
        h.enInformes = enInformes
        h.registrarHijos = registrarHijos
        h.registrarse = registrarHijos
        h.enCacheInterna = enCacheInterna
        return h
    }

    mutating func absorber(_ h: Acumulador) {
        bytes += h.bytes
        compartido += h.compartido
        archivos += h.archivos
        masReciente = max(masReciente, h.masReciente)
        if !h.esArtefacto && h.cuentaActividad { masRecientePropio = max(masRecientePropio, h.masRecientePropio) }
        contenido.sumar(h.contenido)
    }
}

/// Contadores compartidos entre hilos para mostrar el progreso.
fileprivate final class Marcador: @unchecked Sendable {
    private let candado = NSLock()
    private var archivos = 0
    private var bytes: Int64 = 0
    private var ruta = ""

    func sumar(_ a: Int, _ b: Int64) {
        candado.lock(); archivos += a; bytes += b; candado.unlock()
    }

    func actual(_ r: String) {
        candado.lock(); ruta = r; candado.unlock()
    }

    func leer() -> (Int, Int64, String) {
        candado.lock(); defer { candado.unlock() }
        return (archivos, bytes, ruta)
    }
}

fileprivate final class Recorrido {
    var carpetas: [String: InfoCarpeta] = [:]
    var hijos: [String: [String]] = [:]
    var grandes: [ArchivoIndexado] = []
    var duplicables: [ArchivoIndexado] = []
    var instaladores: [ArchivoIndexado] = []
    var comprimidos: [ArchivoIndexado] = []
    var artefactos: [Artefacto] = []
    var sensibles: [ArchivoSensible] = []
    var repos: Set<String> = []
    var releases: [String] = []
    var apps: [String] = []
    var cachesInternas: [(ruta: String, tipo: TipoCacheInterna)] = []
    var wrappersGradle: [String] = []
    var parciales: [String] = []
    var volcados: [ArchivoIndexado] = []
    var registrosGrandes: [ArchivoIndexado] = []
    var noRegenerables: [String] = []
    var avds: [String] = []
    var raicesConRestos: [String] = []
    var clonados: [ArchivoClonado] = []
    var resultados: [UInt64: [String]] = [:]
    var sinPermiso = 0

    private let marcador: Marcador
    private let home: String
    private let appSupport: String
    private let accesoTotal: Bool
    private let omitir: Set<String>
    private var pendientesArchivos = 0
    private var pendientesBytes: Int64 = 0

    init(marcador: Marcador, home: String, accesoTotal: Bool, omitir: Set<String>) {
        self.marcador = marcador
        self.home = home
        self.appSupport = home + "/Library/Application Support/"
        self.accesoTotal = accesoTotal
        self.omitir = omitir
    }

    /// Recorre `raiz` y devuelve sus totales. Si `cortar` dice que sí, esa carpeta no se recorre
    /// aquí: se entrega a `alCortar` para recorrerla en otro hilo.
    func recorrer(raiz: String, contexto: Acumulador, umbral: Int64,
                  cortar: ((String, Int) -> Bool)?, alCortar: ((Unidad) -> Void)?) -> Acumulador {
        guard let raizC = strdup(raiz) else { return contexto }
        defer { free(raizC) }
        var argumentos: [UnsafeMutablePointer<CChar>?] = [raizC, nil]
        guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return contexto }
        defer { fts_close(fts) }

        var pila = ContiguousArray<Acumulador>()
        pila.reserveCapacity(64)
        var resultado = contexto

        func cerrar(_ e: UnsafeMutablePointer<FTSENT>) {
            let a = pila.removeLast()
            if a.registrarse && (a.bytes >= umbral) {
                let ruta = String(cString: e.pointee.fts_path)
                carpetas[ruta] = a.info
                if e.pointee.fts_level > 0 {
                    hijos[(ruta as NSString).deletingLastPathComponent, default: []].append(ruta)
                }
            }
            if pila.isEmpty { resultado = a } else { pila[pila.count - 1].absorber(a) }
        }

        while let e = fts_read(fts) {
            let nivel = Int(e.pointee.fts_level)
            switch Int32(e.pointee.fts_info) {
            case FTS_D:
                while pila.count > nivel { cerrarSinRuta(&pila, &resultado) }
                var a = pila.last?.hijo() ?? contexto
                let st = e.pointee.fts_statp.pointee
                a.bytes = Int64(st.st_blocks) * 512
                a.masReciente = Int(st.st_mtimespec.tv_sec)
                // La fecha de una carpeta cambia al borrar o mover algo dentro: no es trabajo en el proyecto.
                a.masRecientePropio = 0
                let nombre = nombreDe(e)
                var saltar = false

                if nivel > 0 {
                    let ruta = String(cString: e.pointee.fts_path)
                    if nivel <= 3 && omitir.contains(ruta) {
                        saltar = true
                    } else if let cortar, cortar(ruta, nivel) {
                        a.bytes = 0
                        alCortar?(Unidad(ruta: ruta, contexto: pila.last?.hijo() ?? contexto))
                        saltar = true
                    } else {
                        examinarCarpeta(nombre: nombre, ruta: ruta, acumulador: &a, padre: pila.last ?? contexto,
                                        saltar: &saltar)
                    }
                } else {
                    // Raíz de una unidad: se examina igual que cualquier carpeta.
                    let ruta = String(cString: e.pointee.fts_path)
                    examinarCarpeta(nombre: nombre, ruta: ruta, acumulador: &a, padre: contexto, saltar: &saltar)
                }
                pila.append(a)
                if saltar { fts_set(fts, e, FTS_SKIP) }

            case FTS_DP, FTS_DNR, FTS_ERR:
                if Int32(e.pointee.fts_info) == FTS_DNR { sinPermiso += 1 }
                while pila.count > nivel + 1 { cerrarSinRuta(&pila, &resultado) }
                if pila.count == nivel + 1 { cerrar(e) }

            case FTS_F:
                while pila.count > nivel { cerrarSinRuta(&pila, &resultado) }
                guard !pila.isEmpty else { continue }
                archivo(e, &pila[pila.count - 1])

            case FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard !pila.isEmpty else { continue }
                pila[pila.count - 1].bytes += Int64(e.pointee.fts_statp.pointee.st_blocks) * 512

            case FTS_NS:
                sinPermiso += 1

            default:
                break
            }
        }
        while !pila.isEmpty { cerrarSinRuta(&pila, &resultado) }
        marcador.sumar(pendientesArchivos, pendientesBytes)
        pendientesArchivos = 0
        pendientesBytes = 0
        return resultado
    }

    /// Cierre de emergencia (no debería pasar): suma la carpeta a su padre sin registrarla.
    private func cerrarSinRuta(_ pila: inout ContiguousArray<Acumulador>, _ resultado: inout Acumulador) {
        let a = pila.removeLast()
        if pila.isEmpty { resultado = a } else { pila[pila.count - 1].absorber(a) }
    }

    @inline(__always)
    private func nombreDe(_ e: UnsafeMutablePointer<FTSENT>) -> String {
        let p = e.pointee.fts_path + (Int(e.pointee.fts_pathlen) - Int(e.pointee.fts_namelen))
        return String(cString: p)
    }

    // MARK: Carpetas

    private static let paquetes: Set<String> = [
        "app", "framework", "bundle", "plugin", "appex", "xpc", "kext", "xcarchive", "dsym", "xcframework",
        "docset", "qlgenerator", "mdimporter", "prefpane", "saver", "systemextension", "driver",
    ]
    private static let bibliotecas: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "aplibrary",
    ]
    private static let cachesInternasNombres: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache",
        "ShaderCache", "GrShaderCache", "component_crx_cache", "extensions_crx_cache", "optimization_guide_model_store",
        // VS Code, Cursor y otros editores basados en él.
        "CachedData", "CachedExtensionVSIXs", "CachedProfilesData", "CachedConfigurations",
        // Nombres nuevos de Chromium.
        "GPUPersistentCache", "OptGuidePredictionModels",
    ]
    private static let codigoDeTerceros: Set<String> = ["node_modules", "site-packages", "vendor", "Pods", "__pycache__"]
    /// (deps/ de Elixir ya se trata como dependencias al detectar el artefacto; dentro de otros, «deps» puede ser tuyo.)
    private static let dependenciasEnArtefactos: Set<String> = ["_deps", "bower_components", "checkouts", "Checkouts",
                                                                "SourcePackages"]
    /// Lo que Gradle y sus plugins escriben en build/reports (se compara el principio del nombre: «lint-results-debug.html»).
    private static let informesDeGradle = ["tests", "androidTests", "lint", "detekt", "jacoco", "kover", "compose-compiler",
                                           "configuration-cache", "problems", "profile", "roborazzi", "paparazzi", "ktlint",
                                           "spotbugs", "pmd", "checkstyle", "dependency-analysis", "dependencies", "project",
                                           "tasks", "screenshotTest", "buildHealth"]
    private static let componentes: Set<String> = ["plugins", "extensions", "packages", "lib", "runtimes", "versions",
                                                    "bin", "toolchains", "sdk", "downloads"]
    /// Lo que escriben git y los editores por su cuenta (al abrir el proyecto, al hacer fetch…): no dice que hayas
    /// trabajado en el proyecto. (.DS_Store y los *.iml, que son archivos, se saltan en `archivo`.)
    static let sinActividad: Set<String> = [".git", ".idea", ".vscode", ".fleet", "xcuserdata"]
    /// Desde qué tamaño se apunta un archivo como posible copia repetida (256 KiB).
    static let minimoDuplicable: Int64 = 262_144

    private func examinarCarpeta(nombre: String, ruta: String, acumulador a: inout Acumulador, padre: Acumulador,
                                 saltar: inout Bool) {
        let ext = (nombre as NSString).pathExtension.lowercased()
        if ruta == home + "/Library" { a.zona = .library }
        if Self.sinActividad.contains(nombre) { a.cuentaActividad = false }
        if ext == "avd" {
            // Emuladores fuera de ~/.android/avd (pruebas aisladas, Gradle): también usan imágenes del sistema.
            avds.append(ruta)
            // Y uno guardado dentro de build/ no lo vuelve a crear la compilación.
            if a.enArtefacto { noRegenerables.append(ruta) }
        }

        if nombre == ".git" {
            repos.insert((ruta as NSString).deletingLastPathComponent)
            a.clasificar = false
            a.registrarHijos = false
            return
        }
        // Las carpetas de trabajo de esta app, con lo que deja una compresión o una unión que se cortó: no son archivos
        // tuyos, ni grandes ni copias que unir. Se cuentan en lo que ocupa su carpeta, pero no se ofrecen; la próxima
        // limpieza las recoge (`Limpiador.recogerRestos`).
        if Compresor.esCarpetaDeTrabajo(nombre: nombre, ruta: ruta) {
            if nombre.hasPrefix(Compresor.prefijoTemporal) { raicesConRestos.append(Rutas.padre(ruta)) }
            a.clasificar = false
            a.enArtefacto = false
            a.registrarse = false
            a.registrarHijos = false
            a.cuentaActividad = false
            return
        }
        if nombre.hasPrefix(".") && a.zona == .personal { a.zona = .oculta }

        // Safari guarda cada descarga en curso como una carpeta «archivo.download».
        if ext == "download" && a.zona == .personal { parciales.append(ruta) }

        if !ext.isEmpty && Self.bibliotecas.contains(ext) {
            a.contenido.bibliotecas += 1
            a.clasificar = false
            a.registrarHijos = false
            // La fototeca está protegida: sin permiso, ni se intenta.
            if ext == "photoslibrary" && !accesoTotal { saltar = true }
            return
        }
        if !ext.isEmpty && Self.paquetes.contains(ext) {
            if ext == "app" && (a.zona == .personal || a.zona == .compartida) && padre.clasificar { apps.append(ruta) }
            // El archivo que se sube a la App Store, con los dSYM para entender los fallos de esa versión.
            if ext == "xcarchive" && a.enArtefacto && !a.enTerceros { releases.append(ruta) }
            a.clasificar = false
            a.enPaquete = true
            a.registrarHijos = false
            return
        }
        if Self.codigoDeTerceros.contains(nombre) {
            a.clasificar = false
            a.enTerceros = true
        }
        if a.enArtefacto && !a.enTerceros && !a.enPaquete {
            // Dentro de una carpeta de compilación, las dependencias que descargan CMake, Mix, SwiftPM, Carthage…
            if Self.dependenciasEnArtefactos.contains(nombre) {
                a.enTerceros = true
            } else if nombre == "reports" && padre.esArtefacto && ruta.hasSuffix("/build/reports") {
                a.enInformes = true
            } else if a.enInformes && Rutas.padre(ruta).hasSuffix("/build/reports")
                        && Self.informesDeGradle.contains(where: { nombre.hasPrefix($0) }) {
                a.enInformes = false
            }
        }
        // En carpetas de herramientas, sus componentes (plugins, runtimes…) no son archivos tuyos.
        if a.zona == .oculta && Self.componentes.contains(nombre.lowercased()) { a.clasificar = false }

        // Artefactos de proyectos: solo en tus carpetas (en Library o en carpetas ocultas son de las apps).
        if padre.clasificar && !padre.enArtefacto && (padre.zona == .personal || padre.zona == .compartida) {
            let carpetaPadre = (ruta as NSString).deletingLastPathComponent
            if carpetaPadre != home, let tipo = Self.artefacto(nombre: nombre, ruta: ruta, padre: carpetaPadre) {
                artefactos.append(Artefacto(ruta: ruta, tipo: tipo))
                // deps/ de Elixir y bower_components son dependencias descargadas, como node_modules.
                if nombre == "deps" || nombre == "bower_components" { a.enTerceros = true }
                a.enArtefacto = true
                a.clasificar = false
                a.esArtefacto = true
                return
            }
        }

        // Cachés que las apps (sobre todo las de Electron/Chromium) guardan junto a sus datos.
        if !a.enCacheInterna && ruta.hasPrefix(appSupport) {
            let padreNombre = ((ruta as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if Self.cachesInternasNombres.contains(nombre)
                || ((nombre == "CacheStorage" || nombre == "ScriptCache") && padreNombre == "Service Worker") {
                cachesInternas.append((ruta, .cache))
                a.enCacheInterna = true
            } else if nombre == "logs" || nombre == "Logs" || nombre == "Crashpad" {
                cachesInternas.append((ruta, .registros))
                a.enCacheInterna = true
            }
        }
    }

    private static func artefacto(nombre: String, ruta: String, padre: String) -> TipoArtefacto? {
        func hay(_ archivo: String) -> Bool { access(padre + "/" + archivo, F_OK) == 0 }
        /// ¿Hay al lado algún archivo con esa extensión? (proyecto.csproj, main.tf…)
        func hayExtension(_ extensiones: Set<String>) -> Bool {
            ((try? FileManager.default.contentsOfDirectory(atPath: padre)) ?? [])
                .contains { extensiones.contains(($0 as NSString).pathExtension.lowercased()) }
        }
        let gradle = { hay("build.gradle") || hay("build.gradle.kts") || hay("settings.gradle") || hay("settings.gradle.kts") }
        let python = { hay("pyproject.toml") || hay("setup.py") || hay("setup.cfg") || hay("requirements.txt") }
        let unity = { hay("Assets") && hay("ProjectSettings") }
        switch nombre {
        // Solo con el proyecto al lado: una carpeta que se llama así sin más no se da por regenerable.
        case "node_modules":
            return hay("package.json") || hay("package-lock.json") || hay("yarn.lock") || hay("pnpm-lock.yaml")
                || hay("bun.lockb") || hay("bun.lock") ? .node : nil
        case "Pods": return hay("Podfile") ? .pods : nil
        case "build":
            // electron-builder guarda en build/ sus recursos (icono, entitlements, instalador): no es una salida de compilación.
            let recursos = ["icon.icns", "icon.ico", "entitlements.mac.plist", "entitlements.plist", "installer.nsh"]
            if hay("package.json") && recursos.contains(where: { access(ruta + "/" + $0, F_OK) == 0 }) { return nil }
            return gradle() || hay("pubspec.yaml") || hay("CMakeLists.txt") || hay("package.json") || hay("Podfile")
                || python() || hayExtension(["xcodeproj"]) ? .compilacion : nil
        // Lo que generan al compilar las apps web, Electron y los paquetes de Python. Un requirements.txt solo
        // no basta: en proyectos de datos, «out/» suele guardar resultados de experimentos.
        case "dist":
            return hay("package.json") || hay("pyproject.toml") || hay("setup.py") || hay("setup.cfg") ? .compilacion : nil
        case "out":
            return hay("package.json") ? .compilacion : nil
        case ".output", ".nx", ".docusaurus", "storybook-static", ".vercel":
            return hay("package.json") ? .web : nil
        case "coverage", "htmlcov":
            return hay("package.json") || python() ? .pruebas : nil
        case ".tox", ".nox", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".hypothesis": return .python
        case ".terraform": return hayExtension(["tf"]) ? .terraform : nil
        case "Library", "Temp", "Logs": return unity() ? .unity : nil
        case "obj": return unity() ? .unity : (hayExtension(["csproj", "fsproj", "vbproj", "sln"]) ? .dotnet : nil)
        case "bin": return hayExtension(["csproj", "fsproj", "vbproj"]) ? .dotnet : nil
        case "zig-cache", ".zig-cache", "zig-out": return hay("build.zig") ? .compilacion : nil
        case "_build", "deps": return hay("mix.exs") ? .compilacion : nil
        case ".stack-work": return hay("stack.yaml") ? .compilacion : nil
        case "dist-newstyle": return hay("cabal.project") || hayExtension(["cabal"]) ? .compilacion : nil
        case "elm-stuff": return hay("elm.json") ? .compilacion : nil
        case "bower_components": return hay("bower.json") ? .node : nil
        case ".gradle": return gradle() || hay("gradlew") ? .gradle : nil
        case ".cxx": return gradle() ? .cxx : nil
        case ".kotlin": return gradle() ? .kotlin : nil
        case ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".vite":
            return hay("package.json") ? .web : nil
        case ".expo": return hay("package.json") ? .expo : nil
        case ".dart_tool": return hay("pubspec.yaml") ? .dart : nil
        case "DerivedData":
            return hayExtension(["xcodeproj", "xcworkspace"]) || hay("Package.swift") || hay("project.yml") || hay("Project.swift")
                ? .xcode : nil
        case ".build": return hay("Package.swift") ? .swiftpm : nil
        case "target": return hay("Cargo.toml") || hay("pom.xml") ? .cargo : nil
        default:
            if nombre.lowercased().contains("env") && access(ruta + "/pyvenv.cfg", F_OK) == 0 { return .venv }
            if nombre.hasPrefix("cmake-build-") && hay("CMakeLists.txt") { return .compilacion }   // CLion
            return nil
        }
    }

    // MARK: Archivos

    private func archivo(_ e: UnsafeMutablePointer<FTSENT>, _ a: inout Acumulador) {
        let st = e.pointee.fts_statp.pointee
        var b = Int64(st.st_blocks) * 512
        // Un archivo con varios enlaces solo se libera al borrar todos: se reparte su tamaño.
        if st.st_nlink > 1 { b /= Int64(st.st_nlink) }
        let mt = Int(st.st_mtimespec.tv_sec)
        a.bytes += b
        a.archivos += 1
        if mt > a.masReciente { a.masReciente = mt }
        if mt > a.masRecientePropio && !Self.esDeHerramienta(e) { a.masRecientePropio = mt }

        // Lo que un archivo grande comparte con clones (APFS) no se libera al borrarlo si queda otra copia.
        // Los comprimidos guardan sus datos aparte y el sistema no lo dice bien: se dan por privados.
        let asignado = Int64(st.st_blocks) * 512
        if asignado >= Privado.minimo && st.st_flags & UInt32(UF_COMPRESSED) == 0,
           let p = Privado.consultar(e.pointee.fts_path), p.privado < asignado {
            var compartido = asignado - p.privado
            if st.st_nlink > 1 { compartido /= Int64(st.st_nlink) }
            a.compartido += compartido
            if p.copias >= 2 {
                clonados.append(ArchivoClonado(ruta: String(cString: e.pointee.fts_path), inodo: st.st_ino, clon: p.clon,
                                               copias: p.copias, compartido: compartido))
            }
        }

        pendientesArchivos += 1
        pendientesBytes += b
        if pendientesArchivos >= 4096 {
            marcador.sumar(pendientesArchivos, pendientesBytes)
            pendientesArchivos = 0
            pendientesBytes = 0
        }

        let largoNombre = Int(e.pointee.fts_namelen)
        let nombre = e.pointee.fts_path + (Int(e.pointee.fts_pathlen) - largoNombre)
        let tamano = Int64(st.st_size)

        // Un .git que es un archivo: un worktree o un submódulo. También es un repositorio.
        if largoNombre == 4 && nombre[0] == 46 && nombre[1] == 103 && nombre[2] == 105 && nombre[3] == 116 /* .git */ {
            repos.insert(Rutas.padre(String(cString: e.pointee.fts_path)))
        }

        if a.enArtefacto {
            // Dentro de build/: interesan las apps compiladas para publicar y lo que la compilación no crea
            // (copias de bases de datos, trazas de rendimiento, documentos, llaves…), que no se regenera.
            let clave = claveExtension(nombre, largoNombre)
            if tamano > 1_000_000 && (clave == extAPK || clave == extAAB || clave == extIPA) {
                let n = String(cString: nombre).lowercased()
                if Self.esRelease(n) { releases.append(String(cString: e.pointee.fts_path)) }
                return
            }
            // Los paquetes descargados (node_modules, Pods…) a veces traen bases de datos o documentos de ejemplo,
            // y las apps compiladas llevan dentro copias de los recursos del proyecto: esos sí vuelven.
            guard !a.enTerceros && !a.enPaquete else { return }
            if extensionesNoRegenerables.contains(clave) || extensionesPersonales.contains(clave)
                || (clave == extKEY && tamano >= 20_000) {   // un .key grande es una presentación de Keynote
                let ruta = String(cString: e.pointee.fts_path)
                if !Self.generadoPorHerramientas(ruta) { noRegenerables.append(ruta) }
            } else if a.enInformes && extensionesHechasAMano.contains(clave) {
                noRegenerables.append(String(cString: e.pointee.fts_path))
            } else {
                secretoEnArtefacto(e, nombre: nombre, largo: largoNombre, clave: clave, tamano: tamano, acumulador: &a)
            }
            return
        }
        guard a.clasificar else { return }

        let clave = claveExtension(nombre, largoNombre)
        // Informes, tablas, capturas… de tus carpetas: así se sabe si lo que hay en /tmp tiene copia en otra parte.
        if (a.zona == .personal || a.zona == .compartida) && tamano > 0 && extensionesResultado.contains(clave) {
            let k = Resultados.clave(nombre, largoNombre, tamano)
            if (resultados[k]?.count ?? 0) < 3 { resultados[k, default: []].append(String(cString: e.pointee.fts_path)) }
        }
        let tipo = tablaExtensiones[clave] ?? .otro
        switch tipo {
        case .documento:
            // «_b_Lucene103_0.doc» es un trozo de un índice de búsqueda (Lucene), no un documento de Word.
            if clave == extDOC && nombre[0] == 95 /* _ */ && String(cString: nombre).contains("Lucene") { break }
            a.contenido.documentos += 1
        case .foto:
            if tamano >= 150_000 { a.contenido.fotos += 1 }
        case .video:
            if tamano >= 2_000_000 { a.contenido.videos += 1 }
        case .audio:
            if tamano >= 1_000_000 { a.contenido.audio += 1 }
        case .codigo:
            a.contenido.codigo += 1
        case .base:
            a.contenido.bases += 1
        case .clave:
            clasificarClave(e, clave: clave, tamano: tamano, acumulador: &a)
        case .instalador:
            if clave == extAAB || ((clave == extAPK || clave == extIPA) && Self.esRelease(String(cString: nombre).lowercased())) {
                releases.append(String(cString: e.pointee.fts_path))
            }
            if clave != extAAB && a.zona == .personal && tamano >= 1_000_000 {
                instaladores.append(indexado(e, st, b, a.zona))
            }
        case .comprimido:
            if a.zona == .personal && tamano >= 5_000_000 { comprimidos.append(indexado(e, st, b, a.zona)) }
        case .parcial:
            if a.zona == .personal { parciales.append(String(cString: e.pointee.fts_path)) }
        case .volcado:
            if a.zona != .library && a.zona != .sistema && tamano >= 1_000_000 { volcados.append(indexado(e, st, b, a.zona)) }
        case .registro:
            // «00000000000000000000.log» es un segmento de Kafka o el registro de LevelDB/RocksDB: datos, no un log.
            if a.zona != .library && a.zona != .sistema && tamano >= 20_000_000 {
                let n = String(cString: nombre)
                if !(n.dropLast(4).count >= 6 && n.dropLast(4).allSatisfy(\.isNumber)) { registrosGrandes.append(indexado(e, st, b, a.zona)) }
            }
        case .json, .plist, .properties:
            let n = String(cString: nombre)
            if n == "google-services.json" || n == "GoogleService-Info.plist" {
                sensibles.append(ArchivoSensible(ruta: String(cString: e.pointee.fts_path), tipo: .firebase, zona: a.zona))
            } else if n == "credentials.json" || n.hasPrefix("service-account") || n.hasPrefix("client_secret") {
                sensibles.append(ArchivoSensible(ruta: String(cString: e.pointee.fts_path), tipo: .secreto, zona: a.zona))
            } else if n == "gradle-wrapper.properties" {
                wrappersGradle.append(String(cString: e.pointee.fts_path))
            }
        case .otro:
            nombresEspeciales(e, nombre: nombre, largo: largoNombre, zona: a.zona)
        }

        if b >= 50_000_000 { grandes.append(indexado(e, st, b, a.zona)) }
        // Posibles copias repetidas: de tus carpetas (para borrar la que sobra) y también de las ocultas y de Library (para
        // unirlas en una sola sin borrar nada; ver `Escaner.duplicados`, que decide qué se ofrece para qué). Desde 256 KiB:
        // unir copias es de «Liberar al máximo», que también une las pequeñas; borrar la que sobra, desde 1 MB.
        if tamano >= Self.minimoDuplicable && (a.zona == .personal || a.zona == .oculta || a.zona == .library) {
            duplicables.append(indexado(e, st, b, a.zona))
        }
    }

    /// .DS_Store (lo escribe el Finder al abrir la carpeta) y los *.iml (los reescribe el editor): no son trabajo tuyo.
    @inline(__always)
    private static func esDeHerramienta(_ e: UnsafeMutablePointer<FTSENT>) -> Bool {
        let largo = Int(e.pointee.fts_namelen)
        let n = e.pointee.fts_path + (Int(e.pointee.fts_pathlen) - largo)
        if largo == 9 && n[0] == 46 /* . */ && n[1] == 68 /* D */ && n[2] == 83 /* S */ && n[3] == 95 /* _ */ { return true }
        return largo > 4 && n[largo - 4] == 46 /* . */ && n[largo - 3] == 105 /* i */ && n[largo - 2] == 109 /* m */
            && n[largo - 1] == 108 /* l */
    }

    private func clasificarClave(_ e: UnsafeMutablePointer<FTSENT>, clave: UInt64, tamano: Int64,
                                 acumulador a: inout Acumulador) {
        let ruta = String(cString: e.pointee.fts_path)
        let nombre = (ruta as NSString).lastPathComponent.lowercased()
        if clave == extKEY && tamano >= 20_000 {
            // Un .key grande es una presentación de Keynote, no una clave.
            a.contenido.documentos += 1
            return
        }
        if clave == extJKS || clave == extKEYSTORE {
            if nombre == "debug.keystore" { return }   // la de depuración se regenera sola
            // La «configuration cache» de Gradle cifra su estado con una clave propia que regenera sola: no es de firma.
            if ruta.contains("/cc-keystore/") { return }
            sensibles.append(ArchivoSensible(ruta: ruta, tipo: .keystore, zona: a.zona))
            return
        }
        // Certificados públicos de autoridades que traen muchas librerías: no son de nadie.
        let publicos = ["cacert", "ca-cert", "ca_cert", "ca-bundle", "ca_bundle", "ca-certificates", "certifi", "root-ca", "rootca"]
        if nombre == "cert.pem" || publicos.contains(where: { nombre.contains($0) }) { return }
        sensibles.append(ArchivoSensible(ruta: ruta, tipo: .certificado, zona: a.zona))
    }

    /// Una llave o contraseña dentro de una carpeta de compilación: la compilación no la crea, así que la puso alguien.
    /// Las copias que mete la propia compilación (perfiles de aprovisionamiento, configuración de Firebase) no cuentan.
    private func secretoEnArtefacto(_ e: UnsafeMutablePointer<FTSENT>, nombre: UnsafePointer<CChar>, largo: Int,
                                    clave: UInt64, tamano: Int64, acumulador a: inout Acumulador) {
        switch tablaExtensiones[clave] ?? .otro {
        case .clave:
            // Xcode copia el perfil de aprovisionamiento en cada app que compila; un .key grande es una presentación.
            if clave == extMOBILEPROVISION || clave == extPROVISIONPROFILE || (clave == extKEY && tamano >= 20_000) { return }
            clasificarClave(e, clave: clave, tamano: tamano, acumulador: &a)
        case .json:
            // credentials.json, service-account*.json, client_secret*.json
            guard nombre[0] == 99 /* c */ || nombre[0] == 115 /* s */ else { return }
            let n = String(cString: nombre)
            guard n == "credentials.json" || n.hasPrefix("service-account") || n.hasPrefix("client_secret") else { return }
            sensibles.append(ArchivoSensible(ruta: String(cString: e.pointee.fts_path), tipo: .secreto, zona: a.zona))
        case .otro:
            // .env, .netrc, id_rsa…: primero se mira el nombre byte a byte, que dentro de build/ hay miles de archivos.
            guard nombre[0] == 46 /* . */ || (largo >= 5 && nombre[0] == 105 && nombre[1] == 100 && nombre[2] == 95) /* id_ */ else { return }
            nombresEspeciales(e, nombre: nombre, largo: largo, zona: a.zona)
        default:
            return
        }
    }

    /// Archivos con pinta de tuyos que en realidad escribe una herramienta al compilar o al medir:
    /// la base de datos de Xcode y SwiftPM, el índice de búsqueda de Unity y los informes de Compose, JaCoCo, Kover y Criterion.
    private static func generadoPorHerramientas(_ ruta: String) -> Bool {
        ruta.hasSuffix("-composables.csv") || ruta.hasSuffix("/Library/Search/transactions.db")
            || ["/XCBuildData/", "/compose-compiler/", "/compose_compiler/", "/compose-metrics/", "/compose_metrics/",
                "/compose_reports/", "/reports/jacoco/", "/reports/kover/", "/target/criterion/"].contains { ruta.contains($0) }
    }

    private func nombresEspeciales(_ e: UnsafeMutablePointer<FTSENT>, nombre: UnsafePointer<CChar>, largo: Int, zona: Zona) {
        // .env, .env.local, .npmrc, .netrc… y llaves SSH (id_rsa, id_ed25519…)
        if nombre[0] == 46 /* . */ {
            let n = String(cString: nombre)
            let plantilla = [".example", ".template", ".sample", ".dist", ".defaults"].contains { n.hasSuffix($0) }
            if (n == ".env" || n.hasPrefix(".env.")) && !plantilla || n == ".netrc" || n == ".pypirc" {
                sensibles.append(ArchivoSensible(ruta: String(cString: e.pointee.fts_path), tipo: .secreto, zona: zona))
            } else if n == ".npmrc" {
                // Solo es secreto si guarda un token de acceso.
                let ruta = String(cString: e.pointee.fts_path)
                if let texto = try? String(contentsOfFile: ruta, encoding: .utf8), texto.contains("_auth") || texto.contains("token") {
                    sensibles.append(ArchivoSensible(ruta: ruta, tipo: .secreto, zona: zona))
                }
            }
        } else if largo >= 5 && nombre[0] == 105 && nombre[1] == 100 && nombre[2] == 95 /* id_ */ {
            let n = String(cString: nombre)
            if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(n) {
                sensibles.append(ArchivoSensible(ruta: String(cString: e.pointee.fts_path), tipo: .llaveSSH, zona: zona))
            }
        }
    }

    private func indexado(_ e: UnsafeMutablePointer<FTSENT>, _ st: stat, _ b: Int64, _ zona: Zona) -> ArchivoIndexado {
        ArchivoIndexado(ruta: String(cString: e.pointee.fts_path), bytes: b, tamano: Int64(st.st_size),
                        modificado: Int(st.st_mtimespec.tv_sec), dispositivo: st.st_dev, inodo: st.st_ino, zona: zona)
    }

    /// app-release.aab sí; app-debug.apk o app-release-unsigned.apk no.
    static func esRelease(_ n: String) -> Bool {
        n.contains("release") && !n.contains("unsigned") && !n.contains("debugsigned") && !n.contains("debug")
    }
}

// MARK: - Extensiones

fileprivate enum TipoArchivo: UInt8 {
    case otro, documento, foto, video, audio, codigo, base, clave, instalador, comprimido, json, plist, properties, parcial
    case volcado, registro
}

/// Convierte la extensión (hasta 16 letras, en minúsculas) en un número para compararla rápido.
@inline(__always)
fileprivate func claveExtension(_ p: UnsafePointer<CChar>, _ n: Int) -> UInt64 {
    var i = n - 1
    let tope = max(0, n - 18)
    while i >= tope {
        if p[i] == 46 { break }
        i -= 1
    }
    guard i > 0, i >= tope, p[i] == 46 else { return 0 }
    let largo = n - i - 1
    guard largo >= 1 && largo <= 16 else { return 0 }
    var k: UInt64 = 14_695_981_039_346_656_037
    var j = i + 1
    while j < n {
        var c = UInt8(bitPattern: p[j])
        if c >= 65 && c <= 90 { c += 32 }
        k = (k ^ UInt64(c)) &* 1_099_511_628_211
        j += 1
    }
    return k
}

fileprivate func claveDe(_ ext: String) -> UInt64 {
    ext.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
}

fileprivate let extAPK = claveDe("apk")
fileprivate let extAAB = claveDe("aab")
fileprivate let extIPA = claveDe("ipa")
fileprivate let extKEY = claveDe("key")
fileprivate let extJKS = claveDe("jks")
fileprivate let extKEYSTORE = claveDe("keystore")
fileprivate let extDOC = claveDe("doc")
fileprivate let extMOBILEPROVISION = claveDe("mobileprovision")
fileprivate let extPROVISIONPROFILE = claveDe("provisionprofile")
/// Lo que una compilación no crea nunca: si aparece dentro de build/, lo puso ahí alguien
/// (copias de bases de datos, trazas, modelos y resultados de experimentos).
fileprivate let extensionesNoRegenerables: Set<UInt64> = Set([
    "db", "sqlite", "sqlite3", "realm", "perfetto-trace",
    "pt", "pth", "ckpt", "safetensors", "onnx", "h5", "hdf5", "npy", "npz", "parquet", "pkl", "pickle", "joblib", "feather",
].map(claveDe))
/// Lo que tampoco crea nunca una compilación y suele ser tuyo: documentos, diseños, fotos de cámara, grabaciones y tablas.
/// (Las fotos JPG/PNG y los vídeos MP4 no están: las webs compiladas copian los suyos en dist/.)
fileprivate let extensionesPersonales: Set<UInt64> = Set([
    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "odt", "ods", "odp",
    "psd", "ai", "sketch", "fig", "xd", "indd", "afdesign", "afphoto", "procreate", "kra", "xcf", "blend",
    "heic", "heif", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "mov", "csv", "tsv", "rtf",
].map(claveDe))
/// En build/reports, fuera de los informes de Gradle: copias del código, scripts, notas y capturas que guardó alguien.
fileprivate let extensionesHechasAMano: Set<UInt64> = Set([
    "tar", "gz", "tgz", "zip", "7z", "py", "sh", "ipynb", "md", "sql", "png", "jpg", "jpeg",
].map(claveDe))

fileprivate let extensionesResultado: Set<UInt64> = Set(Resultados.extensiones.map(claveDe))

/// Archivos que guardan el resultado de un trabajo (informes, tablas, capturas, vídeos, zips, parches con cambios…). En
/// /tmp pueden ser lo único que queda de ese trabajo si no tienen copia en tus carpetas.
enum Resultados {
    static let extensiones: Set<String> = [
        "json", "csv", "tsv", "txt", "md", "html", "htm", "pdf", "xlsx", "xls", "docx", "pptx", "patch", "diff",
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "zip",
        "mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav",
    ]

    /// Clave de un archivo por su nombre (los bytes tal como los guarda el disco) y su tamaño.
    static func clave(_ nombre: UnsafePointer<CChar>, _ largo: Int, _ tamano: Int64) -> UInt64 {
        var k: UInt64 = 14_695_981_039_346_656_037
        for i in 0..<largo { k = (k ^ UInt64(UInt8(bitPattern: nombre[i]))) &* 1_099_511_628_211 }
        return (k ^ UInt64(bitPattern: tamano)) &* 1_099_511_628_211
    }
}

fileprivate let tablaExtensiones: [UInt64: TipoArchivo] = {
    var t: [UInt64: TipoArchivo] = [:]
    func agregar(_ tipo: TipoArchivo, _ lista: String) {
        for e in lista.split(separator: " ") { t[claveDe(String(e))] = tipo }
    }
    agregar(.documento, "pdf doc docx xls xlsx ppt pptx pages numbers odt ods odp rtf psd ai sketch fig xd indd afdesign afphoto procreate kra xcf blend epub")
    agregar(.foto, "jpg jpeg heic heif dng cr2 cr3 nef arw raf orf rw2")
    agregar(.video, "mp4 mov m4v avi mkv mts m2ts 3gp webm")
    agregar(.audio, "mp3 m4a wav aiff aif flac aac ogg")
    agregar(.codigo, "swift kt kts java js jsx ts tsx py rb go rs c cc cpp h hpp m mm cs php dart vue svelte scala")
    agregar(.base, "sqlite sqlite3 db realm sqlitedb")
    agregar(.clave, "jks keystore p12 pfx p8 mobileprovision provisionprofile pem key")
    agregar(.instalador, "dmg pkg mpkg iso xip apk xapk ipa aab")
    agregar(.comprimido, "zip rar 7z tar gz tgz bz2 xz zst")
    agregar(.json, "json")
    agregar(.plist, "plist")
    agregar(.properties, "properties")
    agregar(.parcial, "crdownload part partial opdownload")
    agregar(.volcado, "hprof")
    agregar(.registro, "log")
    return t
}()
