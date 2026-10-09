import Compression
import Foundation

/// Qué comprimir con la compresión transparente de APFS: lo que lleva la acción `.comprimir`. Al limpiar se vuelve a
/// buscar qué archivos cumplen las reglas (`Compresor.buscar`): no se reutiliza la lista del análisis.
struct Compresion: Hashable, Sendable {
    /// Carpetas en las que se busca (rutas completas, dentro de tu carpeta personal).
    var raices: [String]
    /// Solo archivos sin cambios (ni en su contenido ni en sus atributos) desde hace al menos estos días.
    var minDias: Double
    /// Si no está vacío, solo archivos con estas extensiones (en minúsculas y sin punto).
    var extensiones: Set<String> = []
    /// Las raíces son apps instaladas (.app de /Applications o ~/Applications): se entra en sus apps de dentro
    /// (ayudantes, extensiones) y la carpeta temporal va fuera de la app (`Compresor.temporalesDeApps`), para no dejar
    /// nunca nada suelto dentro de su paquete firmado. Ver `Seguridad.appPropia`.
    var apps = false
}

/// Lo que el análisis espera ahorrar comprimiendo (o uniendo copias idénticas), archivo por archivo. Sirve para no sumar
/// dos veces lo que otro elemento seleccionado borra: comprimir o unir algo que se va a borrar no ahorra nada. Se compara
/// por identidad, porque guarda miles de archivos y la interfaz compara elementos a menudo.
final class PrevisionCompresion: Hashable, Sendable {
    struct Archivo: Sendable {
        let ruta: String
        let ahorro: Int64
    }

    let archivos: [Archivo]
    /// Lo que ocupan ahora esos archivos.
    let ocupan: Int64
    /// Lo que se espera ahorrar.
    let ahorro: Int64
    /// Al unir copias: el archivo cuyo contenido comparten todas. Si otro elemento lo borra, no se une nada.
    let requiere: String?
    /// Los archivos y todas las carpetas que los contienen: así se sabe al momento si una ruta que otro elemento borra
    /// toca alguno, sin recorrer miles de archivos cada vez que se marca o desmarca algo (la interfaz lo pregunta a menudo).
    private let tocadas: Set<String>

    init(_ archivos: [Archivo], ocupan: Int64, requiere: String? = nil) {
        self.archivos = archivos
        self.ocupan = ocupan
        self.requiere = requiere
        ahorro = archivos.reduce(0) { $0 + $1.ahorro }
        var tocadas = Set<String>()
        for a in archivos {
            var actual = a.ruta
            // Las carpetas de un mismo sitio se repiten: se para en la primera que ya está.
            while actual.count > 1, tocadas.insert(actual).inserted { actual = Rutas.padre(actual) }
        }
        self.tocadas = tocadas
    }

    static func == (a: PrevisionCompresion, b: PrevisionCompresion) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    /// Lo que se ahorra sin contar los archivos que están en `borradas` (rutas que otro elemento elimina) o dentro.
    func ahorro(sin borradas: Set<String>) -> Int64 {
        guard !borradas.isEmpty else { return ahorro }
        if let requiere, borradas.contains(requiere) || Totales.dentroDe(requiere, borradas) { return 0 }
        // Con pocos archivos (unir copias), se mira cada uno; con muchos (comprimir miles), se miran las borradas: solo
        // cuentan las que son uno de estos archivos o una carpeta que contiene alguno (casi nunca hay ninguna).
        guard archivos.count * 8 > borradas.count else {
            return archivos.reduce(0) { $0 + (borradas.contains($1.ruta) || Totales.dentroDe($1.ruta, borradas) ? 0 : $1.ahorro) }
        }
        let quitan = borradas.filter(tocadas.contains)
        guard !quitan.isEmpty else { return ahorro }
        return archivos.reduce(0) { suma, a in
            suma + (quitan.contains { a.ruta == $0 || a.ruta.hasPrefix($0 + "/") } ? 0 : a.ahorro)
        }
    }
}

/// Compresión transparente de APFS: el archivo ocupa menos en el disco y se lee igual (el sistema lo descomprime al
/// leerlo, como hace con sus propias apps). Si un programa vuelve a escribir en él, macOS lo descomprime solo. No se
/// borra nada: cada archivo se copia comprimido con `ditto --noclone --hfsCompression`, se comprueba byte a byte y solo
/// entonces se cambia por el original. Ante cualquier fallo, el original se queda como estaba.
enum Compresor {
    /// Menos de esto apenas ahorra (el disco guarda por bloques de 4 KiB).
    static let tamanoMinimo: Int64 = 16 * 1024
    /// ditto no comprime los archivos de más de unos 512 MiB: se quedan como están.
    static let tamanoMaximo: Int64 = 512 * 1024 * 1024
    /// Espacio libre de verdad que tiene que quedar, además de lo que ocupa la copia mientras se comprueba.
    static let margenLibre: Int64 = 2_000_000_000
    /// ditto descarta la compresión de los archivos que ahorran poco: según la estimación (`estimar`), los que dejan más de
    /// un 86 % de lo que ocupan. Esos ni se intentan.
    static let maximoEstimado = 0.86
    /// Un trozo de 64 KiB que con LZ4 deja más de un 80 % (casi siempre imágenes o binarios en base64 dentro de una
    /// conversación) se cuenta como guardado sin comprimir: LZVN tampoco gana nada con él.
    static let trozoSinComprimir = 0.80
    /// En los demás trozos, LZVN deja de media un 87 % de lo que deja LZ4.
    static let lzvnFrenteALZ4 = 0.87
    /// Archivos y bytes por lote: cada lote es una llamada a ditto por casilla y dos lecturas de lo que está abierto.
    static let archivosPorLote = 300
    static let bytesPorLote: Int64 = 1 << 30

    /// Solo en modo diagnóstico con una casa de prueba, LIMPIADOR_SIN_CTIME=1 no exige la antigüedad del cambio de
    /// estado (ctime): en los archivos de prueba la fecha de modificación se finge con touch, pero ctime no se puede.
    static let mirarCtime = !(Rutas.casaDePrueba && ProcessInfo.processInfo.environment["LIMPIADOR_SIN_CTIME"] == "1")

    /// Lo que no se comprime nunca. Bases de datos y sus diarios (se escriben a trozos y suelen seguir abiertas), discos
    /// virtuales, candados, procesos y sockets, y lo que ya viene comprimido (no ganaría nada).
    static let extensionesExcluidas: Set<String> = [
        "sqlite", "sqlite3", "db", "db3", "realm", "ldb", "mdb", "wal", "shm",
        "qcow2", "qcow", "vmdk", "vdi", "vhd", "vhdx", "hdd", "raw", "dmg", "sparseimage", "sparsebundle", "iso", "cdr",
        "lock", "pid", "sock",
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "mp3", "m4a", "aac", "flac", "ogg", "opus",
        "mp4", "m4v", "mov", "mkv", "webm", "avi",
        "zip", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "zstd", "lz4", "lzma", "7z", "rar", "br",
        "jar", "war", "aar", "apk", "apks", "aab", "ipa", "xip", "whl", "pkg", "woff", "woff2", "pack", "idx",
        "keystore", "jks",
    ]
    /// En las apps, estos sí se miran: muchas guardan sus .jar sin comprimir por dentro para arrancar antes (los de
    /// Android Studio e IntelliJ). La muestra decide: los que de verdad vienen comprimidos no ahorran y se quedan.
    private static let paquetesQueSeMiranEnApps: Set<String> = ["jar", "zip", "war", "aar"]
    /// Terminaciones de diarios de bases de datos y candados («historial.db-wal», «x.sqlite-journal», «.lock»).
    private static let finalesExcluidos = ["-wal", "-shm", "-journal", ".lock"]

    /// Carpetas en las que no se entra: el historial de git (ya va comprimido), las apps (macOS pide un permiso aparte
    /// para modificarlas; solo al comprimir una app, con `apps`, se entra en las que lleva dentro), los emuladores de
    /// Android (sus discos se escriben por bloques), las bibliotecas de fotos y las carpetas temporales de esta misma
    /// compresión.
    private static func saltarCarpeta(_ nombre: String, apps: Bool) -> Bool {
        nombre == ".git" || (!apps && nombre.hasSuffix(".app")) || nombre.hasSuffix(".avd") || nombre.hasSuffix(".photoslibrary")
            || nombre.hasPrefix(prefijoTemporal)
    }

    /// Dónde van las carpetas temporales al comprimir apps: fuera de la app y en el mismo disco (tu carpeta personal y
    /// /Applications están en el volumen de datos), para que una compresión cortada nunca deje nada suelto dentro de un
    /// paquete firmado.
    static var temporalesDeApps: String { Rutas.enHome("Library/Application Support/LimpiadorMac/comprimiendo").path }

    /// Las banderas con las que un archivo no se toca: ya comprimido, inmutable, solo para añadir, del sistema, sin
    /// datos en el disco (dataless: leerlo lo descargaría de la nube) o seguido por su número de documento.
    private static let banderasProhibidas = UInt32(UF_COMPRESSED) | UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)
        | UInt32(UF_TRACKED) | UInt32(SF_IMMUTABLE) | UInt32(SF_APPEND) | UInt32(SF_RESTRICTED) | UInt32(SF_NOUNLINK)
        | UInt32(SF_DATALESS)

    // MARK: Estado de un archivo

    struct Tiempo: Hashable, Sendable {
        let s: Int
        let ns: Int
        init(_ t: timespec) { s = t.tv_sec; ns = t.tv_nsec }
        var ts: timespec { timespec(tv_sec: s, tv_nsec: ns) }
    }

    /// Lo que se sabe de un archivo (lstat): sirve para comprobar que no cambió entre un paso y el siguiente.
    struct EstadoArchivo: Equatable, Sendable {
        let dispositivo: Int32
        let inodo: UInt64
        let tamano: Int64
        /// Lo que ocupa en el disco (bloques asignados).
        let ocupa: Int64
        let enlaces: UInt16
        let modo: UInt16
        let banderas: UInt32
        let dueno: uid_t
        let grupo: gid_t
        let modificado: Tiempo
        let cambiado: Tiempo
        let creado: Tiempo
        let accedido: Tiempo

        init(_ st: stat) {
            dispositivo = st.st_dev
            inodo = st.st_ino
            tamano = Int64(st.st_size)
            ocupa = Int64(st.st_blocks) * 512
            enlaces = st.st_nlink
            modo = st.st_mode
            banderas = st.st_flags
            dueno = st.st_uid
            grupo = st.st_gid
            modificado = Tiempo(st.st_mtimespec)
            cambiado = Tiempo(st.st_ctimespec)
            creado = Tiempo(st.st_birthtimespec)
            accedido = Tiempo(st.st_atimespec)
        }

        init?(ruta: String) {
            var st = stat()
            guard lstat(ruta, &st) == 0 else { return nil }
            self.init(st)
        }

        var esRegular: Bool { modo & S_IFMT == S_IFREG }

        /// Es el mismo archivo y nadie lo cambió: ni su contenido ni sus atributos (ctime cambia con cualquier cosa).
        func sinCambios(desde o: EstadoArchivo) -> Bool {
            dispositivo == o.dispositivo && inodo == o.inodo && tamano == o.tamano && modificado == o.modificado
                && cambiado == o.cambiado && banderas == o.banderas && modo == o.modo && enlaces == o.enlaces
        }

        /// Es el mismo archivo y su contenido no cambió (tras moverlo de carpeta su ctime cambia, así que no se mira).
        func mismoContenido(que o: EstadoArchivo) -> Bool {
            dispositivo == o.dispositivo && inodo == o.inodo && tamano == o.tamano && modificado == o.modificado
        }
    }

    // MARK: Buscar

    /// Un archivo que se puede comprimir.
    struct Candidato: Sendable {
        /// Tal como se escribió la raíz (como las demás rutas de la app).
        let ruta: String
        /// La misma ruta sin enlaces en sus carpetas: así la da el sistema para lo que está abierto.
        let rutaReal: String
        /// Índice de su raíz en `Compresion.raices`.
        let raiz: Int
        let estado: EstadoArchivo
        /// Lo que se espera ahorrar.
        var ahorro: Int64 = 0
    }

    /// Lo que encontró una búsqueda: los candidatos y lo que se quedó fuera, para explicarlo.
    struct Busqueda: Sendable {
        var candidatos: [Candidato] = []
        /// Cambiados hace menos de `minDias`.
        var recientes = 0
        /// Abiertos por algún programa (o cargados en memoria, si son programas o librerías).
        var abiertos = 0
        /// Clones de APFS o con varios nombres (enlaces duros): comprimirlos ocuparía más, no menos.
        var compartidos = 0
        /// De más de 512 MiB: ditto no los comprime.
        var grandes = 0
        var bytesGrandes: Int64 = 0
        /// Se estima que ahorran menos de un 20 % (ditto no los comprimiría).
        var noRentan = 0
        /// Ya estaban comprimidos.
        var yaComprimidos = 0
        var bytesYaComprimidos: Int64 = 0
        /// Lo que ocupan todos los archivos que se miraron (también los que no son tuyos o no se pueden comprimir): con
        /// las apps sirve para saber cuánto supone el ahorro.
        var bytesVistos: Int64 = 0
        /// Lo que miden (su tamaño, no lo que ocupan) todos los que se miraron y, de eso, los que ya venían comprimidos: con
        /// las apps dice qué parte ya viene comprimida (WhatsApp, Xcode…).
        var tamanoVisto: Int64 = 0
        var tamanoYaComprimido: Int64 = 0
        /// Los mayores de 512 MiB que se quedan como están (nombre y lo que ocupan), para decirlo.
        var nombresGrandes: [(nombre: String, bytes: Int64)] = []
        /// Al buscar en apps: macOS no deja modificar alguna de sus carpetas (EPERM: falta el permiso «Gestión de apps»).
        /// Sus archivos cuentan igual como candidatos; al comprimir, el primer intercambio lo confirma y se para.
        var faltaPermiso = false
        /// El archivo más reciente de los candidatos.
        var masReciente: Date?

        var ocupan: Int64 { candidatos.reduce(0) { $0 + $1.estado.ocupa } }
        var ahorro: Int64 { candidatos.reduce(0) { $0 + $1.ahorro } }
    }

    /// Los archivos de `c` que se pueden comprimir: regulares, tuyos, con un solo nombre, sin banderas especiales, de 16 KiB
    /// a 512 MiB, sin cambios desde hace `minDias` (fecha de modificación y de cambio de estado), que no comparten bloques
    /// con un clon, que nadie tiene abiertos según `abiertos` y que no están excluidos por su tipo. Con `estimar`, además
    /// solo los que se estima que ditto comprimirá (ver `estimar`). Los de `excluir` no se tocan (las copias que se van a
    /// unir con otra: comprimidas ahora, dejarían de estarlo al cambiarlas por un clon). `ahora` solo se cambia en las
    /// pruebas.
    static func buscar(_ c: Compresion, abiertos: ArchivosAbiertos, estimar: Bool = true, excluir: Set<String> = [],
                       ahora: Date = Date()) -> Busqueda {
        var b = Busqueda()
        let limite = Int(ahora.timeIntervalSince1970 - c.minDias * 86400)
        let uid = getuid()
        // Para cambiar un archivo por su copia hay que poder escribir en su carpeta (algunas herramientas dejan las
        // suyas de solo lectura): se mira una vez por carpeta.
        var carpetaAnterior = ""
        var sePuedeEscribir = false
        for (i, raiz) in c.raices.enumerated() where Seguridad.sePuedeModificar(URL(fileURLWithPath: raiz), apps: c.apps) {
            let real = Rutas.real(URL(fileURLWithPath: raiz))
            guard let rutaC = strdup(raiz) else { continue }
            defer { free(rutaC) }
            var argumentos: [UnsafeMutablePointer<CChar>?] = [rutaC, nil]
            guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { continue }
            defer { fts_close(fts) }
            while let e = fts_read(fts) {
                let tipo = Int32(e.pointee.fts_info)
                // El nombre está al final de la ruta (sin cambiar de carpeta, fts da la ruta entera).
                func leerNombre() -> String {
                    String(cString: e.pointee.fts_path + (Int(e.pointee.fts_pathlen) - Int(e.pointee.fts_namelen)))
                }
                if tipo == FTS_D {
                    if e.pointee.fts_level > 0 && saltarCarpeta(leerNombre(), apps: c.apps) { fts_set(fts, e, FTS_SKIP) }
                    continue
                }
                guard tipo == FTS_F else { continue }
                let st = e.pointee.fts_statp.pointee
                b.bytesVistos += Int64(st.st_blocks) * 512
                b.tamanoVisto += Int64(st.st_size)
                if st.st_flags & UInt32(UF_COMPRESSED) != 0 { b.tamanoYaComprimido += Int64(st.st_size) }
                guard st.st_uid == uid, st.st_size >= tamanoMinimo, st.st_mode & S_IRUSR != 0 else { continue }
                if st.st_flags & UInt32(UF_COMPRESSED) != 0 {
                    b.yaComprimidos += 1
                    b.bytesYaComprimidos += Int64(st.st_blocks) * 512
                    continue
                }
                guard st.st_flags & banderasProhibidas == 0 else { continue }
                let nombre = leerNombre()
                guard !nombre.hasPrefix("._"), !finalesExcluidos.contains(where: { nombre.hasSuffix($0) }) else { continue }
                let ext = (nombre as NSString).pathExtension.lowercased()
                guard !extensionesExcluidas.contains(ext) || (c.apps && paquetesQueSeMiranEnApps.contains(ext)),
                      c.extensiones.isEmpty || c.extensiones.contains(ext) else { continue }
                if st.st_size > tamanoMaximo {
                    b.grandes += 1
                    b.bytesGrandes += Int64(st.st_blocks) * 512
                    b.nombresGrandes.append((nombre, Int64(st.st_blocks) * 512))
                    continue
                }
                guard st.st_mtimespec.tv_sec <= limite, !mirarCtime || st.st_ctimespec.tv_sec <= limite else {
                    b.recientes += 1
                    continue
                }
                let ruta = String(cString: e.pointee.fts_path)
                guard !excluir.contains(ruta) else { continue }
                let carpeta = Rutas.padre(ruta)
                if carpeta != carpetaAnterior {
                    carpetaAnterior = carpeta
                    sePuedeEscribir = access(carpeta, W_OK) == 0
                    // Dentro de una app, EPERM con permisos de escritura es el permiso «Gestión de apps» de macOS: se
                    // cuenta (para decirlo y pedirlo), no es una carpeta de solo lectura.
                    if !sePuedeEscribir && c.apps && errno == EPERM {
                        sePuedeEscribir = true
                        b.faltaPermiso = true
                    }
                }
                guard sePuedeEscribir else { continue }
                let rutaReal = real + ruta.dropFirst(raiz.count)
                guard abiertos.hayAbierto(rutaReal: rutaReal) == nil else {
                    b.abiertos += 1
                    continue
                }
                // Un clon comparte sus bloques con otra copia: la copia comprimida ocuparía espacio nuevo y el clon
                // seguiría reteniendo el de siempre. Si el sistema no sabe decirlo, tampoco se toca.
                let ocupa = Int64(st.st_blocks) * 512
                guard st.st_nlink == 1, let privado = Privado.consultar(ruta), privado.privado >= ocupa else {
                    b.compartidos += 1
                    continue
                }
                b.candidatos.append(Candidato(ruta: ruta, rutaReal: rutaReal, raiz: i, estado: EstadoArchivo(st)))
            }
        }
        if estimar {
            // Leer muestras de miles de archivos: en paralelo.
            final class Caja: @unchecked Sendable { var ahorros: [Int: Int64] = [:] }
            let caja = Caja()
            let candado = NSLock()
            let lista = b.candidatos
            DispatchQueue.concurrentPerform(iterations: lista.count) { j in
                let ahorro = Self.estimar(lista[j].ruta, tamano: lista[j].estado.tamano, ocupa: lista[j].estado.ocupa)
                candado.lock()
                caja.ahorros[j] = ahorro
                candado.unlock()
            }
            for j in b.candidatos.indices { b.candidatos[j].ahorro = caja.ahorros[j] ?? 0 }
            b.noRentan = b.candidatos.filter { $0.ahorro == 0 }.count
            b.candidatos.removeAll { $0.ahorro == 0 }
        }
        b.masReciente = b.candidatos.map { Date(timeIntervalSince1970: TimeInterval($0.estado.modificado.s)) }.max()
        return b
    }

    /// Lo que se espera ahorrar al comprimir un archivo, o 0 si ditto no lo comprimiría. ditto comprime con LZVN, que no
    /// está en la biblioteca Compression: se estima con LZ4, de la misma familia (sin codificación de entropía), trozo a
    /// trozo de 64 KiB, como guarda el sistema. Un trozo que con LZ4 casi no se comprime (más de un 80 %: imágenes en base64
    /// dentro de una conversación, datos ya comprimidos) cuenta entero; en los demás, LZVN deja un 87 % de lo que deja
    /// LZ4. Calibrado con ditto y copias de conversaciones reales de Codex y Claude Code (de 16 KB a 140 MB) y de
    /// programas, librerías y jars: el total estimado queda entre un 6 % por debajo y un 6 % por encima del real. Se lee
    /// uno de cada 8 trozos en los archivos de 8 MiB o más y uno de cada 16 (al menos 4, o todos si son 4 o menos) en los
    /// demás, cada uno del centro de su tramo para no darle más peso al principio del archivo (las cabeceras comprimen
    /// mucho mejor que el resto).
    static func estimar(_ ruta: String, tamano: Int64, ocupa: Int64) -> Int64 {
        let trozo = 65_536
        let fd = open(ruta, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let trozos = Int((tamano + Int64(trozo) - 1) / Int64(trozo))
        // En los grandes (8 MiB o más), donde las imágenes en base64 van en bloques, más muestras; en los demás basta con menos.
        let muestras = trozos >= 128 ? max(16, trozos / 8) : min(trozos, max(4, trozos / 16))
        let elegidos = muestras == trozos ? Array(0..<trozos) : (0..<muestras).map { (2 * $0 + 1) * trozos / (2 * muestras) }
        var buf = [UInt8](repeating: 0, count: trozo)
        var destino = [UInt8](repeating: 0, count: trozo + trozo / 255 + 64)
        var leidos = 0
        var estimado = 0.0
        for i in elegidos {
            let n = pread(fd, &buf, trozo, off_t(i) * off_t(trozo))
            guard n > 0 else { break }
            let c = compression_encode_buffer(&destino, destino.count, buf, n, nil, COMPRESSION_LZ4_RAW)
            leidos += n
            estimado += c == 0 || Double(c) > trozoSinComprimir * Double(n) ? Double(n) : Double(c) * lzvnFrenteALZ4
        }
        guard leidos > 0 else { return 0 }
        let proporcion = estimado / Double(leidos)
        guard proporcion <= maximoEstimado else { return 0 }
        // La copia guarda además una tabla con el sitio de cada trozo y una cabecera; el disco reserva bloques de 4 KiB.
        let bytes = Double(tamano) * proporcion + Double(trozos * 8 + 300)
        let ocupara = Int64((bytes / 4096).rounded(.up)) * 4096
        return max(0, ocupa - ocupara)
    }

    // MARK: Comprimir

    /// Pasos en los que una prueba puede intervenir (abrir el archivo, cambiarlo…) o simular un fallo.
    enum Paso: Sendable { case copiado, verificado, antesDeCambiar, cambiado, antesDeBorrar }
    /// `.fallar` hace que ese paso falle (y se deshaga lo hecho con ese archivo); `.abortar` para en seco sin recoger
    /// nada, como si la app se cerrara de golpe.
    enum Simulado: Sendable { case seguir, fallar, abortar }
    typealias Simulacion = (Paso, String) -> Simulado

    struct Resultado: Sendable {
        /// Archivos comprimidos y lo que se ahorró de verdad (bloques antes menos bloques después).
        var comprimidos = 0
        var ahorro: Int64 = 0
        /// Lo mismo por raíz, para el historial.
        var porRaiz: [String: (archivos: Int, ahorro: Int64)] = [:]
        /// ditto no los comprimió (no ganaba bastante): se quedan como estaban.
        var noSeDejaron = 0
        /// Abiertos por algún programa al ir a cambiarlos.
        var abiertos = 0
        /// Cambiaron entre la búsqueda y el momento de cambiarlos (alguien escribió en ellos).
        var cambiaron = 0
        /// Lo que falló (el original se queda como estaba).
        var fallos: [String] = []
        /// Se paró porque no quedaba espacio libre con margen.
        var sinEspacio = false
        /// Se paró porque se pidió detener.
        var detenido = false
        /// Se paró porque algo empezó a usar lo que se comprimía (el emulador, por ejemplo).
        var enUsoPor: String?
        /// Copias de una compresión que se cortó y que no se pudieron dar por repetidas: se dejan donde están.
        var copiasGuardadas: [String] = []
        /// macOS no dejó cambiar un archivo de una app (EPERM o EACCES al intercambiarlo): falta el permiso «Gestión de
        /// apps». Se para ahí y lo que no se cambió se queda como estaba.
        var sinPermiso = false
        /// Los archivos que se cambiaron de verdad (solo al comprimir apps o al descomprimir): para poder deshacerlo.
        var archivos: [String] = []
        /// Al descomprimir: lo que vuelven a ocupar de más (bloques después menos bloques antes).
        var aumento: Int64 = 0
    }

    /// Qué hace un lote: comprimir (`ditto --hfsCompression`) o deshacerlo (`ditto --nopreserveHFSCompression`, que
    /// escribe el contenido sin comprimir). El resto del camino (copia, comprobación byte a byte, intercambio atómico y
    /// vuelta atrás si algo cambia) es el mismo.
    enum Sentido: Sendable { case comprimir, descomprimir }

    /// Nombre de las carpetas temporales: «.limpiador-<UUID>», dentro de la raíz que se comprime.
    static let prefijoTemporal = ".limpiador-"

    /// Comprime los archivos de `c`, de lote en lote. Por cada archivo:
    /// 1. ditto --noclone --hfsCompression deja una copia comprimida en una carpeta temporal de la misma raíz;
    /// 2. se comprueba la copia: comprimida, del mismo tamaño, con el mismo contenido byte a byte y los mismos permisos,
    ///    dueño, banderas, atributos extendidos y ACL; se le ponen las fechas del original (creación, modificación y
    ///    acceso), que ditto no conserva todas;
    /// 3. si el original no cambió y nadie lo tiene abierto, se intercambian los dos de golpe (renamex_np con
    ///    RENAME_SWAP): la copia comprimida queda en su sitio y el original, en la carpeta temporal. Mientras el
    ///    intercambio se pueda deshacer, la copia no se deja escribir (lo que alguien escribiera en ella se perdería al
    ///    devolver el original);
    /// 4. se vuelve a mirar: si un programa tenía abierto el original (ahora lo tendría en la carpeta temporal) o lo
    ///    cambió durante el intercambio, se deshace; si no, se borra el original y la copia recupera sus permisos.
    /// Ante cualquier fallo, el original se queda como estaba y se borra la copia. `enUso` se mira antes de cada lote
    /// (para lo que no se debe tocar mientras algo funciona, como el emulador). Los archivos de `excluir` se saltan (ver
    /// `buscar`). `libre` y `simular` solo se cambian en las pruebas.
    static func comprimir(_ c: Compresion, progreso: (_ hechos: Int, _ total: Int, _ ahorro: Int64) -> Void = { _, _, _ in },
                          cancelado: () -> Bool = { false }, enUso: () -> String? = { nil }, excluir: Set<String> = [],
                          libre: () -> Int64 = { InfoDisco.libreAhora() }, simular: Simulacion? = nil) -> Resultado {
        var r = Resultado()
        let raices = c.raices.filter { Seguridad.sePuedeModificar(URL(fileURLWithPath: $0), apps: c.apps) }
        guard let temporal = prepararTemporal(apps: c.apps, &r) else { return r }
        for raiz in raices { r.copiasGuardadas += recogerRestos(en: raiz) }
        let abiertos = ArchivosAbiertos.ahora()
        guard abiertos.leidos else {
            r.fallos.append("No pude ver qué archivos tienen abiertos los programas, así que no comprimí nada.")
            return r
        }
        let busqueda = buscar(c, abiertos: abiertos, excluir: excluir)
        r.abiertos = busqueda.abiertos
        let lotes = agrupar(busqueda.candidatos, raices: c.raices, temporal: temporal, primeroSolo: c.apps)
        // Las carpetas temporales van en la raíz de cada lote: se apunta dónde, para recoger sus restos aunque la app se
        // cierre de golpe y ahí ya no quede nada que comprimir (las de las apps van siempre a `temporalesDeApps`).
        let usadas = c.apps ? [] : Array(Set(lotes.map(\.raiz))).sorted()
        apuntarRaices(usadas)
        procesarLotes(lotes, total: busqueda.candidatos.count, sentido: .comprimir, anotar: c.apps, &r, progreso: progreso,
                      cancelado: cancelado, enUso: enUso, libre: libre, simular: simular)
        olvidarRaices(usadas.filter { !tieneRestos($0) })
        return r
    }

    /// Deshace la compresión de esos archivos (los que comprimió esta app, apuntados en `AppsComprimidas`): cada uno se
    /// copia sin comprimir con `ditto --nopreserveHFSCompression`, se comprueba byte a byte y se cambia por el comprimido
    /// con el mismo intercambio atómico. Solo se tocan los que siguen comprimidos, son tuyos, no tienen otros nombres y
    /// nadie tiene abiertos; si algo falla, el archivo se queda comprimido (se lee igual). Con `apps`, la carpeta
    /// temporal va fuera de la app. `raiz` es la carpeta (la app) dentro de la que tienen que estar todos.
    static func descomprimir(_ rutas: [String], raiz: String, apps: Bool,
                             progreso: (_ hechos: Int, _ total: Int, _ aumento: Int64) -> Void = { _, _, _ in },
                             cancelado: () -> Bool = { false }, enUso: () -> String? = { nil },
                             libre: () -> Int64 = { InfoDisco.libreAhora() }, simular: Simulacion? = nil) -> Resultado {
        var r = Resultado()
        guard Seguridad.sePuedeModificar(URL(fileURLWithPath: raiz), apps: apps) else {
            r.fallos.append("\(Formato.rutaCorta(raiz)): no es una carpeta que pueda modificar.")
            return r
        }
        guard let temporal = prepararTemporal(apps: apps, &r) else { return r }
        r.copiasGuardadas += recogerRestos(en: raiz)
        let abiertos = ArchivosAbiertos.ahora()
        guard abiertos.leidos else {
            r.fallos.append("No pude ver qué archivos tienen abiertos los programas, así que no descomprimí nada.")
            return r
        }
        let real = Rutas.real(URL(fileURLWithPath: raiz))
        var candidatos: [Candidato] = []
        for ruta in Set(rutas).sorted() where ruta.hasPrefix(raiz + "/") {
            guard let e = EstadoArchivo(ruta: ruta), e.esRegular, e.dueno == getuid(), e.enlaces == 1,
                  e.banderas & UInt32(UF_COMPRESSED) != 0, e.banderas & (banderasProhibidas & ~UInt32(UF_COMPRESSED)) == 0,
                  access(Rutas.padre(ruta), W_OK) == 0 || (apps && errno == EPERM) else { continue }
            let rutaReal = real + ruta.dropFirst(raiz.count)
            guard abiertos.hayAbierto(rutaReal: rutaReal) == nil else {
                r.abiertos += 1
                continue
            }
            candidatos.append(Candidato(ruta: ruta, rutaReal: rutaReal, raiz: 0, estado: e))
        }
        let lotes = agrupar(candidatos, raices: [raiz], temporal: temporal, primeroSolo: apps)
        let usadas = apps || lotes.isEmpty ? [] : [raiz]
        apuntarRaices(usadas)
        procesarLotes(lotes, total: candidatos.count, sentido: .descomprimir, anotar: true, &r, progreso: progreso,
                      cancelado: cancelado, enUso: enUso, libre: libre, simular: simular)
        olvidarRaices(usadas.filter { !tieneRestos($0) })
        return r
    }

    /// La carpeta en la que se crean las temporales: nil (y no se hace nada) si es la de las apps y no se pudo crear.
    /// "" quiere decir «en la raíz de cada lote», como siempre. Con apps se recogen también los restos de una compresión
    /// de apps que se cortó.
    private static func prepararTemporal(apps: Bool, _ r: inout Resultado) -> String? {
        guard apps else { return "" }
        let carpeta = temporalesDeApps
        do {
            try FileManager.default.createDirectory(atPath: carpeta, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            r.fallos.append("No pude crear la carpeta temporal \(Formato.rutaCorta(carpeta)) (\(error.localizedDescription)); no toqué nada.")
            return nil
        }
        r.copiasGuardadas += recogerRestos(en: carpeta)
        return carpeta
    }

    /// Procesa los lotes uno a uno, mirando antes de cada uno si se pidió detener, si algo empezó a usarlo y si queda
    /// sitio con margen. Para en cuanto macOS no deja cambiar un archivo (`sinPermiso`).
    private static func procesarLotes(_ lotes: [Lote], total: Int, sentido: Sentido, anotar: Bool, _ r: inout Resultado,
                                      progreso: (_ hechos: Int, _ total: Int, _ ahorro: Int64) -> Void,
                                      cancelado: () -> Bool, enUso: () -> String?, libre: () -> Int64,
                                      simular: Simulacion?) {
        var hechos = 0
        progreso(0, total, 0)
        for lote in lotes {
            if cancelado() {
                r.detenido = true
                break
            }
            if let quien = enUso() {
                r.enUsoPor = quien
                break
            }
            // La copia ocupa espacio hasta que se borra el original: tiene que caber con margen.
            let necesario = lote.casillas.joined().reduce(Int64(0)) { $0 + $1.estado.tamano }
            guard libre() >= necesario + margenLibre else {
                r.sinEspacio = true
                break
            }
            guard procesar(lote, sentido: sentido, anotar: anotar, &r, simular: simular) else { return }
            hechos += lote.casillas.joined().count
            progreso(hechos, total, sentido == .comprimir ? r.ahorro : r.aumento)
            if r.sinPermiso { break }
        }
    }

    /// Unos cuantos archivos de una misma raíz que se comprimen juntos. Cada casilla es una carpeta temporal (y una
    /// llamada a ditto) en la que no se repite ningún nombre. `temporal` es donde se crea la carpeta temporal del lote
    /// (la raíz, o la de las apps).
    struct Lote {
        let raiz: String
        let raizReal: String
        let temporal: String
        let temporalReal: String
        var casillas: [[Candidato]] = []

        init(raiz: String, raizReal: String, temporal: String, casillas: [[Candidato]] = []) {
            self.raiz = raiz
            self.raizReal = raizReal
            self.temporal = temporal.isEmpty ? raiz : temporal
            temporalReal = temporal.isEmpty ? raizReal : Rutas.real(URL(fileURLWithPath: temporal))
            self.casillas = casillas
        }
    }

    /// Con `primeroSolo` (apps), el primer lote de cada raíz lleva un solo archivo, el más pequeño: si macOS no deja
    /// modificar la app (falta «Gestión de apps»), se sabe sin haber comprimido un lote entero.
    private static func agrupar(_ candidatos: [Candidato], raices: [String], temporal: String, primeroSolo: Bool = false) -> [Lote] {
        var lotes: [Lote] = []
        let porRaiz = Dictionary(grouping: candidatos, by: \.raiz)
        for i in porRaiz.keys.sorted() {
            let raiz = raices[i]
            let raizReal = Rutas.real(URL(fileURLWithPath: raiz))
            var lote = Lote(raiz: raiz, raizReal: raizReal, temporal: temporal)
            var nombres: [Set<String>] = []
            var archivos = 0
            var bytes: Int64 = 0
            var lista = porRaiz[i, default: []].sorted(by: { $0.ruta < $1.ruta })
            if primeroSolo, let k = lista.indices.min(by: { lista[$0].estado.tamano < lista[$1].estado.tamano }) {
                lotes.append(Lote(raiz: raiz, raizReal: raizReal, temporal: temporal, casillas: [[lista.remove(at: k)]]))
            }
            for cand in lista {
                if archivos > 0 && (archivos >= archivosPorLote || bytes + cand.estado.tamano > bytesPorLote) {
                    lotes.append(lote)
                    lote = Lote(raiz: raiz, raizReal: raizReal, temporal: temporal)
                    nombres = []
                    archivos = 0
                    bytes = 0
                }
                // El disco (APFS) no distingue mayúsculas ni las formas de escribir una tilde: «Foo.txt» y «foo.txt» serían
                // el mismo archivo en la carpeta temporal y ditto dejaría uno solo para los dos. Se comparan así.
                let nombre = Self.claveDeNombre(Rutas.nombre(cand.ruta))
                if let k = nombres.firstIndex(where: { !$0.contains(nombre) }) {
                    nombres[k].insert(nombre)
                    lote.casillas[k].append(cand)
                } else {
                    nombres.append([nombre])
                    lote.casillas.append([cand])
                }
                archivos += 1
                bytes += cand.estado.tamano
            }
            if archivos > 0 { lotes.append(lote) }
        }
        return lotes
    }

    /// Un nombre como lo compara el disco: sin distinguir mayúsculas ni las formas de escribir una letra con tilde (si
    /// junta dos nombres que el disco distingue, solo cuesta una casilla más; al revés, se pisarían dos archivos).
    static func claveDeNombre(_ nombre: String) -> String {
        nombre.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// Comprime (o descomprime, según `sentido`) un lote. Con `anotar`, apunta en `r.archivos` cada archivo cambiado.
    /// Devuelve false solo si una prueba pidió abortar (simula que la app se cerró de golpe).
    private static func procesar(_ lote: Lote, sentido: Sentido = .comprimir, anotar: Bool = false, _ r: inout Resultado,
                                 simular: Simulacion?) -> Bool {
        let nombreTemporal = prefijoTemporal + UUID().uuidString
        let temporal = lote.temporal + "/" + nombreTemporal
        let temporalReal = lote.temporalReal + "/" + nombreTemporal
        var carpetas = FechasDeCarpetas()
        carpetas.anotar(lote.raiz)
        guard mkdir(temporal, 0o700) == 0 else {
            r.fallos.append("No pude crear una carpeta temporal en \(Formato.rutaCorta(lote.temporal)) (\(String(cString: strerror(errno)))).")
            return true
        }
        // Qué copia es de qué archivo y qué permisos tenía: si la app se cerrara a mitad, sirve para comprobar las copias
        // que queden y para devolverle los suyos a una que ya estuviera en su sitio (ver `recogerRestos`).
        var manifiesto = ""
        for (k, casilla) in lote.casillas.enumerated() {
            for cand in casilla { manifiesto += Self.lineaDeManifiesto("\(k)/\(Rutas.nombre(cand.ruta))", cand.estado.modo, cand.ruta) }
        }
        guard FileManager.default.createFile(atPath: temporal + "/lote.txt", contents: Data(manifiesto.utf8)) else {
            rmdir(temporal)
            r.fallos.append("No pude preparar la carpeta temporal en \(Formato.rutaCorta(lote.temporal)).")
            return true
        }

        // 1. Copias comprimidas (o, al deshacerlo, sin comprimir).
        let opcion = sentido == .comprimir ? "--hfsCompression" : "--nopreserveHFSCompression"
        var copias: [(cand: Candidato, copia: String)] = []
        for (k, casilla) in lote.casillas.enumerated() {
            let carpeta = temporal + "/\(k)"
            guard mkdir(carpeta, 0o700) == 0 else { continue }
            let destino = casilla.count == 1 ? [carpeta + "/" + Rutas.nombre(casilla[0].ruta)] : [carpeta]
            Shell.ejecutar("/usr/bin/ditto", ["--noclone", opcion] + casilla.map(\.ruta) + destino,
                           limite: 3600, prioridad: .utility)
            for cand in casilla {
                let copia = carpeta + "/" + Rutas.nombre(cand.ruta)
                switch simular?(.copiado, cand.ruta) ?? .seguir {
                case .abortar: return false
                case .fallar: unlink(copia)
                case .seguir: break
                }
                copias.append((cand, copia))
            }
        }

        // Por si acaso: dos copias que son el mismo archivo (dos nombres que el disco toma por el mismo) no valen para
        // ninguno de los dos originales. Se dejan los dos como estaban.
        var porInodo: [UInt64: Int] = [:]
        for (_, copia) in copias {
            if let e = EstadoArchivo(ruta: copia) { porInodo[e.inodo, default: 0] += 1 }
        }
        let cruzadas = Set(porInodo.filter { $0.value > 1 }.keys)
        if !cruzadas.isEmpty {
            var sobran: [String] = []
            copias.removeAll { x in
                guard let e = EstadoArchivo(ruta: x.copia), cruzadas.contains(e.inodo) else { return false }
                r.fallos.append("\(Formato.rutaCorta(x.cand.ruta)): otro archivo con un nombre casi igual (solo cambian mayúsculas o tildes) se cruzó con él al copiarlo; lo dejé como estaba.")
                sobran.append(x.copia)
                return true
            }
            // La copia que compartían no sirve para ninguno: se borra (los originales siguen en su sitio, sin tocar).
            for copia in sobran { unlink(copia) }
        }

        // 2. Comprobar cada copia.
        var listas: [(cand: Candidato, copia: String, estado: EstadoArchivo)] = []
        for (cand, copia) in copias {
            switch comprobar(cand, copia, sentido: sentido) {
            case .cambio:
                r.cambiaron += 1
                unlink(copia)
            case .bien(let estado):
                switch simular?(.verificado, cand.ruta) ?? .seguir {
                case .abortar: return false
                case .fallar: unlink(copia)
                case .seguir: listas.append((cand, copia, estado))
                }
            case .noComprime:
                r.noSeDejaron += 1
                unlink(copia)
            case .distinta(let motivo):
                r.fallos.append("\(Formato.rutaCorta(cand.ruta)): \(motivo); lo dejé como estaba.")
                unlink(copia)
            }
        }

        // 3. Cambiar cada original por su copia, si nadie lo tiene abierto ni lo cambió.
        let antes = ArchivosAbiertos.ahora()
        if !antes.leidos && !listas.isEmpty {
            r.fallos.append("No pude ver qué archivos estaban abiertos; dejé \(listas.count) como estaban.")
            for x in listas { unlink(x.copia) }
            listas = []
        }
        var cambiados: [(cand: Candidato, copia: String, estado: EstadoArchivo)] = []
        var devueltas: [Devuelta] = []
        for x in listas {
            // macOS no deja cambiar archivos de esta app (falta «Gestión de apps»): lo que queda del lote, como estaba.
            if r.sinPermiso {
                unlink(x.copia)
                continue
            }
            if antes.hayAbierto(rutaReal: x.cand.rutaReal) != nil {
                r.abiertos += 1
                unlink(x.copia)
                continue
            }
            guard let ahora = EstadoArchivo(ruta: x.cand.ruta), ahora.sinCambios(desde: x.cand.estado) else {
                r.cambiaron += 1
                unlink(x.copia)
                continue
            }
            carpetas.anotar(Rutas.padre(x.cand.ruta))
            // Mientras el intercambio se pueda deshacer, la copia no se deja escribir: lo que alguien escribiera en ella
            // justo antes de devolver el original se quedaría fuera de tu archivo (un programa que añade una línea recibe
            // un error durante unos milisegundos). Recupera sus permisos al terminar (`ponerPermisos`).
            guard Self.quitarEscritura(x.copia, x.estado.modo) else {
                r.fallos.append("\(Formato.rutaCorta(x.cand.ruta)): no pude preparar su copia (\(String(cString: strerror(errno)))); lo dejé como estaba.")
                unlink(x.copia)
                continue
            }
            switch simular?(.antesDeCambiar, x.cand.ruta) ?? .seguir {
            case .abortar: return false
            case .fallar:
                unlink(x.copia)
                continue
            case .seguir: break
            }
            guard renamex_np(x.copia, x.cand.ruta, UInt32(RENAME_SWAP)) == 0 else {
                let codigo = errno
                unlink(x.copia)
                // Dentro de una app, EPERM o EACCES es el permiso «Gestión de apps» (macOS 13 y siguientes): se para aquí.
                if lote.temporal != lote.raiz && (codigo == EPERM || codigo == EACCES) {
                    r.sinPermiso = true
                    continue
                }
                r.fallos.append("\(Formato.rutaCorta(x.cand.ruta)): no pude cambiarlo por la copia (\(String(cString: strerror(codigo)))); lo dejé como estaba.")
                continue
            }
            // Ahora el original está en `x.copia` y la copia comprimida, en su sitio.
            var deshacer = false
            switch simular?(.cambiado, x.cand.ruta) ?? .seguir {
            case .abortar: return false
            case .fallar: deshacer = true
            case .seguir: break
            }
            // Si alguien escribió en el original justo durante el intercambio, la copia ya no vale.
            if deshacer || !(EstadoArchivo(ruta: x.copia)?.mismoContenido(que: x.cand.estado) ?? false) {
                if !deshacer { r.cambiaron += 1 }
                devolver(x, &r, &devueltas)
                continue
            }
            cambiados.append(x)
        }

        // 4. Volver a mirar lo abierto: quien abrió el original antes del intercambio lo sigue teniendo (en la carpeta
        //    temporal). Nadie más puede llegar a él: su nombre de siempre ya es la copia comprimida.
        let despues = ArchivosAbiertos.ahora()
        for x in cambiados {
            switch simular?(.antesDeBorrar, x.cand.ruta) ?? .seguir {
            case .abortar: return false
            case .fallar:
                devolver(x, &r, &devueltas)
                continue
            case .seguir: break
            }
            let enTemporal = temporalReal + x.copia.dropFirst(temporal.count)
            if !despues.leidos || despues.hayAbierto(rutaReal: enTemporal) != nil {
                r.abiertos += 1
                devolver(x, &r, &devueltas)
                continue
            }
            guard EstadoArchivo(ruta: x.copia)?.mismoContenido(que: x.cand.estado) ?? false else {
                r.cambiaron += 1
                devolver(x, &r, &devueltas)
                continue
            }
            guard unlink(x.copia) == 0 else {
                devolver(x, &r, &devueltas)
                continue
            }
            // Ya no hay vuelta atrás: la copia, en su sitio, recupera los permisos del original.
            if !Self.ponerPermisos(x.cand.ruta, inodo: x.estado.inodo, modo: x.cand.estado.modo) {
                r.fallos.append("\(Formato.rutaCorta(x.cand.ruta)): quedó comprimido, pero no pude devolverle sus permisos (\(String(x.cand.estado.modo & 0o7777, radix: 8))); pónselos desde la Terminal con «chmod \(String(x.cand.estado.modo & 0o7777, radix: 8))».")
            }
            let ocupa = EstadoArchivo(ruta: x.cand.ruta)?.ocupa ?? x.cand.estado.ocupa
            let ahorro = max(0, x.cand.estado.ocupa - ocupa)
            r.comprimidos += 1
            r.ahorro += ahorro
            r.aumento += max(0, ocupa - x.cand.estado.ocupa)
            if anotar { r.archivos.append(x.cand.ruta) }
            let suma = r.porRaiz[lote.raiz] ?? (0, 0)
            r.porRaiz[lote.raiz] = (suma.archivos + 1, suma.ahorro + ahorro)
        }

        // 5. Las copias comprimidas de lo que se devolvió a su sitio se borran si nadie las abrió entretanto (por su
        //    nombre de siempre, mientras estuvieron en su sitio) ni cambiaron; si no, se quedan y se avisa.
        if !devueltas.isEmpty {
            let fin = ArchivosAbiertos.ahora()
            for d in devueltas {
                let real = temporalReal + d.ruta.dropFirst(temporal.count)
                let ahora = EstadoArchivo(ruta: d.ruta)
                if let ahora, !ahora.mismoContenido(que: d.estado) {
                    // Alguien escribió en la copia mientras estuvo en su sitio: eso no está en tu archivo.
                    r.fallos.append(Self.escritoEnElResto(d.original, resto: d.ruta))
                } else if fin.leidos && fin.hayAbierto(rutaReal: real) == nil && ahora != nil {
                    unlink(d.ruta)
                }
            }
        }

        // 6. Quitar la carpeta temporal (sin borrar nada que no sea de este lote) y devolver sus fechas a las carpetas.
        //    Si queda algo (una versión que no se pudo devolver o una copia que alguien abrió), se queda con su
        //    manifiesto: la próxima vez se borra lo que esté repetido y lo demás se vuelve a avisar.
        let vacias = lote.casillas.indices.map { rmdir(temporal + "/\($0)") == 0 || errno == ENOENT }
        if vacias.allSatisfy({ $0 }) {
            unlink(temporal + "/lote.txt")
            rmdir(temporal)
        } else {
            r.fallos.append("Dejé algunos archivos en \(Formato.rutaCorta(temporal)) para no perder nada; la próxima vez que limpie borraré los que estén repetidos.")
        }
        carpetas.restaurar()
        return true
    }

    /// Deshace el intercambio: el original (que está en la carpeta temporal, en `x.copia`) vuelve a su sitio. Solo si en
    /// su sitio sigue la copia comprimida sin cambios: si un programa la reemplazó o escribió en ella, no se toca nada y
    /// se avisa (no se pierde ninguno de los dos). La copia, que queda en la carpeta temporal, se apunta en `devueltas`
    /// para borrarla al final del lote si nadie la abrió entretanto.
    private static func devolver(_ x: (cand: Candidato, copia: String, estado: EstadoArchivo), _ r: inout Resultado,
                                 _ devueltas: inout [Devuelta]) {
        guard let enSuSitio = EstadoArchivo(ruta: x.cand.ruta), enSuSitio.mismoContenido(que: x.estado),
              renamex_np(x.copia, x.cand.ruta, UInt32(RENAME_SWAP)) == 0 else {
            r.fallos.append("\(Formato.rutaCorta(x.cand.ruta)): cambió mientras lo comprimía; guardé la versión anterior en \(Formato.rutaCorta(x.copia)).")
            return
        }
        devueltas.append(Devuelta(ruta: x.copia, estado: x.estado, original: x.cand.ruta))
    }

    /// Lo que quedó en la carpeta temporal al deshacer un intercambio (la copia comprimida, o el clon al unir): se borra
    /// al final si nadie lo abrió ni lo cambió. `original` es la ruta de tu archivo.
    struct Devuelta {
        let ruta: String
        let estado: EstadoArchivo
        let original: String
    }

    /// El aviso de cuando alguien escribió en la copia (o el clon) justo mientras estuvo en el sitio de tu archivo y se
    /// devolvió el original: tu archivo tiene todo lo de antes, pero no eso, que se queda en la carpeta temporal.
    static func escritoEnElResto(_ original: String, resto: String) -> String {
        "\(Formato.rutaCorta(original)): recibió escrituras justo mientras lo cambiaba y lo dejé como estaba; lo que se escribió en ese momento quedó en \(Formato.rutaCorta(resto)). Revísalo: puede que a tu archivo le falte eso."
    }

    /// Quita a la copia (o al clon) los permisos de escritura antes del intercambio (ver `comprimir`, paso 3). Si ya no
    /// los tenía, no hace nada.
    static func quitarEscritura(_ ruta: String, _ modo: UInt16) -> Bool {
        let sinEscritura = modo & 0o7777 & ~0o222
        return sinEscritura == modo & 0o7777 || chmod(ruta, sinEscritura) == 0
    }

    /// Devuelve a lo que está en `ruta` los permisos `modo`, solo si sigue siendo ese archivo (`inodo`): se abre y se le
    /// cambian a lo abierto, así no se toca otro archivo que alguien acabe de poner en su sitio.
    static func ponerPermisos(_ ruta: String, inodo: UInt64, modo: UInt16) -> Bool {
        let fd = open(ruta, O_RDONLY | O_NOFOLLOW)
        if fd >= 0 {
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_ino == inodo else { return false }
            return st.st_mode & 0o7777 == modo & 0o7777 || fchmod(fd, modo & 0o7777) == 0
        }
        // Sin permiso de lectura no se puede abrir: se comprueba por la ruta.
        var st = stat()
        guard lstat(ruta, &st) == 0, st.st_ino == inodo, st.st_mode & S_IFMT == S_IFREG else { return false }
        return chmod(ruta, modo & 0o7777) == 0
    }

    private enum Comprobacion {
        case bien(EstadoArchivo)
        /// El original cambió o ya no está (alguien lo usó mientras tanto): se deja.
        case cambio
        /// ditto no la comprimió (no ganaba bastante) o no ocupa menos.
        case noComprime
        case distinta(String)
    }

    /// Comprueba la copia comprimida (o, al deshacerlo, la descomprimida) de un candidato y le pone sus fechas y atributos.
    private static func comprobar(_ cand: Candidato, _ copia: String, sentido: Sentido = .comprimir) -> Comprobacion {
        let o = cand.estado
        let comprimida = UInt32(UF_COMPRESSED)
        guard let ahora = EstadoArchivo(ruta: cand.ruta), ahora.sinCambios(desde: o) else { return .cambio }
        guard var n = EstadoArchivo(ruta: copia), n.esRegular else { return .distinta("ditto no pudo copiarlo") }
        switch sentido {
        case .comprimir: guard n.banderas & comprimida != 0, n.ocupa < o.ocupa else { return .noComprime }
        case .descomprimir: guard n.banderas & comprimida == 0 else { return .distinta("ditto no lo descomprimió") }
        }
        guard n.tamano == o.tamano else { return .distinta("la copia no mide lo mismo") }
        // La copia se crea con el grupo de la carpeta temporal (la de las apps está en tu carpeta, con «staff»; las apps
        // de /Applications suelen ser de «admin»): se le pone el del original, si eres de ese grupo.
        if n.grupo != o.grupo && n.dueno == o.dueno {
            guard lchown(copia, uid_t.max, o.grupo) == 0, let otra = EstadoArchivo(ruta: copia) else {
                return .distinta("no pude ponerle a la copia el mismo grupo")
            }
            n = otra
        }
        guard n.dueno == o.dueno, n.grupo == o.grupo else { return .distinta("la copia no tiene el mismo dueño") }
        guard mismoContenido(cand.ruta, copia, tamano: o.tamano) else {
            // Si el original cambió mientras se leía, no es que la copia esté mal.
            return EstadoArchivo(ruta: cand.ruta)?.sinCambios(desde: o) ?? false ? .distinta("la copia no es idéntica") : .cambio
        }
        // Después de leerla (leer cambia la fecha de acceso): permisos, atributos, ACL y fechas del original.
        if n.modo != o.modo { chmod(copia, o.modo & 0o7777) }
        guard igualarAtributos(de: cand.ruta, en: copia) else { return .distinta("no pude copiarle sus atributos extendidos") }
        guard igualarACL(de: cand.ruta, en: copia) else { return .distinta("no pude copiarle sus permisos (ACL)") }
        guard ponerFechas(copia, o) else { return .distinta("no pude ponerle sus fechas") }
        // Las mismas banderas que el original, salvo la de la compresión, que es la que cambia.
        let esperada = sentido == .comprimir ? comprimida : 0
        guard let f = EstadoArchivo(ruta: copia), f.banderas & comprimida == esperada,
              f.banderas & ~comprimida == o.banderas & ~comprimida, f.modo == o.modo, f.tamano == o.tamano,
              f.modificado == o.modificado, f.creado == o.creado else {
            return .distinta("la copia no quedó con los mismos permisos, banderas o fechas")
        }
        return .bien(f)
    }

    /// Los dos archivos tienen el mismo contenido, comparando bloques de 1 MiB (sin llenar la memoria caché).
    static func mismoContenido(_ a: String, _ b: String, tamano: Int64) -> Bool {
        let fa = open(a, O_RDONLY | O_NOFOLLOW)
        guard fa >= 0 else { return false }
        defer { close(fa) }
        let fb = open(b, O_RDONLY | O_NOFOLLOW)
        guard fb >= 0 else { return false }
        defer { close(fb) }
        _ = fcntl(fa, F_NOCACHE, 1)
        _ = fcntl(fb, F_NOCACHE, 1)
        let bloque = 1 << 20
        var ba = [UInt8](repeating: 0, count: bloque)
        var bb = [UInt8](repeating: 0, count: bloque)
        var total: Int64 = 0
        while true {
            let na = leerTodo(fa, &ba)
            let nb = leerTodo(fb, &bb)
            guard na >= 0, na == nb else { return false }
            if na == 0 { return total == tamano }
            guard memcmp(ba, bb, na) == 0 else { return false }
            total += Int64(na)
        }
    }

    /// Lee hasta llenar el búfer o llegar al final (read puede devolver menos). -1 si falla.
    private static func leerTodo(_ fd: Int32, _ buf: inout [UInt8]) -> Int {
        var hecho = 0
        let n = buf.count
        while hecho < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + hecho, n - hecho) }
            if r < 0 { if errno == EINTR { continue }; return -1 }
            if r == 0 { break }
            hecho += r
        }
        return hecho
    }

    /// Los atributos extendidos de un archivo (sin los de la compresión, que el sistema oculta).
    static func atributos(_ ruta: String) -> [String: [UInt8]]? {
        let largo = listxattr(ruta, nil, 0, XATTR_NOFOLLOW)
        guard largo >= 0 else { return nil }
        guard largo > 0 else { return [:] }
        var nombres = [CChar](repeating: 0, count: largo)
        guard listxattr(ruta, &nombres, largo, XATTR_NOFOLLOW) == largo else { return nil }
        var r: [String: [UInt8]] = [:]
        for parte in nombres.split(separator: 0) {
            let nombre = String(decoding: parte.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let tam = getxattr(ruta, nombre, nil, 0, 0, XATTR_NOFOLLOW)
            guard tam >= 0 else { return nil }
            var valor = [UInt8](repeating: 0, count: tam)
            guard tam == 0 || getxattr(ruta, nombre, &valor, tam, 0, XATTR_NOFOLLOW) == tam else { return nil }
            r[nombre] = valor
        }
        return r
    }

    /// Deja en la copia los mismos atributos extendidos que el original. ditto los copia, pero reescribe la cuarentena
    /// (com.apple.quarantine) con otra fecha y sin la app que lo descargó: se le pone la original. Los de la compresión
    /// y el «resource fork» no se tocan nunca; si el original tiene uno, no se comprime.
    ///
    /// La procedencia (com.apple.provenance) la pone el propio macOS a cada archivo nuevo con la del programa que lo crea, y
    /// nadie la puede cambiar ni quitar (setxattr y removexattr dicen que sí, pero no cambia nada): la copia queda con la
    /// de LimpiadorMac, como cualquier archivo que escribe un programa (una app que se actualiza sola, Homebrew…). No dice
    /// nada del contenido ni de la firma, así que no se compara; todos los demás atributos, sí.
    static func igualarAtributos(de origen: String, en copia: String) -> Bool {
        guard let todosA = atributos(origen), let todosB = atributos(copia) else { return false }
        let intocables: Set<String> = ["com.apple.decmpfs", "com.apple.ResourceFork"]
        guard todosA.keys.allSatisfy({ !intocables.contains($0) }) else { return false }
        let a = todosA.filter { !delSistema.contains($0.key) }
        var b = todosB.filter { !delSistema.contains($0.key) }
        if a == b { return true }
        for (nombre, valor) in a where b[nombre] != valor {
            guard setxattr(copia, nombre, valor, valor.count, 0, XATTR_NOFOLLOW) == 0 else { return false }
        }
        for nombre in b.keys where a[nombre] == nil && !intocables.contains(nombre) {
            guard removexattr(copia, nombre, XATTR_NOFOLLOW) == 0 else { return false }
        }
        b = (atributos(copia) ?? [:]).filter { !delSistema.contains($0.key) }
        return a == b
    }

    /// Atributos extendidos que gestiona el propio macOS y ningún programa puede poner ni quitar (ver `igualarAtributos`).
    static let delSistema: Set<String> = ["com.apple.provenance"]

    /// Deja en la copia la misma lista de control de acceso (ACL) que el original; si el original no tiene, se la quita
    /// (un clon trae la de su fuente).
    static func igualarACL(de origen: String, en copia: String) -> Bool {
        func texto(_ ruta: String) -> String? {
            guard let acl = acl_get_link_np(ruta, ACL_TYPE_EXTENDED) else { return "" }   // sin ACL
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard let t = acl_to_text(acl, nil) else { return nil }
            defer { acl_free(UnsafeMutableRawPointer(t)) }
            return String(cString: t)
        }
        guard let a = texto(origen) else { return false }
        if texto(copia) == a { return true }
        if a.isEmpty {
            // Una ACL vacía quita la que tenga.
            guard let vacia = acl_init(0) else { return false }
            defer { acl_free(UnsafeMutableRawPointer(vacia)) }
            guard acl_set_link_np(copia, ACL_TYPE_EXTENDED, vacia) == 0 else { return false }
            return texto(copia) == ""
        }
        guard let acl = acl_get_link_np(origen, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_link_np(copia, ACL_TYPE_EXTENDED, acl) == 0 else { return false }
        return texto(copia) == a
    }

    /// Pone a la copia las fechas de creación, modificación y acceso del original (ditto no conserva la de creación).
    static func ponerFechas(_ ruta: String, _ o: EstadoArchivo) -> Bool {
        var lista = attrlist()
        lista.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        lista.commonattr = attrgroup_t(UInt32(ATTR_CMN_CRTIME) | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_ACCTIME))
        // En el orden de los atributos: creación, modificación, acceso.
        var tiempos = [o.creado.ts, o.modificado.ts, o.accedido.ts]
        return tiempos.withUnsafeMutableBytes { setattrlist(ruta, &lista, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) } == 0
    }

    /// Si una compresión se cortó (la app se cerró de golpe, se colgó o se apagó el Mac), en la raíz queda su carpeta
    /// temporal con copias que sobran: el original de cada una sigue en su sitio (comprimido o no). Se borra cada copia
    /// cuyo original existe y tiene el mismo contenido; las demás se dejan donde están y se devuelven, para avisar. Nunca
    /// se borra una sin comprobarla. Y si se cortó con una copia ya en su sitio y sin permiso de escritura (paso 3), se le
    /// devuelven los permisos del original, apuntados en el manifiesto.
    static func recogerRestos(en raiz: String) -> [String] {
        var guardadas: [String] = []
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: raiz)) ?? [] where esCarpetaTemporal(n) {
            let carpeta = raiz + "/" + n
            var st = stat()
            guard lstat(carpeta, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { continue }
            let manifiesto = leerManifiesto(carpeta)
            for m in manifiesto.values { if let modo = m.modo { devolverEscritura(m.ruta, modo: modo) } }
            var quedan = 0
            for casilla in (try? fm.contentsOfDirectory(atPath: carpeta)) ?? [] where casilla != "lote.txt" {
                let dentro = carpeta + "/" + casilla
                for archivo in (try? fm.contentsOfDirectory(atPath: dentro)) ?? [] {
                    let copia = dentro + "/" + archivo
                    if let original = manifiesto[casilla + "/" + archivo]?.ruta, let e = EstadoArchivo(ruta: copia), e.esRegular,
                       let o = EstadoArchivo(ruta: original), o.inodo != e.inodo,
                       mismoContenido(original, copia, tamano: e.tamano) {
                        unlink(copia)
                    } else {
                        guardadas.append(copia)
                        quedan += 1
                    }
                }
                rmdir(dentro)
            }
            if quedan == 0 {
                unlink(carpeta + "/lote.txt")
                rmdir(carpeta)
            }
        }
        return guardadas
    }

    /// «.limpiador-<UUID>»: una carpeta temporal de una compresión.
    static func esCarpetaTemporal(_ nombre: String) -> Bool {
        nombre.hasPrefix(prefijoTemporal) && UUID(uuidString: String(nombre.dropFirst(prefijoTemporal.count))) != nil
    }

    /// Una carpeta de trabajo de LimpiadorMac, con lo que deja una compresión o una unión que se cortó: «.limpiador-<UUID>»
    /// (en la raíz que se comprime) o las de comprimir apps y unir copias (en Application Support/LimpiadorMac). No son
    /// archivos tuyos ni copias que unir: el índice no las ofrece y la próxima limpieza las recoge.
    static func esCarpetaDeTrabajo(nombre: String, ruta: String) -> Bool {
        if nombre.hasPrefix(prefijoTemporal) { return esCarpetaTemporal(nombre) }
        guard nombre == "comprimiendo" || nombre == "uniendo" else { return false }
        return ruta == temporalesDeApps || ruta == Clonador.carpetaTemporal
    }

    /// Hay alguna carpeta temporal de una compresión en esa raíz.
    static func tieneRestos(_ raiz: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: raiz)) ?? []).contains(where: esCarpetaTemporal)
    }

    // MARK: Restos de lo que se cortó

    /// Una línea del manifiesto de una carpeta temporal («lote.txt»): qué es cada archivo de dentro (`clave`), los permisos
    /// que tenía el archivo de tu carpeta y su ruta.
    static func lineaDeManifiesto(_ clave: String, _ modo: UInt16, _ ruta: String) -> String {
        "\(clave)\t\(String(modo & 0o7777, radix: 8))\t\(ruta)\n"
    }

    /// Lee el manifiesto de una carpeta temporal: por cada archivo de dentro, la ruta del tuyo y sus permisos. Los de antes
    /// no apuntaban los permisos («clave<tab>ruta»): entonces `modo` es nil.
    static func leerManifiesto(_ carpeta: String) -> [String: (ruta: String, modo: UInt16?)] {
        var r: [String: (ruta: String, modo: UInt16?)] = [:]
        guard let texto = try? String(contentsOfFile: carpeta + "/lote.txt", encoding: .utf8) else { return r }
        for linea in texto.split(separator: "\n") {
            let partes = linea.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard partes.count >= 2 else { continue }
            if partes.count == 3, (1...6).contains(partes[1].count), partes[1].allSatisfy({ ("0"..."7").contains($0) }),
               let modo = UInt16(partes[1], radix: 8), partes[2].hasPrefix("/") {
                r[partes[0]] = (partes[2], modo)
            } else {
                r[partes[0]] = (partes.dropFirst().joined(separator: "\t"), nil)
            }
        }
        return r
    }

    /// Si lo que hay en `ruta` es tuyo y tiene los permisos `modo` sin los de escritura (como lo deja el paso 3 mientras
    /// el intercambio se puede deshacer), se le devuelven. Si el original ya no se podía escribir, no hay nada que hacer.
    static func devolverEscritura(_ ruta: String, modo: UInt16) {
        let completo = modo & 0o7777
        guard completo & 0o222 != 0 else { return }
        var st = stat()
        guard lstat(ruta, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
              st.st_mode & 0o7777 == completo & ~0o222 else { return }
        _ = ponerPermisos(ruta, inodo: st.st_ino, modo: completo)
    }

    /// Dónde se apuntan las raíces en las que hay (o puede haber) carpetas temporales de una compresión: así la próxima
    /// limpieza recoge sus restos aunque la app se cerrara de golpe y ya no quede nada que comprimir allí.
    private static var registroDeRaices: String {
        Rutas.enHome("Library/Application Support/LimpiadorMac/comprimiendo-en.txt").path
    }

    static func raicesApuntadas() -> [String] {
        ((try? String(contentsOfFile: registroDeRaices, encoding: .utf8)) ?? "").split(separator: "\n")
            .map(String.init).filter { $0.hasPrefix("/") }
    }

    private static func guardarRaices(_ raices: [String]) {
        let ruta = registroDeRaices
        guard !raices.isEmpty else {
            unlink(ruta)
            return
        }
        try? FileManager.default.createDirectory(atPath: Rutas.padre(ruta), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data((raices.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: ruta), options: .atomic)
    }

    private static func apuntarRaices(_ raices: [String]) {
        guard !raices.isEmpty else { return }
        let ya = raicesApuntadas()
        let nuevas = raices.filter { !ya.contains($0) }
        if !nuevas.isEmpty { guardarRaices(ya + nuevas) }
    }

    private static func olvidarRaices(_ raices: [String]) {
        guard !raices.isEmpty else { return }
        let ya = raicesApuntadas()
        let quedan = ya.filter { !raices.contains($0) }
        if quedan != ya { guardarRaices(quedan) }
    }

    /// Recoge lo que dejaron las compresiones que se cortaron: en la carpeta de las apps, en las raíces apuntadas y en
    /// `ademas` (las de lo que se va a comprimir ahora). Las raíces que se quedan sin carpetas temporales dejan de estar
    /// apuntadas. Devuelve lo que se dejó porque no está repetido (para avisar).
    static func recogerTodosLosRestos(ademas: [String] = []) -> [String] {
        var guardadas = recogerRestos(en: temporalesDeApps)
        let apuntadas = raicesApuntadas()
        var vistas: Set<String> = [temporalesDeApps]
        for raiz in apuntadas + ademas where vistas.insert(raiz).inserted && Seguridad.sePuedeModificar(URL(fileURLWithPath: raiz)) {
            guardadas += recogerRestos(en: raiz)
        }
        olvidarRaices(apuntadas.filter { !tieneRestos($0) })
        return guardadas
    }

    /// Puede haber restos que recoger (una carpeta temporal de apps o raíces apuntadas): para decir qué se está haciendo.
    static var puedeHaberRestos: Bool {
        !raicesApuntadas().isEmpty || ((try? FileManager.default.contentsOfDirectory(atPath: temporalesDeApps)) ?? []).contains(where: esCarpetaTemporal)
    }
}

/// Las fechas de las carpetas que se tocan al comprimir o unir copias (crear la carpeta temporal, intercambiar archivos):
/// se les devuelven al terminar si su contenido sigue teniendo los mismos nombres. Así no parece un uso reciente para las
/// reglas que miran cuándo cambió una carpeta (las conversaciones antiguas, «usado hace poco»…).
struct FechasDeCarpetas {
    private var anotadas: [String: (acceso: timespec, modificacion: timespec, nombres: Set<String>)] = [:]

    mutating func anotar(_ ruta: String) {
        guard anotadas[ruta] == nil else { return }
        var st = stat()
        guard lstat(ruta, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              let nombres = try? FileManager.default.contentsOfDirectory(atPath: ruta) else { return }
        anotadas[ruta] = (st.st_atimespec, st.st_mtimespec, Set(nombres))
    }

    func restaurar() {
        for (ruta, a) in anotadas {
            guard let ahora = try? FileManager.default.contentsOfDirectory(atPath: ruta), Set(ahora) == a.nombres else { continue }
            var tiempos = [a.acceso, a.modificacion]
            _ = utimensat(AT_FDCWD, ruta, &tiempos, AT_SYMLINK_NOFOLLOW)
        }
    }
}
