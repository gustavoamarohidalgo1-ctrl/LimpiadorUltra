import AppKit
import Compression
import CoreServices
import CryptoKit
import Foundation
import Security

enum Shell {
    /// Ejecuta un programa y devuelve su salida estándar (stderr se descarta).
    /// Si tarda más de `limite` segundos, se detiene.
    /// `prioridad` baja (.utility) deja el disco y la CPU antes a lo que espera el usuario.
    @discardableResult
    static func ejecutar(_ programa: String, _ argumentos: [String], limite: TimeInterval = 120,
                         prioridad: QualityOfService = .default) -> (estado: Int32, salida: String) {
        final class Caja: @unchecked Sendable { var datos = Data() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: programa)
        p.arguments = argumentos
        p.qualityOfService = prioridad
        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let caja = Caja()
        let lectura = DispatchGroup()
        lectura.enter()
        DispatchQueue.global().async {
            caja.datos = tubo.fileHandleForReading.readDataToEndOfFile()
            lectura.leave()
        }
        do { try p.run() } catch {
            try? tubo.fileHandleForWriting.close()
            return (-1, "")
        }
        if lectura.wait(timeout: .now() + limite) == .timedOut {
            p.terminate()
            _ = lectura.wait(timeout: .now() + 1)
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: caja.datos, as: UTF8.self))
    }

    /// Ejecuta un comando que cambia cosas (brew cleanup, git gc…) y devuelve su salida estándar y de errores juntas,
    /// para el historial. Va en su propio grupo de procesos: si pasa de `limite` segundos se detiene él y todo lo que haya
    /// lanzado (git gc lanza pack-objects, que si no seguiría escribiendo), primero con SIGTERM y a los 5 s con SIGKILL.
    /// `entorno` se añade al de la app. `agotado` dice si se detuvo por tiempo. Estado -1 si no se pudo lanzar.
    static func comando(_ programa: String, _ argumentos: [String], entorno: [String: String] = [:],
                        limite: TimeInterval) -> (estado: Int32, salida: String, agotado: Bool) {
        var tubo: [Int32] = [0, 0]
        guard pipe(&tubo) == 0 else { return (-1, "", false) }
        let (lectura, escritura) = (tubo[0], tubo[1])
        var acciones: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&acciones)
        defer { posix_spawn_file_actions_destroy(&acciones) }
        posix_spawn_file_actions_addopen(&acciones, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&acciones, escritura, 1)
        posix_spawn_file_actions_adddup2(&acciones, escritura, 2)
        var atributos: posix_spawnattr_t?
        posix_spawnattr_init(&atributos)
        defer { posix_spawnattr_destroy(&atributos) }
        // Su propio grupo de procesos (para poder detenerlo entero), sin heredar otros descriptores de la app y con las
        // señales como de costumbre.
        posix_spawnattr_setflags(&atributos, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                                   | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&atributos, 0)
        var ninguna = sigset_t()
        sigemptyset(&ninguna)
        posix_spawnattr_setsigmask(&atributos, &ninguna)
        var todas = sigset_t()
        sigfillset(&todas)
        posix_spawnattr_setsigdefault(&atributos, &todas)

        var variables = ProcessInfo.processInfo.environment
        for (clave, valor) in entorno { variables[clave] = valor }
        let argv = ([programa] + argumentos).map { strdup($0) } + [nil]
        let envp = variables.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let lanzado = posix_spawn(&pid, programa, &acciones, &atributos, argv, envp)
        close(escritura)
        guard lanzado == 0 else {
            close(lectura)
            return (-1, "", false)
        }
        defer { close(lectura) }

        var salida = Data()
        var bufer = [UInt8](repeating: 0, count: 65_536)
        let inicio = Date()
        var finDeLectura = false
        var terminado = false
        var estado: Int32 = -1
        var agotado = false
        var matarEn: Date?
        var esperaFinal: Date?
        while true {
            if !finDeLectura {
                var p = pollfd(fd: lectura, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 200) > 0 {
                    let n = read(lectura, &bufer, bufer.count)
                    if n > 0 {
                        // Del historial basta el final: como mucho 1 MB.
                        if salida.count < 1_000_000 { salida.append(contentsOf: bufer[0..<n]) }
                    } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                        finDeLectura = true
                    }
                }
            } else {
                usleep(50_000)
            }
            if !terminado {
                var st: Int32 = 0
                let w = waitpid(pid, &st, WNOHANG)
                if w == pid {
                    terminado = true
                    // Terminó con exit(n) (n) o por una señal (128 + señal), como lo cuenta la terminal.
                    estado = st & 0x7f == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
                    esperaFinal = Date().addingTimeInterval(2)
                } else if w < 0 && errno != EINTR {
                    terminado = true
                    esperaFinal = Date()
                }
            }
            // Lo que lanzó y siga escribiendo en la salida no lo retiene más de 2 s.
            if terminado && (finDeLectura || Date() > esperaFinal!) { break }
            if !agotado && Date().timeIntervalSince(inicio) > limite {
                agotado = true
                kill(-pid, SIGTERM)
                matarEn = Date().addingTimeInterval(5)
            }
            if let m = matarEn, Date() > m {
                kill(-pid, SIGKILL)
                matarEn = nil
            }
        }
        // Si se detuvo por tiempo, que no quede nada suyo funcionando (lo que deja a medias se recoge después).
        if agotado {
            kill(-pid, SIGKILL)
            usleep(200_000)
        }
        return (estado, String(decoding: salida, as: UTF8.self), agotado)
    }
}

enum Tamanos {
    /// Espacio real ocupado en disco (usa `du`, que es mucho más rápido que recorrer en Swift).
    static func de(_ url: URL) -> Int64 {
        let r = Shell.ejecutar("/usr/bin/du", ["-sk", url.path])
        let ultima = r.salida.split(separator: "\n").last ?? ""
        let kb = Int64(ultima.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        return kb * 1024
    }

    /// Lo que ocupa una carpeta pequeña recorriéndola aquí mismo, contado como el índice (un archivo con varios
    /// enlaces, repartido entre ellos). Para las que el índice no registra por pequeñas (menos de 1 MB).
    static func recorriendo(_ ruta: String) -> Int64 {
        guard let rutaC = strdup(ruta) else { return 0 }
        defer { free(rutaC) }
        var argumentos: [UnsafeMutablePointer<CChar>?] = [rutaC, nil]
        guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        var total: Int64 = 0
        while let e = fts_read(fts) {
            let tipo = Int32(e.pointee.fts_info)
            guard tipo != FTS_DP && tipo != FTS_DNR && tipo != FTS_ERR && tipo != FTS_NS else { continue }
            let st = e.pointee.fts_statp.pointee
            let enlaces = tipo == FTS_F ? max(1, Int64(st.st_nlink)) : 1
            total += Int64(st.st_blocks) * 512 / enlaces
        }
        return total
    }

    /// Tamaño de cada hijo directo de una carpeta (archivos y carpetas).
    static func hijos(de url: URL) -> [(url: URL, tamano: Int64)] {
        let r = Shell.ejecutar("/usr/bin/du", ["-a", "-k", "-d", "1", url.path])
        var resultado: [(URL, Int64)] = []
        let base = url.standardizedFileURL.path
        for linea in r.salida.split(separator: "\n") {
            let partes = linea.split(separator: "\t", maxSplits: 1)
            guard partes.count == 2, let kb = Int64(partes[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let ruta = String(partes[1])
            if URL(fileURLWithPath: ruta).standardizedFileURL.path == base { continue }
            resultado.append((URL(fileURLWithPath: ruta), kb * 1024))
        }
        return resultado.sorted { $0.1 > $1.1 }
    }
}

/// Lo que se libera de verdad al borrar un archivo. En APFS dos archivos pueden compartir los mismos bloques
/// (clones: lo que hacen «Duplicar» del Finder, `cp -c` o algunas compilaciones), y borrar uno no libera nada
/// mientras quede el otro.
enum Privado {
    /// Solo se pregunta por archivos de 1 MiB o más al indexar: son unos pocos miles y tarda centésimas.
    /// Los pequeños se dan por privados.
    static let minimo: Int64 = 1_048_576

    struct Info {
        /// Bytes que usa solo este archivo: lo que se libera al borrarlo.
        let privado: Int64
        /// Identifica sus datos: los clones exactos de un archivo comparten el mismo.
        let clon: UInt64
        /// Cuántos archivos comparten esos datos (1 si no es un clon exacto; 0 si el sistema no lo dice).
        let copias: UInt32
    }

    /// nil si el sistema de archivos no lo sabe (HFS+, discos externos…): entonces se da todo por privado.
    /// No sigue enlaces. Un archivo comprimido por APFS (UF_COMPRESSED) guarda sus datos aparte y aquí da 0:
    /// quien llama lo da por privado.
    static func consultar(_ ruta: UnsafePointer<CChar>) -> Info? {
        var lista = attrlist()
        lista.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        lista.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        lista.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
        // largo (4) + atributos devueltos (5 × 4) + tamaño privado (8) + id de los datos (8) + copias (4)
        var buf = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        let r = withUnsafeMutableBytes(of: &buf) { b in
            getattrlist(ruta, &lista, b.baseAddress, b.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
        }
        guard r == 0 else { return nil }
        return withUnsafeBytes(of: &buf) { b -> Info? in
            // Los atributos vienen en orden y solo los que el sistema devolvió.
            let devueltos = b.load(fromByteOffset: 20, as: UInt32.self)
            guard devueltos & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let privado = b.loadUnaligned(fromByteOffset: 24, as: Int64.self)
            var o = 32
            var clon: UInt64 = 0
            if devueltos & UInt32(ATTR_CMNEXT_CLONEID) != 0 {
                clon = b.loadUnaligned(fromByteOffset: o, as: UInt64.self)
                o += 8
            }
            let copias = devueltos & UInt32(ATTR_CMNEXT_CLONE_REFCNT) != 0 ? b.loadUnaligned(fromByteOffset: o, as: UInt32.self) : 0
            return Info(privado: max(0, privado), clon: clon, copias: copias)
        }
    }

    static func consultar(_ ruta: String) -> Info? {
        ruta.withCString { consultar($0) }
    }
}

/// Instantáneas locales de Time Machine: mientras existan, lo que se borra sigue ocupando hasta que caducan.
enum Instantaneas {
    /// Cuántas hay en el disco de arranque (`tmutil listlocalsnapshots /`, solo lectura); nil si tmutil no contestó.
    static func locales() -> Int? {
        let r = Shell.ejecutar("/usr/bin/tmutil", ["listlocalsnapshots", "/"], limite: 15)
        return r.estado == 0 ? contar(r.salida) : nil
    }

    /// Una instantánea por línea («com.apple.TimeMachine.2026-10-08-120000.local»), tras la cabecera «Snapshots for disk /:».
    static func contar(_ salida: String) -> Int {
        salida.split(separator: "\n").filter { linea in
            !linea.hasPrefix("Snapshots for") && !linea.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
    }

    /// Cuántas de esas son de Time Machine (las únicas que se ofrece adelgazar); nil si tmutil no contestó.
    static func deTimeMachine() -> Int? {
        let r = Shell.ejecutar("/usr/bin/tmutil", ["listlocalsnapshots", "/"], limite: 15)
        return r.estado == 0 ? contarDeTimeMachine(r.salida) : nil
    }

    static func contarDeTimeMachine(_ salida: String) -> Int {
        salida.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("com.apple.TimeMachine.") }.count
    }

    /// Pide a macOS que adelgace las instantáneas locales de Time Machine del disco de arranque hasta liberar `bytes`, con
    /// la máxima urgencia (4): `tmutil thinlocalsnapshots / <bytes> 4`. Solo toca las de Time Machine (las de otras
    /// apps, no) y las copias del disco de copias de seguridad siguen intactas. Devuelve si terminó bien y su salida.
    static func adelgazar(bytes: Int64) -> (bien: Bool, salida: String) {
        let r = Shell.comando("/usr/bin/tmutil", ["thinlocalsnapshots", "/", String(max(1, bytes)), "4"], limite: 300)
        return (r.estado == 0 && !r.agotado, r.salida.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Lo que ocupa el volumen de datos fuera de lo que indexa la app: apps, /Library, Homebrew, /private, los recursos
/// que descarga macOS… Sirve para saber cuánto del disco quedó sin revisar (sobre todo lo que macOS no deja leer sin
/// Acceso total al disco). Se mide con du al terminar el análisis, no durante: a la vez lo hacía 2 s más lento.
enum MedidaFuera {
    /// Carpetas del volumen de datos que no están en tu carpeta personal (las de /usr/share/firmlinks y /private).
    static let rutas = ["/Applications", "/Library", "/opt", "/usr/local", "/private", "/System/Library/AssetsV2",
                        "/System/Library/Assets", "/System/Library/PreinstalledAssets", "/System/Library/PreinstalledAssetsV2",
                        "/System/Library/Caches", "/System/Library/Speech", "/cores"]

    /// Lo que ocupa cada carpeta (unos 10 s en este Mac, sobre todo /Applications). nil si alguna medida falló.
    static func medir() -> [String: Int64]? {
        final class Caja: @unchecked Sendable { var bytes: [String: Int64] = [:]; var fallos = 0 }
        let caja = Caja()
        let candado = NSLock()
        let lista = rutas.filter { Rutas.existe($0) }
        DispatchQueue.concurrentPerform(iterations: lista.count) { i in
            // -x: sin pasar a otros volúmenes. du acaba con error si hay carpetas sin permiso, pero el total de lo
            // que pudo leer vale. Con prioridad baja, para no frenar lo que hace el usuario.
            let r = Shell.ejecutar("/usr/bin/du", ["-skx", lista[i]], limite: 180, prioridad: .utility)
            let ultima = r.salida.split(separator: "\n").last ?? ""
            let kb = Int64(ultima.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "")
            candado.lock()
            if let kb { caja.bytes[lista[i]] = kb * 1024 } else { caja.fallos += 1 }
            candado.unlock()
        }
        return caja.fallos == 0 ? caja.bytes : nil
    }
}

enum Fechas {
    static func modificacion(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Fecha de "último uso" según Spotlight, si la tiene.
    static func ultimoUsoSpotlight(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Último uso de un archivo: lo más reciente entre Spotlight y la fecha de modificación.
    static func ultimoUsoArchivo(_ url: URL) -> Date? {
        [ultimoUsoSpotlight(url), modificacion(url)].compactMap { $0 }.max()
    }

    /// Lo último que cambió (archivos y carpetas) dentro de esas rutas, en segundos desde 1970, recorriéndolas
    /// enteras (0 si no hay nada). Con `despuesDe`, para en cuanto encuentra algo más nuevo: basta para saber que
    /// algo cambió desde el análisis.
    static func ultimoCambio(_ rutas: [String], despuesDe limite: Int? = nil) -> Int {
        var mejor = 0
        for ruta in rutas {
            guard let rutaC = strdup(ruta) else { continue }
            defer { free(rutaC) }
            var argumentos: [UnsafeMutablePointer<CChar>?] = [rutaC, nil]
            guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { continue }
            defer { fts_close(fts) }
            while let e = fts_read(fts) {
                let tipo = Int32(e.pointee.fts_info)
                guard tipo == FTS_F || tipo == FTS_D else { continue }
                mejor = max(mejor, Int(e.pointee.fts_statp.pointee.st_mtimespec.tv_sec))
                if let limite, mejor > limite { return mejor }
            }
        }
        return mejor
    }

    /// Lo último que cambió dentro de una carpeta que no está en el índice (mira hasta `maximo` archivos).
    static func masRecienteDentro(_ url: URL, maximo: Int = 20_000) -> Date? {
        var mejor = modificacion(url)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return mejor }
        var vistos = 0
        for case let u as URL in e {
            vistos += 1
            if vistos > maximo { break }
            if let f = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, f > (mejor ?? .distantPast) {
                mejor = f
            }
        }
        return mejor
    }

    /// Cuándo llegó a este Mac (descarga, copia o instalación), según Spotlight.
    static func agregadoSpotlight(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
    }
}

enum Rutas {
    /// Solo en modo diagnóstico, LIMPIADOR_CASA analiza una carpeta de prueba en lugar de la tuya.
    static let home: URL = {
        if CommandLine.arguments.contains("--diagnostico"), let prueba = ProcessInfo.processInfo.environment["LIMPIADOR_CASA"] {
            return URL(fileURLWithPath: prueba, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    /// Se analiza una carpeta de prueba (LIMPIADOR_CASA): lo que se mide del disco de verdad no casa con ella.
    static let casaDePrueba = home.standardizedFileURL.path != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    static func enHome(_ rel: String) -> URL { home.appendingPathComponent(rel) }
    static func existe(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func existe(_ ruta: String) -> Bool { FileManager.default.fileExists(atPath: ruta) }

    static func esCarpeta(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    static func hijos(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []
    }

    static func padre(_ ruta: String) -> String { (ruta as NSString).deletingLastPathComponent }
    static func nombre(_ ruta: String) -> String { (ruta as NSString).lastPathComponent }

    /// La ruta sin enlaces. A diferencia de `resolvingSymlinksInPath`, conserva el «/private» de /private/var y /private/tmp.
    static func real(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        guard let r = realpath(p, nil) else { return url.standardizedFileURL.resolvingSymlinksInPath().path }
        defer { free(r) }
        return String(cString: r)
    }

    /// Solo en modo diagnóstico con una casa de prueba: una variable de entorno que sustituye una carpeta del sistema
    /// por otra de prueba (con su ruta real), para probar sin tocar las de verdad.
    private static func dePrueba(_ variable: String) -> String? {
        guard casaDePrueba, let valor = ProcessInfo.processInfo.environment[variable], let real = realpath(valor, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// La carpeta de temporales que comparten todos los programas (/tmp). En las pruebas, LIMPIADOR_TMP.
    static let tmp: String = dePrueba("LIMPIADOR_TMP") ?? "/private/tmp"

    /// Dónde puede estar Homebrew: /opt/homebrew (Apple Silicon) y /usr/local (Intel). En una casa de prueba, solo el
    /// Homebrew de prueba de LIMPIADOR_HOMEBREW (o ninguno): nunca el de verdad.
    static let homebrew: [String] = casaDePrueba ? dePrueba("LIMPIADOR_HOMEBREW").map { [$0] } ?? []
                                                 : ["/opt/homebrew", "/usr/local"]

    /// Lo tuyo en /tmp (lo que dejan programas y scripts), sin lo que usan la terminal y el sistema.
    static func tuyoEnTmp() -> [String] {
        let otros = ["tmux-", "com.apple.", "claude-", "launchd", "ssh-", "screen", "powerlog", ".", "vscode-"]
        return ((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []).sorted().compactMap { n in
            guard !otros.contains(where: { n.hasPrefix($0) }) else { return nil }
            let p = tmp + "/" + n
            var st = stat()
            guard lstat(p, &st) == 0, st.st_uid == getuid() else { return nil }
            let tipo = st.st_mode & S_IFMT
            return tipo == S_IFDIR || tipo == S_IFREG ? p : nil
        }
    }

    /// Las carpetas de trabajo de las sesiones de Claude Code en /tmp (claude-<tu uid>/<proyecto>/<sesión>) y lo que hay
    /// suelto en claude-<uid> (pruebas que dejó un agente): son tuyas, pero no se ofrecen con lo demás de /tmp, porque
    /// pueden tener resultados de un trabajo que quieras leer (ver `Escaner.sesionesDeAgentes`). Solo carpetas.
    static func sesionesDeAgentes() -> [String] {
        let raiz = tmp + "/claude-\(getuid())"
        func carpetasTuyas(_ ruta: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: ruta)) ?? []).sorted().compactMap { n in
                let p = ruta + "/" + n
                var st = stat()
                guard lstat(p, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFDIR else { return nil }
                return p
            }
        }
        var r: [String] = []
        for p in carpetasTuyas(raiz) {
            // «-Users-gustavo-Proyecto»: la carpeta de un proyecto, con una carpeta por sesión dentro.
            if nombre(p).hasPrefix("-") { r += carpetasTuyas(p) } else { r.append(p) }
        }
        // Nunca la que contiene la carpeta que se analiza (una casa de prueba): es la sesión que la está usando.
        let casa = real(home)
        return r.filter { p in casa != p && !casa.hasPrefix(p + "/") && !p.hasPrefix(casa + "/") }
    }

    /// Temporales (T) y cachés (C) que macOS guarda para este usuario en /var/folders, con su ruta real («/private/var/…»).
    /// En las pruebas, LIMPIADOR_TEMPORALES es una carpeta con T y C dentro.
    static let temporalesDelSistema: [String] = {
        if let prueba = dePrueba("LIMPIADOR_TEMPORALES") { return [prueba + "/T", prueba + "/C"] }
        return [_CS_DARWIN_USER_TEMP_DIR, _CS_DARWIN_USER_CACHE_DIR].compactMap { clave in
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard confstr(clave, &buf, buf.count) > 0, let real = realpath(buf, nil) else { return nil }
            defer { free(real) }
            let ruta = String(cString: real)
            return ruta.hasPrefix("/private/var/folders/") ? ruta : nil
        }
    }()
}

/// Reglas que impiden borrar cosas importantes pase lo que pase.
enum Seguridad {
    private static let protegidas: Set<String> = {
        let h = Rutas.home.path
        let rel = ["", "Library", "Library/Caches", "Library/Application Support", "Library/Preferences",
                   "Library/Logs", "Library/Containers", "Library/Group Containers", "Library/Keychains",
                   "Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/CloudStorage",
                   "Library/LaunchAgents", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
                   "Public", "Applications", ".Trash", ".ssh", ".gnupg", ".config", ".local", ".cache", ".npm",
                   ".gradle", ".android", ".android/avd"]
        return Set(rel.map { $0.isEmpty ? h : h + "/" + $0 })
    }()

    static func sePuedeBorrar(_ url: URL) -> Bool {
        let p = Rutas.real(url)
        let h = Rutas.real(Rutas.home)
        let enTemporales = Rutas.temporalesDelSistema.contains { p.hasPrefix($0 + "/") } || (p.hasPrefix("/private/tmp/") && esTuyo(p))
        guard p.hasPrefix(h + "/") || p.hasPrefix("/Users/Shared/") || enTemporales || esAppBorrable(p) else { return false }
        if protegidas.contains(p) { return false }
        if p.contains("/Library/Keychains") || p.contains("/.ssh/") || p.hasSuffix("/.git") { return false }
        // Nunca se borra una llave de firma suelta, aunque alguien la seleccione.
        let ext = url.pathExtension.lowercased()
        if ext == "jks" || ext == "keystore" { return false }
        return true
    }

    /// Lo que se puede cambiar sin borrarlo (comprimirlo): solo lo que está dentro de tu carpeta personal, y nunca tus
    /// llaveros, correo, mensajes, fotos, lo que sincronizan iCloud u otras nubes, los datos de las apps aisladas
    /// (Containers) ni las carpetas de llaves (.ssh, .gnupg). Nada de /System, /Library, /usr ni de otros usuarios.
    /// Con `apps` (comprimir una app instalada, E11), también lo que está dentro de una app propia (`appPropia`).
    static func sePuedeModificar(_ url: URL, apps: Bool = false) -> Bool {
        let p = Rutas.real(url)
        let h = Rutas.real(Rutas.home)
        if apps, let app = appPropia(p) { return p == app || p.hasPrefix(app + "/") }
        guard p.hasPrefix(h + "/") else { return false }
        let dentro = String(p.dropFirst(h.count)) + "/"
        let prohibidas = ["/Library/Keychains/", "/Library/Mail/", "/Library/Messages/", "/Library/Mobile Documents/",
                          "/Library/CloudStorage/", "/Library/Photos/", "/Library/Containers/", "/Library/Group Containers/",
                          "/Pictures/", "/.Trash/", "/.ssh/", "/.gnupg/"]
        return !prohibidas.contains { dentro.hasPrefix($0) } && !dentro.contains(".photoslibrary/") && !dentro.contains("/.ssh/")
    }

    /// Las carpetas de apps instaladas que se pueden comprimir: /Applications y ~/Applications (y una carpeta dentro,
    /// como /Applications/Utilidades). En las pruebas (casa de prueba), solo la ~/Applications de la casa.
    static var carpetasDeApps: [String] {
        let propias = Rutas.real(Rutas.enHome("Applications"))
        return Rutas.casaDePrueba ? [propias] : ["/Applications", propias]
    }

    /// La app propia (su .app, con la ruta real) que contiene la ruta `p` (ya real), si la hay: una app de
    /// `carpetasDeApps` (o de una carpeta dentro) que es tuya (su dueño eres tú), tiene identificador y no es de Apple, no
    /// viene de la App Store (sin Contents/_MASReceipt: la tienda comprueba sus archivos) y no es LimpiadorMac. Las de
    /// otro dueño (root: Office, zoom) necesitan la contraseña de administrador y no se tocan.
    static func appPropia(_ p: String) -> String? {
        for carpeta in carpetasDeApps where p.hasPrefix(carpeta + "/") {
            let partes = p.dropFirst(carpeta.count + 1).split(separator: "/", omittingEmptySubsequences: false)
            // La primera .app de la ruta, en el primer o el segundo nivel.
            guard let i = partes.prefix(2).firstIndex(where: { $0.hasSuffix(".app") }) else { continue }
            let app = carpeta + "/" + partes[...i].joined(separator: "/")
            var st = stat()
            guard lstat(app, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(),
                  let id = Bundle(path: app)?.bundleIdentifier?.lowercased(), !id.hasPrefix("com.apple."),
                  id != "com.gustavo.limpiadormac", !Rutas.existe(app + "/Contents/_MASReceipt") else { return nil }
            return app
        }
        return nil
    }

    /// En /tmp hay cosas de otros usuarios y del sistema: solo se toca lo que es tuyo.
    private static func esTuyo(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && st.st_uid == getuid()
    }

    /// Una app de Aplicaciones (o de una carpeta dentro) que no es de Apple, o un instalador de macOS.
    private static func esAppBorrable(_ p: String) -> Bool {
        guard p.hasSuffix(".app") else { return false }
        let padre = Rutas.padre(p)
        guard padre == "/Applications" || Rutas.padre(padre) == "/Applications" else { return false }
        guard let id = Bundle(path: p)?.bundleIdentifier?.lowercased() else { return false }
        return !id.hasPrefix("com.apple.") || id.hasPrefix("com.apple.installassistant")
    }

    /// Comprueba si la app tiene Acceso total al disco (necesario para leer la Papelera y algunas carpetas).
    static func tieneAccesoTotal() -> Bool {
        let prueba = Rutas.enHome("Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: prueba.path)) != nil
    }
}

/// Lo que está instalado en este Mac, para saber qué carpetas son restos y a quién pertenece cada cosa.
struct AppsInstaladas {
    private(set) var bundleIDs: Set<String> = []
    private(set) var fabricantes: Set<String> = []   // "com.google", "us.zoom"…
    private(set) var nombres: Set<String> = []        // coincidencia flexible
    private(set) var nombresExactos: Set<String> = [] // procesos del sistema, comandos
    private(set) var comandos: Set<String> = []
    /// Apps en /Applications (para saber si una copia suelta sobra).
    private(set) var idsEnAplicaciones: Set<String> = []
    /// Dónde está cada una de esas apps, por su identificador en minúsculas: para comparar su versión con la de la copia.
    private(set) var rutasEnAplicaciones: [String: [String]] = [:]
    /// Códigos de desarrollador (Team ID) y carpetas compartidas («group.…») de las apps instaladas,
    /// leídos de su firma: así «UBF8T346G9.Office» se reconoce como de Microsoft Office.
    private let firmas = Firmas()

    /// Leer todas las firmas tarda segundos: solo se leen si aparece una carpeta que las necesita, y en paralelo.
    final class Firmas: @unchecked Sendable {
        fileprivate var apps: [URL] = []
        private var leidas: (equipos: Set<String>, grupos: Set<String>)?
        private let candado = NSLock()

        var datos: (equipos: Set<String>, grupos: Set<String>) {
            candado.lock()
            defer { candado.unlock() }
            if let leidas { return leidas }
            var equipos = Set<String>()
            var grupos = Set<String>()
            let lista = apps
            let juntar = NSLock()
            DispatchQueue.concurrentPerform(iterations: lista.count) { i in
                let (equipo, suyos) = Self.leer(lista[i])
                juntar.lock()
                if let equipo { equipos.insert(equipo) }
                grupos.formUnion(suyos)
                juntar.unlock()
            }
            leidas = (equipos, grupos)
            return (equipos, grupos)
        }

        private static func leer(_ url: URL) -> (String?, [String]) {
            var codigo: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &codigo) == errSecSuccess, let codigo else { return (nil, []) }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(codigo, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let d = info as? [String: Any] else { return (nil, []) }
            let equipo = (d[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() }
            let grupos = ((d[kSecCodeInfoEntitlementsDict as String] as? [String: Any])?["com.apple.security.application-groups"] as? [String]) ?? []
            return (equipo, grupos.map { $0.lowercased() })
        }
    }
    private var nombrePorID: [String: String] = [:]
    private var nombrePorNombre: [String: String] = [:]
    /// Programas de tu carpeta personal que abre algún comando de la terminal: ruta real → comando.
    private var puntosDeEntrada: [String: String] = [:]
    /// Carpetas del PATH de tu terminal que están dentro de tu carpeta personal (~/.local/bin, ~/.grok/bin…).
    private(set) var pathEnCasa: [String] = []
    /// El PATH de tu terminal entero y en orden: al escribir un comando, la terminal usa el primero que encuentra.
    private(set) var pathTerminal: [String] = []

    static func normalizar(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func cargar(appsExtra: [String] = []) -> AppsInstaladas {
        var r = AppsInstaladas()
        let fm = FileManager.default
        let carpetas = ["/Applications", "/System/Applications", Rutas.enHome("Applications").path,
                        "/System/Library/CoreServices", "/Applications/Xcode.app/Contents/Applications",
                        "/Applications/Xcode.app/Contents/Developer/Applications", "/Library/Application Support"]
        for carpeta in carpetas {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: carpeta), includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                r.agregarApp(url, enAplicaciones: carpeta == "/Applications")
            }
        }
        // Apps que viven fuera de Aplicaciones (en el Escritorio, en Descargas…) también cuentan.
        for ruta in appsExtra { r.agregarApp(URL(fileURLWithPath: ruta), enAplicaciones: false) }

        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { r.agregarBundleID(id, nombre: app.localizedName) }
            if let n = app.localizedName { r.agregarNombre(n) }
        }
        // Procesos y componentes del sistema: sus carpetas nunca son «restos».
        for dir in ["/usr/libexec", "/usr/sbin", "/usr/bin", "/System/Library/PrivateFrameworks",
                    "/System/Library/Frameworks", "/System/Library/CoreServices"] {
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                r.nombresExactos.insert(normalizar((n as NSString).deletingPathExtension))
            }
        }
        // Homebrew: fórmulas (comandos) y casks (apps).
        for dir in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { r.agregarComando(n) }
        }
        for dir in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { r.agregarNombre(n); r.agregarComando(n) }
        }
        // Comandos instalados: el PATH real de la terminal más los sitios habituales.
        var rutasComandos = Set(["/opt/homebrew/bin", "/usr/local/bin", Rutas.enHome(".local/bin").path,
                                 Rutas.enHome(".npm-global/bin").path, Rutas.enHome(".bun/bin").path,
                                 Rutas.enHome(".cargo/bin").path, "/opt/homebrew/lib/node_modules",
                                 "/usr/local/lib/node_modules", Rutas.enHome(".local/share/uv/tools").path,
                                 Rutas.enHome(".local/pipx/venvs").path])
        let path = pathDeLaTerminal()
        r.pathTerminal = path
        rutasComandos.formUnion(path)
        for version in (try? fm.contentsOfDirectory(atPath: Rutas.enHome(".nvm/versions/node").path)) ?? [] {
            rutasComandos.insert(Rutas.enHome(".nvm/versions/node/\(version)/bin").path)
        }
        let home = Rutas.home.path + "/"
        r.pathEnCasa = path.filter { Rutas.real(URL(fileURLWithPath: $0)).hasPrefix(home) }
        for dir in rutasComandos {
            let enCasa = Rutas.real(URL(fileURLWithPath: dir)).hasPrefix(home)
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                r.agregarComando(n)
                // A dónde lleva cada comando, si es a algo de tu carpeta (~/.codex/packages/…, ~/.opencode/bin/…).
                let ruta = dir + "/" + n
                var st = stat()
                guard enCasa || (lstat(ruta, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK) else { continue }
                let real = Rutas.real(URL(fileURLWithPath: ruta))
                if real.hasPrefix(home) { r.puntosDeEntrada[real] = n }
            }
        }
        return r
    }

    /// El comando de la terminal (codex, opencode…) cuyo programa vive dentro de esa carpeta, si hay alguno.
    func comandoDentro(de carpeta: String) -> String? {
        let base = Rutas.real(URL(fileURLWithPath: carpeta)) + "/"
        return puntosDeEntrada.first { $0.key.hasPrefix(base) }?.value
    }

    /// El PATH que ve tu terminal (incluye lo que agregan .zshrc y los instaladores).
    private static func pathDeLaTerminal() -> [String] {
        // En las pruebas (casa de prueba), el PATH de prueba.
        if Rutas.casaDePrueba, let path = ProcessInfo.processInfo.environment["LIMPIADOR_PATH"] {
            return path.split(separator: ":").map(String.init)
        }
        // Abierta desde la terminal (modo diagnóstico) ya tenemos su PATH. Y un zsh interactivo con terminal puede
        // quedarse esperando una respuesta de algo del .zshrc hasta agotar el tiempo.
        if isatty(STDIN_FILENO) != 0 || isatty(STDOUT_FILENO) != 0, let path = ProcessInfo.processInfo.environment["PATH"] {
            return path.split(separator: ":").map(String.init)
        }
        let salida = Shell.ejecutar("/bin/zsh", ["-lic", "print -r -- __PATH__$PATH"], limite: 4).salida
        guard let linea = salida.split(separator: "\n").last(where: { $0.hasPrefix("__PATH__") }) else { return [] }
        return linea.dropFirst(8).split(separator: ":").map(String.init)
    }

    private mutating func agregarApp(_ url: URL, enAplicaciones: Bool) {
        let visible = url.deletingPathExtension().lastPathComponent
        agregarNombre(visible)
        guard let b = Bundle(url: url) else { return }
        if let id = b.bundleIdentifier {
            agregarBundleID(id, nombre: visible)
            if enAplicaciones {
                idsEnAplicaciones.insert(id.lowercased())
                rutasEnAplicaciones[id.lowercased(), default: []].append(url.path)
            }
        }
        if !url.path.hasPrefix("/System/") { firmas.apps.append(url) }
        for clave in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            if let v = b.infoDictionary?[clave] as? String {
                let k = Self.normalizar(v)
                nombres.insert(k)
                if nombrePorNombre[k] == nil { nombrePorNombre[k] = visible }
            }
        }
    }

    /// «UBF8T346G9.Office» → «UBF8T346G9»: el código de 10 caracteres del desarrollador, si lo tiene.
    static func equipo(de carpeta: String) -> String? {
        guard let punto = carpeta.firstIndex(of: ".") else { return nil }
        let prefijo = carpeta[..<punto]
        guard prefijo.count == 10, prefijo.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              prefijo.contains(where: \.isNumber) else { return nil }
        return String(prefijo)
    }

    private mutating func agregarNombre(_ n: String) {
        let k = Self.normalizar(n)
        guard !k.isEmpty else { return }
        nombres.insert(k)
        if nombrePorNombre[k] == nil { nombrePorNombre[k] = n }
    }

    private mutating func agregarComando(_ n: String) {
        let k = Self.normalizar(n)
        guard !k.isEmpty else { return }
        comandos.insert(k)
        nombresExactos.insert(k)
    }

    private mutating func agregarBundleID(_ id: String, nombre: String?) {
        let l = id.lowercased()
        bundleIDs.insert(l)
        if let nombre, nombrePorID[l] == nil { nombrePorID[l] = nombre }
        // El «fabricante» (com.google.xxx -> google) también cuenta: muchas apps
        // guardan sus datos en una carpeta con el nombre de la empresa.
        let partes = l.split(separator: ".")
        if partes.count >= 2 {
            nombres.insert(Self.normalizar(String(partes[1])))
            fabricantes.insert(partes.prefix(2).joined(separator: "."))
        }
        if let ultima = partes.last { nombres.insert(Self.normalizar(String(ultima))) }
    }

    /// Carpetas de macOS o genéricas que nunca se consideran restos.
    private static let ignorar: Set<String> = [
        "addressbook", "animoji", "callhistorydb", "callhistorytransactions", "categories", "clouddocs",
        "crashreporter", "differentialprivacy", "diskimages", "facetime", "fileprovider", "intelligenceflow",
        "knowledge", "music", "sesstorage", "appsubscriptions", "defaultstore", "defaultstoreshm",
        "defaultstorewal", "mobilesync", "icloud", "dock", "syncservices", "cef", "electron", "caches",
        "askpermission", "homekit", "mail", "safari", "photos", "contacts", "calendars", "notes", "reminders",
        "stocks", "weather", "maps", "news", "tv", "podcasts", "books", "shortcuts", "siri", "voicememos",
        "com", "org", "net", "io", "app", "apps", "data", "storage", "backups", "temp", "tmp", "logs",
        "instruments", "xcode", "simulator", "coresimulator", "developer", "java", "python", "node",
        "accounts", "identityservices", "diagnosticreports", "avatarcacheindex", "mobilemeaccounts",
        "tokenbucketratelimiter", "contextstoreagent", "loginwindow", "pbs", "mbuseragent",
        "networkserviceproxy", "familycircle", "coreparsec", "keychains", "limpiadormac", "geoservices",
        "cloudkit", "passkit", "familycircled", "sharedfilelistd", "localizationswitcherd",
    ]

    /// Decide si una carpeta pertenece a algo que sigue instalado.
    func estaInstalado(carpeta: String) -> Bool {
        var l = carpeta.lowercased()
        if l.hasPrefix("com.apple.") || l.contains("group.com.apple.") || l.hasPrefix("apple") { return true }
        // Carpetas compartidas: «group.com.empresa.app» o «EQUIPO.algo». La firma de las apps dice de quién son.
        let equipo = Self.equipo(de: carpeta)
        if equipo != nil || l.hasPrefix("group.") {
            let f = firmas.datos
            // Si no se pudo leer ninguna firma, mejor no decidir: estas carpetas guardan licencias, sesiones y chats.
            if f.equipos.isEmpty && f.grupos.isEmpty { return true }
            if f.grupos.contains(Self.sinExtension(l)) { return true }
            if let equipo, f.equipos.contains(equipo) { return true }
        }
        if equipo != nil { l = String(l.dropFirst(11)) }
        if l.hasPrefix("group.") { l = String(l.dropFirst(6)) }
        let carpeta = l
        let n = Self.normalizar((carpeta as NSString).deletingPathExtension)
        if n.count < 3 || Self.ignorar.contains(n) || nombresExactos.contains(n) { return true }

        if l.contains(".") && l.split(separator: ".").count >= 3 {
            // Parece un identificador de app (com.empresa.app).
            let id = Self.sinExtension(l)
            if bundleIDs.contains(id) { return true }
            // Mismo fabricante que una app instalada (com.microsoft.office con Word instalado): se respeta.
            if fabricantes.contains(id.split(separator: ".").prefix(2).joined(separator: ".")) { return true }
            for b in bundleIDs where id.hasPrefix(b + ".") || b.hasPrefix(id + ".") { return true }
            let partes = id.split(separator: ".").map { Self.normalizar(String($0)) }
            // com.empresa.app: coincide si «app» es una app instalada.
            if let ultima = partes.last, ultima.count >= 4, nombres.contains(ultima) { return true }
            return false
        }

        for nombre in nombres where nombre.count >= 4 {
            if nombre == n { return true }
            // «BraveSoftware» empieza por «brave»; «AndroidStudio» contiene «android».
            if n.count >= 4 && (nombre.contains(n) || n.hasPrefix(nombre)) { return true }
        }
        return nombres.contains(n)
    }

    /// Nombre visible de la app a la que pertenece una carpeta («com.brave.Browser» → «Brave Browser»).
    func nombreApp(para carpeta: String) -> String? {
        let l = Self.sinExtension(carpeta.lowercased())
        if let n = nombrePorID[l] { return n }
        for (id, n) in nombrePorID where l.hasPrefix(id + ".") || id.hasPrefix(l + ".") { return n }
        let n = Self.normalizar(carpeta)
        if let v = nombrePorNombre[n] { return v }
        if n.count >= 4 {
            for (k, v) in nombrePorNombre where k.count >= 4 && (k.hasPrefix(n) || n.hasPrefix(k)) { return v }
        }
        return nil
    }

    /// ¿Existe un comando con un nombre parecido al de la carpeta oculta?
    func comandoPara(carpetaOculta: String) -> String? {
        let n = Self.normalizar(carpetaOculta)
        guard n.count >= 3 else { return nil }
        if comandos.contains(n) { return n }
        let base = Self.normalizar(String(carpetaOculta.dropFirst().split(separator: "-").first ?? ""))
        if base.count >= 3, comandos.contains(base) { return base }
        return nil
    }

    private static func sinExtension(_ s: String) -> String {
        for ext in [".plist", ".savedstate", ".binarycookies"] where s.hasSuffix(ext) { return String(s.dropLast(ext.count)) }
        return s
    }
}

/// Qué está funcionando ahora mismo: apps abiertas, programas, emuladores, Gradle y lo que tienen abierto.
struct Procesos {
    struct AppAbierta {
        let nombre: String
        let bundleID: String
        /// Una app normal, con ventanas y en el Dock (no un agente, un ayudante ni un servicio).
        var normal = true
        var pid: pid_t = 0
        /// Dónde está la app (para saber dentro de qué app va un ayudante).
        var url: URL? = nil
    }

    /// Un programa en marcha, con la ruta real de su ejecutable tal como la da el sistema (con sus espacios).
    struct Programa {
        let pid: pid_t
        let ruta: String
        /// Nombre del ejecutable, normalizado: «ChatGPT for Chrome» → «chatgptforchrome».
        let nombre: String
        /// Identificadores de las apps (.app) que lo contienen, en minúsculas.
        let ids: [String]
        /// Nombres normalizados de esas apps (el de la carpeta, CFBundleName y CFBundleExecutable).
        let nombresApp: Set<String>
        /// Para mostrar: la app que lo contiene («ChatGPT») o, si no sale de ninguna, el propio programa.
        let visible: String

        /// El programa de esa ruta, con las apps que lo contienen (`apps` guarda las ya leídas, para no repetirlas).
        init(pid: pid_t, ruta: String, apps: inout [String: InfoApp]) {
            var ids: [String] = []
            var nombresApp: Set<String> = []
            var visible = Rutas.nombre(ruta)
            for (i, app) in Procesos.appsQueContienen(ruta).enumerated() {
                let info = apps[app] ?? InfoApp(app)
                apps[app] = info
                if let id = info.id { ids.append(id) }
                nombresApp.formUnion(info.nombres)
                if i == 0 { visible = info.visible }   // la de fuera: «ChatGPT», no «Codex (Service)»
            }
            self.pid = pid
            self.ruta = ruta
            self.nombre = AppsInstaladas.normalizar(Rutas.nombre(ruta))
            self.ids = ids
            self.nombresApp = nombresApp
            self.visible = visible
        }
    }

    var apps: [AppAbierta] = []
    var programas: [Programa] = []
    /// Cada proceso (programa y argumentos), en minúsculas.
    var lineas: [String] = []
    /// El proceso de cada línea de `lineas` (mismo orden).
    var pidsDeLineas: [pid_t] = []
    /// `lineas` seguidas, cada una terminada en «\n» (en UTF-8), y dónde empieza cada una: buscar una ruta en todos los
    /// argumentos es una sola pasada por memoria, no una por línea (`mencionan`).
    private var todasLasLineas: [UInt8] = []
    private var inicios: [Int] = []
    var avds: Set<String> = []
    var simuladores: Set<String> = []
    /// Hay algún proceso de Gradle (un daemon o el wrapper descargando).
    var gradle = false
    /// Versiones de los daemons de Gradle en marcha («8.13»).
    var versionesGradle: Set<String> = []
    /// Hay algún proceso de Gradle cuya versión no se pudo leer: cuenta como si usara todas.
    var gradleSinVersion = false
    var abiertos = ArchivosAbiertos()
    /// Proyectos abiertos en un editor de JetBrains que está funcionando (Android Studio, IntelliJ…): ruta en
    /// minúsculas → nombre del editor.
    var proyectosEnEditores: [String: String] = [:]
    /// Editores abiertos cuya lista de proyectos no se pudo leer: cualquier proyecto puede estar abierto en ellos.
    var editoresSinLeer: [String] = []
    /// Se pudo saber qué está funcionando. Si ps o el sistema (libproc) fallan es false: entonces no se puede
    /// asegurar que algo no esté en uso, y nada que dependa de eso se marca solo ni se borra.
    var fiable = true
    /// Se pudo preguntar a Xcode qué simuladores están encendidos.
    var simuladoresConocidos = true

    static func capturar() -> Procesos {
        var p = Procesos()
        for a in NSWorkspace.shared.runningApplications {
            guard let n = a.localizedName else { continue }
            p.apps.append(AppAbierta(nombre: n, bundleID: a.bundleIdentifier?.lowercased() ?? "",
                                     normal: a.activationPolicy == .regular, pid: a.processIdentifier, url: a.bundleURL))
        }

        // El nombre de cada programa sale de la ruta real de su ejecutable (proc_pidpath), no de ps:
        // ps no distingue los espacios del nombre («…/ChatGPT for Chrome») de los de los argumentos.
        let uid = getuid()
        var deTuUsuario: [pid_t] = []
        var nombres: [pid_t: String] = [:]
        var infoApps: [String: InfoApp] = [:]
        var terminales = Set<pid_t>()
        let pids = Self.todosLosPids()
        for pid in pids {
            guard let ruta = Self.ejecutable(de: pid) else { continue }
            let programa = Programa(pid: pid, ruta: ruta, apps: &infoApps)
            p.programas.append(programa)
            nombres[pid] = programa.visible
            if ArchivosAbiertos.terminales.contains(Rutas.nombre(ruta)) { terminales.insert(pid) }
            var info = proc_bsdshortinfo()
            let tam = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, tam) == tam && info.pbsi_uid == uid {
                deTuUsuario.append(pid)
            }
        }
        // Lo que tienen abierto (solo se puede leer de los procesos de tu usuario, que son los que abren tus archivos).
        p.abiertos = ArchivosAbiertos.capturar(pids: deTuUsuario, nombres: nombres, terminales: terminales)
        // Si el sistema no da ni este mismo programa, la lista no sirve: no se sabe qué está en uso.
        if pids.isEmpty || !p.programas.contains(where: { $0.pid == getpid() }) || !p.abiertos.leidos { p.fiable = false }

        // Los argumentos (emulador, Gradle, rutas que se le pasan a un programa) siguen saliendo de ps.
        let ps = Shell.ejecutar("/bin/ps", ["-axww", "-o", "pid=,args="], limite: 10)
        if ps.estado != 0 || ps.salida.isEmpty { p.fiable = false }
        for linea in ps.salida.split(separator: "\n") {
            let recortada = linea.drop { $0 == " " }
            let pid = pid_t(recortada.prefix { $0.isNumber }) ?? 0
            let l = String(recortada.drop { $0.isNumber }.drop { $0 == " " })
            let minusculas = l.lowercased()
            p.lineas.append(minusculas)
            p.pidsDeLineas.append(pid)
            // Todas las líneas seguidas, para buscar rutas en los argumentos de una vez (`mencionan`).
            p.inicios.append(p.todasLasLineas.count)
            p.todasLasLineas.append(contentsOf: minusculas.utf8)
            p.todasLasLineas.append(10)   // «\n»
            if l.contains("qemu-system") || l.contains("/emulator ") {
                if let r = l.range(of: "-avd ") {
                    let resto = l[r.upperBound...]
                    if let nombre = resto.split(separator: " ").first { p.avds.insert(String(nombre)) }
                }
            }
            if l.contains("GradleDaemon") || l.contains("org.gradle.launcher.daemon") || l.contains("org.gradle.wrapper.GradleWrapperMain") {
                p.gradle = true
                if let v = Self.versionGradle(l) { p.versionesGradle.insert(v) } else { p.gradleSinVersion = true }
            }
        }

        let simctl = Shell.ejecutar("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"], limite: 15)
        if let d = simctl.salida.data(using: .utf8),
           let raiz = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let porRuntime = raiz["devices"] as? [String: [[String: Any]]] {
            for lista in porRuntime.values {
                for dispositivo in lista where (dispositivo["state"] as? String) == "Booted" {
                    if let udid = dispositivo["udid"] as? String { p.simuladores.insert(udid) }
                }
            }
        } else {
            p.simuladoresConocidos = false
        }
        (p.proyectosEnEditores, p.editoresSinLeer) = Self.proyectosEnEditores(p)
        return p
    }

    /// Los editores de JetBrains apuntan sus proyectos recientes en options/recentProjects.xml, con opened="true" los
    /// que tienen abiertos (o tenían al cerrarse, para volver a abrirlos al arrancar). Solo cuentan los del editor que
    /// está funcionando ahora: cerrado, no tiene nada abierto.
    private static func proyectosEnEditores(_ p: Procesos) -> (abiertos: [String: String], sinLeer: [String]) {
        let familias: [(claves: [String], carpeta: String, prefijo: String)] = [
            (["com.google.android.studio"], "Library/Application Support/Google", "AndroidStudio"),
            (["com.jetbrains"], "Library/Application Support/JetBrains", ""),
        ]
        var abiertos: [String: String] = [:]
        var sinLeer: [String] = []
        for f in familias {
            guard let editor = p.appAbierta(f.claves) else { continue }
            for version in Rutas.hijos(Rutas.enHome(f.carpeta)) where version.lastPathComponent.hasPrefix(f.prefijo) {
                let lista = version.appendingPathComponent("options/recentProjects.xml")
                guard Rutas.existe(lista) else { continue }
                guard let texto = try? String(contentsOf: lista, encoding: .utf8) else {
                    sinLeer.append(editor)
                    continue
                }
                for ruta in proyectosAbiertos(en: texto) { abiertos[ruta.lowercased()] = editor }
            }
        }
        return (abiertos, sinLeer)
    }

    private static let patronProyectoReciente = try! NSRegularExpression(
        pattern: #"<entry key="([^"]+)">\s*<value>\s*<RecentProjectMetaInfo([^>]*)>"#)

    /// Las rutas de los proyectos con opened="true" de un recentProjects.xml.
    static func proyectosAbiertos(en texto: String) -> [String] {
        let entidades = [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")]
        return patronProyectoReciente.matches(in: texto, range: NSRange(texto.startIndex..., in: texto)).compactMap { m in
            guard let clave = Range(m.range(at: 1), in: texto), let atributos = Range(m.range(at: 2), in: texto),
                  texto[atributos].contains(#"opened="true""#) else { return nil }
            var ruta = String(texto[clave]).replacingOccurrences(of: "$USER_HOME$", with: Rutas.home.path)
            for (entidad, letra) in entidades { ruta = ruta.replacingOccurrences(of: entidad, with: letra) }
            return ruta
        }
    }

    /// Los candados que el emulador deja en su carpeta (hardware-qemu.ini.lock…) guardan el número del proceso que lo
    /// tiene encendido. Devuelve ese número si el proceso sigue vivo; si se apagó de golpe, el candado se queda pero
    /// el proceso ya no existe.
    static func candadoVivo(en carpeta: String) -> pid_t? {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: carpeta)) ?? [] where n.hasSuffix(".lock") {
            let ruta = carpeta + "/" + n
            var texto = ""
            if let destino = try? fm.destinationOfSymbolicLink(atPath: ruta) {
                texto = destino   // algunas versiones lo guardan como enlace al número
            } else if Rutas.esCarpeta(URL(fileURLWithPath: ruta)) {
                texto = (try? String(contentsOfFile: ruta + "/pid", encoding: .utf8)) ?? ""
            } else if let datos = fm.contents(atPath: ruta) {
                texto = String(decoding: datos.prefix(64), as: UTF8.self)
            }
            let digitos = texto.drop { !$0.isNumber }.prefix { $0.isNumber }
            guard let pid = pid_t(digitos), pid > 0 else { continue }
            if kill(pid, 0) == 0 || errno == EPERM { return pid }
        }
        return nil
    }

    /// Una app (.app) que contiene programas en marcha: su identificador y sus nombres.
    struct InfoApp {
        let id: String?
        let nombres: Set<String>
        let visible: String

        init(_ ruta: String) {
            let b = Bundle(path: ruta)
            visible = (Rutas.nombre(ruta) as NSString).deletingPathExtension
            id = b?.bundleIdentifier?.lowercased()
            var n: Set<String> = [AppsInstaladas.normalizar(visible)]
            for clave in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                if let v = b?.infoDictionary?[clave] as? String { n.insert(AppsInstaladas.normalizar(v)) }
            }
            n.remove("")
            nombres = n
        }
    }

    static func todosLosPids() -> [pid_t] {
        let cuantos = proc_listallpids(nil, 0)
        guard cuantos > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(cuantos) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return n > 0 ? pids.prefix(Int(n)).filter { $0 > 0 } : []
    }

    /// Ruta real del ejecutable de un proceso. Si el programa se actualizó mientras funcionaba, su ejecutable ya no
    /// está en el disco y el sistema no la da: entonces vale la ruta con la que se lanzó.
    private static func ejecutable(de pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        return rutaDeArranque(de: pid)
    }

    /// La ruta con la que se lanzó un proceso de tu usuario (KERN_PROCARGS2: el número de argumentos y, detrás,
    /// esa ruta terminada en cero).
    private static func rutaDeArranque(de pid: pid_t) -> String? {
        var maximo: Int32 = 0
        var tam = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &maximo, &tam, nil, 0) == 0, maximo > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(maximo))
        tam = buf.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &tam, nil, 0) == 0, tam > MemoryLayout<Int32>.size else { return nil }
        let resto = buf[MemoryLayout<Int32>.size..<tam]
        let ruta = String(decoding: resto.prefix { $0 != 0 }, as: UTF8.self)
        return ruta.hasPrefix("/") ? ruta : nil
    }

    /// Las apps que contienen un ejecutable, de fuera a dentro:
    /// «/Applications/ChatGPT.app/…/Codex (Service).app/Contents/MacOS/…» → las dos .app.
    fileprivate static func appsQueContienen(_ ruta: String) -> [String] {
        var r: [String] = []
        var actual = ""
        for parte in ruta.split(separator: "/") {
            actual += "/" + parte
            if parte.hasSuffix(".app") { r.append(actual) }
        }
        return r
    }

    private static let patronesGradle = [#"GradleDaemon (\d[\w.\-]*)"#, #"gradle-daemon-main-(\d[\w.\-]*?)\.jar"#,
                                         #"/gradle-(\d[\w.\-]*?)-(?:bin|all)/"#, #"/caches/(\d[\w.\-]*?)/"#]
        .map { try! NSRegularExpression(pattern: $0) }

    /// La versión de Gradle de un proceso: el daemon la recibe como argumento («…GradleDaemon 8.13») y la
    /// lleva en las rutas de su distribución («gradle-8.13-bin», «gradle-daemon-main-8.13.jar»).
    static func versionGradle(_ linea: String) -> String? {
        let rango = NSRange(linea.startIndex..., in: linea)
        for patron in patronesGradle {
            if let m = patron.firstMatch(in: linea, range: rango), let r = Range(m.range(at: 1), in: linea) {
                return String(linea[r])
            }
        }
        return nil
    }

    func estaEnUso(_ u: EnUso) -> Bool { quienUsa(u) != nil }

    /// Quién usa algo ahora mismo (para explicarlo), o nil si nada lo usa.
    func quienUsa(_ u: EnUso) -> String? {
        switch u {
        case .app(_, let claves): return appAbierta(claves)
        case .emulador(let avd, let carpeta):
            if avds.contains(avd) { return u.descripcion }
            guard let carpeta else { return nil }
            // Un candado de un proceso vivo: encendido, salvo que ese número sea ya de otro programa.
            if let pid = Self.candadoVivo(en: carpeta) {
                let nombre = programas.first { $0.pid == pid }?.nombre
                if nombre.map({ $0.contains("qemu") || $0.contains("emulator") }) ?? true { return u.descripcion }
            }
            return abiertos.hayAbierto(dentroDe: carpeta)
        case .simulador(let udid):
            if simuladores.contains(udid) { return u.descripcion }
            // Si Xcode no contestó, no se sabe si está encendido: mejor no tocarlo.
            return simuladoresConocidos ? nil : u.descripcion
        case .gradle: return gradle ? "Gradle" : nil
        case .gradleVersion(let v):
            if versionesGradle.contains(v) { return "Gradle \(v)" }
            if gradleSinVersion { return "Gradle" }
            // Un programa (Android Studio, el daemon de Kotlin…) con archivos de esa versión abiertos.
            let suyas = [".gradle/caches/\(v)", ".gradle/wrapper/dists/gradle-\(v)-bin", ".gradle/wrapper/dists/gradle-\(v)-all"]
            return suyas.lazy.compactMap { abiertos.hayAbierto(dentroDe: Rutas.enHome($0).path) }.first
        case .proceso(let nombre, let patron): return lineas.contains { $0.contains(patron) } ? nombre : nil
        case .rutas(_, let raiz): return usando(raiz)
        case .programas(_, let ejecutables):
            let buscados = Set(ejecutables.map { $0.lowercased() })
            return programas.first { buscados.contains(Rutas.nombre($0.ruta).lowercased()) }?.visible
        case .proyecto(_, let raiz):
            // Una terminal o un agente de la terminal abiertos en la carpeta del proyecto no lo usan: lo que lancen sí
            // (es otro programa, con su carpeta y sus archivos). Si trabajan dentro de lo que se borra, lo ve la
            // comprobación de las rutas del elemento (`quienUsa(_ el:)`).
            if let quien = usando(raiz, terminales: false) { return quien }
            if let editor = editoresSinLeer.first { return editor }
            // Abierto en el editor: el mismo proyecto, uno que lo contiene o una parte de él (un módulo).
            let r = raiz.lowercased()
            return proyectosEnEditores.first { p, _ in r == p || r.hasPrefix(p + "/") || p.hasPrefix(r + "/") }?.value
        case .carpetaTemporal(_, let raiz):
            if let quien = usando(raiz) { return quien }
            // Un servidor o un script que guardó su número en un .pid y sigue vivo, aunque ahora no tenga nada abierto.
            guard let pid = Self.pidVivo(en: raiz) else { return nil }
            return programas.first { $0.pid == pid }?.visible ?? "Un programa (proceso \(pid))"
        case .appInstalada(_, let id, let ruta):
            // Abierta (ella o algo suyo con su identificador), algo que se ejecuta desde dentro o tiene algo suyo
            // abierto, o un actualizador trabajando (puede estar a punto de reemplazarla).
            if !id.isEmpty, let quien = appAbierta([id]) { return quien }
            if let quien = usando(ruta) { return quien }
            return actualizadorEnMarcha(id: id, ruta: ruta)
        }
    }

    /// Nombres (normalizados) de los programas con los que las apps se actualizan solas: Squirrel (ShipIt, de las apps
    /// de Electron), Sparkle (Autoupdate, Updater), Microsoft AutoUpdate y los de Google y Brave.
    static let actualizadores: Set<String> = ["shipit", "autoupdate", "updater", "microsoftautoupdate",
                                              "microsoftupdateassistant", "googleupdater", "googlesoftwareupdateagent",
                                              "ksinstall", "braveupdater", "bravesoftwareupdateagent"]

    /// Un actualizador que puede estar actualizando la app de identificador `id` que está en `ruta`, si hay alguno
    /// funcionando (por su nombre, por salir de Sparkle o de Squirrel, o el de los editores de JetBrains). Cuenta si dice
    /// en sus argumentos qué app actualiza y es esta (ShipIt recibe «<id>.ShipIt», Sparkle la ruta de la app), o si no dice
    /// ninguna (no se sabe cuál va a reemplazar). Los que nombran otra app no cuentan: el ShipIt de Claude que espera a
    /// que Claude se cierre no impide comprimir Android Studio. Los que se ejecutan desde dentro de la app ya los ve
    /// `usando`.
    func actualizadorEnMarcha(id: String, ruta: String) -> String? {
        let suyo = id.lowercased()
        let suRuta = ruta.lowercased()
        func esPara(_ argumentos: String) -> Bool {
            if (!suyo.isEmpty && argumentos.contains(suyo)) || (!suRuta.isEmpty && argumentos.contains(suRuta)) { return true }
            // Si nombra otra app (una .app o un «….shipit»), es para esa.
            return !argumentos.contains(".app") && !argumentos.contains(".shipit")
        }
        for p in programas where !p.ruta.hasPrefix("/System/") && !p.ruta.hasPrefix("/usr/") {
            guard Self.actualizadores.contains(p.nombre) || p.ruta.contains("/Sparkle.framework/")
                    || p.ruta.contains("/org.sparkle-project.Sparkle/") || p.ruta.contains("/Squirrel.framework/") else { continue }
            // Sus argumentos, sin la ruta del propio programa (que puede ser de otra .app).
            let linea = pidsDeLineas.firstIndex(of: p.pid).map { lineas[$0] } ?? ""
            let programa = p.ruta.lowercased()
            let argumentos = linea.hasPrefix(programa) ? String(linea.dropFirst(programa.count)) : linea
            if esPara(argumentos) { return "\(p.visible) (actualizando una app)" }
        }
        for (i, linea) in lineas.enumerated() where linea.contains("com.intellij.updater") {
            let argumentos = linea.components(separatedBy: "com.intellij.updater").dropFirst().joined()
            if esPara(argumentos) {
                return (i < pidsDeLineas.count ? programas.first { $0.pid == pidsDeLineas[i] }?.visible : nil) ?? "El actualizador de JetBrains"
            }
        }
        return nil
    }

    /// Si `ruta` (un archivo *.pid, o una carpeta con alguno dentro) guarda el número de un proceso que sigue vivo,
    /// ese número. Recorre como mucho `maximo` entradas: si hay más, lo que no se miró no cuenta.
    static func pidVivo(en ruta: String, maximo: Int = 20_000) -> pid_t? {
        var st = stat()
        guard lstat(ruta, &st) == 0 else { return nil }
        if (st.st_mode & S_IFMT) == S_IFREG { return ruta.hasSuffix(".pid") ? numeroVivo(enArchivo: ruta) : nil }
        guard (st.st_mode & S_IFMT) == S_IFDIR, let rutaC = strdup(ruta) else { return nil }
        defer { free(rutaC) }
        var argumentos: [UnsafeMutablePointer<CChar>?] = [rutaC, nil]
        guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }
        var vistos = 0
        while let e = fts_read(fts), vistos < maximo {
            vistos += 1
            guard Int32(e.pointee.fts_info) == FTS_F else { continue }
            let p = String(cString: e.pointee.fts_path)
            if p.hasSuffix(".pid"), let pid = numeroVivo(enArchivo: p) { return pid }
        }
        return nil
    }

    /// El número de proceso que guarda un archivo *.pid (las primeras cifras), si ese proceso sigue vivo.
    static func numeroVivo(enArchivo ruta: String) -> pid_t? {
        guard let datos = FileManager.default.contents(atPath: ruta) else { return nil }
        let texto = String(decoding: datos.prefix(64), as: UTF8.self)
        let digitos = texto.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard let pid = pid_t(digitos), pid > 0 else { return nil }
        return kill(pid, 0) == 0 || errno == EPERM ? pid : nil
    }

    /// Quién usa un elemento: lo que dice su `enUso` o cualquier programa que tenga abierto algo de sus rutas.
    func quienUsa(_ el: Elemento) -> String? {
        if let uso = el.enUso, let quien = quienUsa(uso) { return quien }
        return abiertos.hayAbierto(dentroDe: el.rutasVigiladas)
    }

    /// Quién está usando una carpeta o un archivo: un programa que se ejecuta desde ahí, que tiene algo abierto o
    /// cargado de ahí, que trabaja dentro (su carpeta actual) o que la recibió al arrancar («python3 /tmp/x/a.py»). Con
    /// `terminales` false no cuenta la carpeta de trabajo de las terminales y los agentes de la terminal (ver
    /// `ArchivosAbiertos.hayAbierto(dentroDe:terminales:)`).
    func usando(_ ruta: String, terminales: Bool = true) -> String? {
        let formas = ArchivosAbiertos.formas(ruta)
        let carpetas = formas.map { $0 + "/" }
        if let p = programas.first(where: { p in formas.contains(p.ruta) || carpetas.contains { p.ruta.hasPrefix($0) } }) {
            return p.visible
        }
        if let quien = abiertos.hayAbierto(dentroDe: ruta, terminales: terminales) { return quien }
        // ps da los argumentos tal como se escribieron: con /tmp o con /private/tmp.
        var buscadas = formas.map { $0.lowercased() }
        for f in buscadas where f.hasPrefix("/private/tmp/") || f.hasPrefix("/private/var/") { buscadas.append(String(f.dropFirst(8))) }
        guard let i = mencionan(buscadas) else { return nil }
        let pid = i < pidsDeLineas.count ? pidsDeLineas[i] : 0
        return programas.first { $0.pid == pid }?.visible ?? String(lineas[i].split(separator: " ").first ?? "un programa")
    }

    /// La primera línea de `lineas` en la que aparece alguna de esas rutas seguida de «/», de un espacio o al final de la
    /// línea (la ruta misma o algo de dentro). Una búsqueda en memoria (memmem) por cada forma de escribirla, en vez de
    /// mirar línea por línea: se pregunta cientos de veces en cada análisis.
    private func mencionan(_ buscadas: [String]) -> Int? {
        guard !todasLasLineas.isEmpty else { return nil }
        var primera: Int?
        // Se compara byte a byte: cada ruta, también con sus letras con tilde escritas de las dos formas (é o e + ´).
        let formas = Set(buscadas.flatMap { [$0, $0.precomposedStringWithCanonicalMapping, $0.decomposedStringWithCanonicalMapping] })
        todasLasLineas.withUnsafeBytes { pajar in
            guard let base = pajar.baseAddress else { return }
            for ruta in formas {
                for final in ["/", " ", "\n"] {
                    let aguja = Array((ruta + final).utf8)
                    guard let p = aguja.withUnsafeBytes({ memmem(base, pajar.count, $0.baseAddress, $0.count) }) else { continue }
                    let posicion = base.distance(to: UnsafeRawPointer(p))
                    // La línea que contiene esa posición: la última que empieza antes o en ella.
                    var (bajo, alto) = (0, inicios.count - 1)
                    while bajo < alto {
                        let medio = (bajo + alto + 1) / 2
                        if inicios[medio] <= posicion { bajo = medio } else { alto = medio - 1 }
                    }
                    primera = min(primera ?? bajo, bajo)
                }
            }
        }
        return primera
    }

    /// Nombre de la app (o servicio) abierta que coincide con alguna clave.
    func appAbierta(_ claves: [String]) -> String? {
        coincidencias(claves, todas: false).first.map { $0.app?.nombre ?? $0.programa?.visible ?? "" }
    }

    /// Lo que está funcionando y coincide con alguna clave, en orden: primero las apps (las de NSWorkspace, con ventana o
    /// sin ella), luego los programas que salen de una app que casa y los programas sueltos con ese nombre exacto. Con
    /// `todas` false se para en la primera.
    private func coincidencias(_ claves: [String], todas: Bool) -> [(app: AppAbierta?, programa: Programa?)] {
        let ids = claves.map { $0.lowercased() }.filter { $0.contains(".") }
        // Nombres cortos (Arc) solo cuentan si son exactamente iguales.
        let nombres = Set(claves.map(AppsInstaladas.normalizar).filter { $0.count >= 3 })
        func mismoID(_ id: String) -> Bool {
            !id.isEmpty && ids.contains { id == $0 || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }
        }
        // Las apps con ventana también cuentan si su nombre empieza por la clave («Android Studio Preview»).
        func mismoNombre(_ n: String, normal: Bool) -> Bool {
            nombres.contains { n == $0 || (normal && $0.count >= 4 && n.hasPrefix($0)) }
        }
        var r: [(app: AppAbierta?, programa: Programa?)] = []
        for a in apps where mismoID(a.bundleID) || mismoNombre(AppsInstaladas.normalizar(a.nombre), normal: a.normal) {
            r.append((a, nil))
            if !todas { return r }
        }
        // Servicios sin ventana (agentes, ayudantes): por la app que los contiene, comparando su identificador o su
        // nombre exacto. Los programas sueltos, por su nombre exacto: el ayudante «ChatGPT for Chrome» no es ChatGPT.
        for p in programas {
            if p.ids.contains(where: mismoID) || !p.nombresApp.isDisjoint(with: nombres) || (p.ids.isEmpty && nombres.contains(p.nombre)) {
                r.append((nil, p))
                if !todas { return r }
            }
        }
        return r
    }

    /// Las apps con ventana (como Brave) que hay detrás de lo que coincide con esas claves: la propia app o la que
    /// contiene un ayudante que coincide. nil si nada coincide o si algo de lo que coincide no es de una app que se pueda
    /// cerrar así (un servicio o un programa suelto): cerrar la app no lo liberaría.
    func appsQueCierran(_ claves: [String]) -> Set<String>? {
        var r = Set<String>()
        for c in coincidencias(claves, todas: true) {
            if let a = c.app {
                guard let id = a.normal ? a.bundleID : a.url.flatMap({ appConVentana(contiene: $0.path) }) else { return nil }
                r.insert(id)
            } else if let p = c.programa {
                guard let id = appConVentana(pid: p.pid) else { return nil }
                r.insert(id)
            }
        }
        return r.isEmpty ? nil : r
    }

    /// El identificador de la app con ventana que está abierta y a la que pertenece ese proceso (ella misma, o la .app de
    /// fuera que contiene su programa), si la hay.
    func appConVentana(pid: pid_t) -> String? {
        if let a = apps.first(where: { $0.pid == pid && $0.normal && !$0.bundleID.isEmpty }) { return a.bundleID }
        guard let p = programas.first(where: { $0.pid == pid }) else { return nil }
        return appConVentana(contiene: p.ruta)
    }

    /// La app con ventana abierta que contiene esa ruta (la .app de más fuera que tenga identificador).
    private func appConVentana(contiene ruta: String) -> String? {
        for app in Self.appsQueContienen(ruta) {
            guard let id = Bundle(path: app)?.bundleIdentifier?.lowercased() else { continue }
            return apps.contains { $0.normal && $0.bundleID == id } ? id : nil
        }
        return nil
    }
}

/// Lo que tus programas tienen abierto ahora mismo, leído del sistema (libproc): sus archivos abiertos, la carpeta en
/// la que trabaja cada uno, los sockets con ruta en los que escuchan (o a los que están conectados) y los programas y
/// librerías que tienen cargados. Solo se ven los procesos de tu usuario, que son los únicos que pueden tener abiertos
/// tus archivos.
struct ArchivosAbiertos {
    /// Cada ruta abierta y cada carpeta que contiene algo abierto → un proceso que la usa.
    private var usadas: [String: pid_t] = [:]
    /// Lo mismo, solo con las carpetas de trabajo de las terminales y los agentes de la terminal (`terminales`): cuentan
    /// como uso de lo que hay en esa carpeta, pero no del proyecto que la contiene (ver `hayAbierto(dentroDe:terminales:)`).
    private var deTerminales: [String: pid_t] = [:]
    /// Nombre para mostrar de cada proceso.
    private var nombres: [pid_t: String] = [:]
    /// Se pudieron leer (como mínimo los de este mismo programa, que siempre tiene algo abierto).
    private(set) var leidos = false
    /// Cuántas rutas abiertas distintas hay (para el diagnóstico).
    private(set) var cuantas = 0

    /// Programas que esperan órdenes en una carpeta sin usar lo que hay en ella: las terminales (zsh, bash…) y los
    /// agentes de la terminal (claude, codex…), por el nombre exacto de su ejecutable. Lo que compilen o ejecuten arranca
    /// como otro programa, con su propia carpeta de trabajo y sus propios archivos abiertos, y eso sí cuenta.
    static let terminales: Set<String> = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash", "login", "tmux", "screen",
                                          "claude", "codex", "disclaimer", "cursor-agent", "gemini"]

    /// Lee lo que tienen abierto esos procesos, menos este mismo programa (que recorre el disco al analizar). De los de
    /// `terminales` (sus números), su carpeta de trabajo se anota aparte.
    static func capturar(pids: [pid_t], nombres: [pid_t: String], terminales: Set<pid_t> = []) -> ArchivosAbiertos {
        var a = ArchivosAbiertos()
        a.nombres = nombres
        let propio = getpid()
        a.leidos = !rutas(de: propio).abiertas.isEmpty
        for pid in pids where pid != propio {
            let r = rutas(de: pid)
            for ruta in r.abiertas { Self.registrar(ruta, pid, en: &a.usadas, cuantas: &a.cuantas) }
            if let cwd = r.trabajo {
                if terminales.contains(pid) {
                    Self.registrar(cwd, pid, en: &a.deTerminales, cuantas: &a.cuantas)
                } else {
                    Self.registrar(cwd, pid, en: &a.usadas, cuantas: &a.cuantas)
                }
            }
        }
        return a
    }

    /// Lo que tienen abierto ahora mismo los procesos de tu usuario, sin el resto de `Procesos.capturar` (apps, ps,
    /// simuladores): para mirarlo varias veces seguidas, como antes y después de cada lote al comprimir.
    static func ahora() -> ArchivosAbiertos {
        let uid = getuid()
        var pids: [pid_t] = []
        var nombres: [pid_t: String] = [:]
        var deTerminal = Set<pid_t>()
        for pid in Procesos.todosLosPids() {
            var info = proc_bsdshortinfo()
            let t = tam(proc_bsdshortinfo.self)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, t) == t, info.pbsi_uid == uid else { continue }
            pids.append(pid)
            let nombre = texto(info.pbsi_comm)
            nombres[pid] = nombre
            if terminales.contains(nombre) { deTerminal.insert(pid) }
        }
        return capturar(pids: pids, nombres: nombres, terminales: deTerminal)
    }

    /// El programa que tiene abierta esa ruta o algo dentro de ella (un archivo, su carpeta de trabajo, una
    /// librería cargada), si hay alguno. Con `terminales` false no cuentan las carpetas de trabajo de las terminales y los
    /// agentes de la terminal: una terminal abierta en la carpeta de un proyecto no usa sus intermedios ni sus
    /// dependencias (lo que lance sí cuenta, porque es otro programa).
    func hayAbierto(dentroDe ruta: String, terminales: Bool = true) -> String? {
        guard !usadas.isEmpty || !deTerminales.isEmpty else { return nil }
        let formas = Self.formas(ruta)
        for forma in formas {
            if let pid = usadas[forma] { return nombres[pid] ?? "Un programa (proceso \(pid))" }
        }
        guard terminales else { return nil }
        for forma in formas {
            if let pid = deTerminales[forma] { return nombres[pid] ?? "Un programa (proceso \(pid))" }
        }
        return nil
    }

    func hayAbierto(dentroDe rutas: [URL]) -> String? {
        rutas.lazy.compactMap { hayAbierto(dentroDe: $0.path) }.first
    }

    /// Como `hayAbierto(dentroDe:)`, pero el número del proceso (para saber de qué app es).
    func proceso(dentroDe ruta: String) -> pid_t? {
        guard !usadas.isEmpty || !deTerminales.isEmpty else { return nil }
        let formas = Self.formas(ruta)
        return formas.lazy.compactMap { usadas[$0] }.first ?? formas.lazy.compactMap { deTerminales[$0] }.first
    }

    /// Como `hayAbierto(dentroDe:)`, para una ruta que ya es real (sin enlaces en sus carpetas): no la normaliza, así
    /// que sirve para mirar miles de archivos de una misma carpeta.
    func hayAbierto(rutaReal ruta: String) -> String? {
        usadas[ruta].map { nombres[$0] ?? "Un programa (proceso \($0))" }
    }

    /// La ruta tal cual y con su carpeta sin enlaces («/tmp/x» → «/private/tmp/x»), que es como la da el sistema.
    /// El último nombre no se resuelve: un enlace es un archivo aparte de aquello a lo que apunta.
    static func formas(_ ruta: String) -> [String] {
        let limpia = ruta.count > 1 && ruta.hasSuffix("/") ? String(ruta.dropLast()) : ruta
        var r = [limpia]
        guard let real = realpath(Rutas.padre(limpia), nil) else { return r }
        defer { free(real) }
        let padre = String(cString: real)
        let otra = (padre == "/" ? "" : padre) + "/" + Rutas.nombre(limpia)
        if otra != limpia { r.append(otra) }
        return r
    }

    /// Anota la ruta y todas las carpetas que la contienen (hasta encontrar una ya anotada).
    private static func registrar(_ ruta: String, _ pid: pid_t, en usadas: inout [String: pid_t], cuantas: inout Int) {
        guard ruta.hasPrefix("/"), ruta.count > 1, !delSistema.contains(where: { ruta.hasPrefix($0) }) else { return }
        if usadas[ruta] == nil { cuantas += 1 }
        var actual = ruta
        while actual.count > 1, usadas[actual] == nil {
            usadas[actual] = pid
            actual = Rutas.padre(actual)
        }
    }

    /// Lo del sistema no es de nadie a quien limpiar: no hace falta anotarlo.
    private static let delSistema = ["/System/", "/usr/", "/dev/", "/bin/", "/sbin/"]

    private static func tam<T>(_: T.Type) -> Int32 { Int32(MemoryLayout<T>.size) }

    /// Texto de una ruta de libproc (un arreglo fijo de caracteres terminado en cero).
    private static func texto<T>(_ tupla: T) -> String {
        withUnsafeBytes(of: tupla) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// PROC_PIDREGIONPATHINFO2 (22): como la pública PROC_PIDREGIONPATHINFO, pero salta las regiones de memoria que
    /// no vienen de un archivo, así que tarda menos de la mitad. No está en la cabecera pública (lsof la usa):
    /// si el sistema no la acepta, se usa la pública.
    private static let saborRegiones: Int32 = {
        var r = proc_regionwithpathinfo()
        let t = tam(proc_regionwithpathinfo.self)
        return proc_pidinfo(getpid(), 22, 0, &r, t) == t ? 22 : PROC_PIDREGIONPATHINFO
    }()

    /// Todo lo que un proceso tiene abierto: su carpeta de trabajo (aparte), sus archivos, sus sockets con ruta y lo que
    /// tiene cargado en memoria. Las carpetas y archivos abiertos solo para recibir avisos de cambios (O_EVTONLY: así
    /// vigilan una carpeta muchos servicios del sistema) no cuentan: no leen ni escriben nada, ni retienen espacio.
    private static func rutas(de pid: pid_t) -> (trabajo: String?, abiertas: [String]) {
        var r: [String] = []
        var trabajo: String?
        var cwd = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, tam(proc_vnodepathinfo.self)) == tam(proc_vnodepathinfo.self) {
            trabajo = texto(cwd.pvi_cdir.vip_path)
        }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if bytes > 0 {
            let paso = MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / paso + 32)
            let leidos = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            for f in fds.prefix(max(0, Int(leidos)) / paso) {
                if f.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                    var info = vnode_fdinfowithpath()
                    if proc_pidfdinfo(pid, f.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, tam(vnode_fdinfowithpath.self)) == tam(vnode_fdinfowithpath.self),
                       info.pfi.fi_openflags & UInt32(O_EVTONLY) == 0 {
                        r.append(texto(info.pvip.vip_path))
                    }
                } else if f.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                    // Un socket de dominio Unix (un servidor que escucha en «/tmp/x/servidor.sock», o un cliente
                    // conectado a él): el archivo del socket está en uso mientras el proceso viva.
                    var info = socket_fdinfo()
                    guard proc_pidfdinfo(pid, f.proc_fd, PROC_PIDFDSOCKETINFO, &info, tam(socket_fdinfo.self)) == tam(socket_fdinfo.self),
                          info.psi.soi_kind == Int32(SOCKINFO_UN) else { continue }
                    let un = info.psi.soi_proto.pri_un
                    for ruta in [texto(un.unsi_addr.ua_sun.sun_path), texto(un.unsi_caddr.ua_sun.sun_path)] where ruta.hasPrefix("/") {
                        // Se guarda como lo escribió el programa («/tmp/x.sock»): se pasa a la ruta real, como las demás.
                        r.append(formas(ruta).last ?? ruta)
                    }
                }
            }
        }
        var direccion: UInt64 = 0
        var anterior = ""
        for _ in 0..<100_000 {
            var region = proc_regionwithpathinfo()
            guard proc_pidinfo(pid, saborRegiones, direccion, &region, tam(proc_regionwithpathinfo.self)) == tam(proc_regionwithpathinfo.self) else { break }
            let ruta = texto(region.prp_vip.vip_path)
            if !ruta.isEmpty && ruta != anterior { r.append(ruta); anterior = ruta }
            let siguiente = region.prp_prinfo.pri_address &+ region.prp_prinfo.pri_size
            guard siguiente > direccion else { break }
            direccion = siguiente
        }
        return (trabajo, r)
    }
}

/// Temporales sueltos que las apps crean con mkstemp directamente en tu carpeta de temporales (/var/folders/…/T) y no
/// borran nunca: «.com.openai.codex.AbC123» es el identificador de la app, un punto y seis letras al azar.
enum TemporalesSueltos {
    /// Un temporal suelto: su ruta, lo que libera al borrarlo y su última modificación.
    struct Suelto {
        let ruta: String
        let bytes: Int64
        let modificado: Date
    }

    private static let patron = try! NSRegularExpression(pattern: #"^\.([a-z0-9-]+(\.[A-Za-z0-9-]+){2,})\.[A-Za-z0-9]{6}$"#)

    /// El identificador de la app de un temporal suelto («.com.openai.codex.AbC123» → «com.openai.codex»), o nil.
    static func app(de nombre: String) -> String? {
        guard nombre.hasPrefix("."),
              let m = patron.firstMatch(in: nombre, range: NSRange(nombre.startIndex..., in: nombre)),
              let r = Range(m.range(at: 1), in: nombre) else { return nil }
        return String(nombre[r])
    }

    /// ¿Es «<prefijo>XXXXXX», con seis letras o cifras detrás?
    static func casa(_ nombre: String, prefijo: String) -> Bool {
        guard nombre.hasPrefix(prefijo), nombre.utf8.count == prefijo.utf8.count + 6 else { return false }
        return nombre.utf8.suffix(6).allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    /// Los temporales sueltos de `prefijo` que hay directamente en `carpeta`: archivos normales tuyos (no carpetas ni
    /// enlaces). `viejos` son los que llevan `minHoras` o más sin cambios y que nadie tiene abiertos según `abiertos`;
    /// `recientes`, los demás (más nuevos o abiertos), que no se tocan.
    static func listar(en carpeta: String, prefijo: String, minHoras: Double, abiertos: ArchivosAbiertos)
        -> (viejos: [Suelto], recientes: Int, abiertosAhora: Int) {
        let limite = Date().addingTimeInterval(-minHoras * 3600)
        // La carpeta sin enlaces (/var → /private/var), como da el sistema lo que está abierto: así basta con buscar
        // cada archivo tal cual.
        let real = Rutas.real(URL(fileURLWithPath: carpeta))
        var viejos: [Suelto] = []
        var recientes = 0
        var abiertosAhora = 0
        for n in (try? FileManager.default.contentsOfDirectory(atPath: carpeta)) ?? [] where casa(n, prefijo: prefijo) {
            let ruta = carpeta + "/" + n
            var st = stat()
            guard lstat(ruta, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { continue }
            let modificado = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if abiertos.hayAbierto(rutaReal: real + "/" + n) != nil {
                abiertosAhora += 1
            } else if modificado > limite {
                recientes += 1
            } else {
                // Un archivo con varios nombres solo se libera al borrarlos todos: se reparte, como en el índice.
                let bytes = Int64(st.st_blocks) * 512 / Int64(max(1, st.st_nlink))
                viejos.append(Suelto(ruta: ruta, bytes: bytes, modificado: modificado))
            }
        }
        return (viejos, recientes, abiertosAhora)
    }
}

/// Lo que se mira del historial de un repositorio de git para saber si compactarlo (git gc) libera algo.
enum HistorialGit {
    /// Lo que cuenta git (`git count-objects -v`, solo lectura): «size» (objetos sueltos), «size-pack», «count»… en KiB.
    static func cuenta(_ repo: String) -> [String: Int64] {
        var datos: [String: Int64] = [:]
        for linea in Shell.ejecutar("/usr/bin/git", ["-C", repo, "count-objects", "-v"], limite: 10).salida.split(separator: "\n") {
            let partes = linea.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if partes.count == 2, let v = Int64(partes[1]) { datos[partes[0]] = v }
        }
        return datos
    }

    /// Los archivos a medio escribir que git deja en objects/pack mientras empaqueta (tmp_pack_…, tmp_idx_…, .tmp-…).
    static func temporales(en carpeta: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: carpeta)) ?? []).filter { $0.hasPrefix("tmp_") || $0.hasPrefix(".tmp-") }
    }

    /// Borra los archivos a medio escribir de objects/pack que no estaban en `previos` (los que dejó un git gc que falló),
    /// si nadie los tiene abiertos. Devuelve cuántos borró.
    @discardableResult
    static func borrarTemporales(en carpeta: String, salvo previos: Set<String>) -> Int {
        let abiertos = ArchivosAbiertos.ahora()
        guard abiertos.leidos else { return 0 }
        var borrados = 0
        for t in temporales(en: carpeta) where !previos.contains(t) {
            let ruta = carpeta + "/" + t
            if abiertos.hayAbierto(dentroDe: ruta) == nil && unlink(ruta) == 0 { borrados += 1 }
        }
        return borrados
    }

    /// Cómo está guardado el historial (.git/objects).
    struct Objetos {
        /// Lo que ocupa objects/ entero y lo que ocupa solo él: sin lo que comparte con clones de APFS o enlaces duros
        /// (una copia hecha con el Finder o un «git clone» local).
        var asignado: Int64 = 0
        var privado: Int64 = 0
        /// Objetos sueltos (lo que git empaqueta al compactar): los que comprimen bien (código, texto…) y los que ya
        /// vienen comprimidos (fotos, vídeos, zip, instaladores…), y de cada uno, los de archivos con varias versiones.
        var texto: Int64 = 0
        var textoConVersiones: Int64 = 0
        var binario: Int64 = 0
        var binarioConVersiones: Int64 = 0
        /// Lo que se pierde por guardar cada objeto suelto en bloques de 4 KiB: lo que se gana seguro al empaquetar.
        var desperdicio: Int64 = 0

        /// Lo que se espera liberar. Al empaquetar, git vuelve a comprimir cada objeto como ya lo estaba; lo que gana de
        /// verdad es guardar las versiones parecidas de un mismo archivo como diferencias. Así que cuenta la mitad del
        /// texto con varias versiones, una quinta parte del resto del texto (versiones que ya no están en ninguna rama),
        /// una décima parte de lo ya comprimido con varias versiones (las diferencias entre dos fotos o dos instaladores
        /// ahorran poco) y nada de lo ya comprimido con una sola versión (con fotos, el historial hasta crece un poco).
        var estimado: Int64 {
            desperdicio + textoConVersiones / 2 + (texto - textoConVersiones) / 5 + binarioConVersiones / 10
        }
    }

    /// Recorre .git/objects de un repositorio (solo lectura). nil si no se puede leer.
    static func analizar(repo: String) -> Objetos? {
        let raiz = repo + "/.git/objects"
        guard let rutaC = strdup(raiz) else { return nil }
        defer { free(rutaC) }
        var argumentos: [UnsafeMutablePointer<CChar>?] = [rutaC, nil]
        guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }
        var o = Objetos()
        var sueltos: [(id: String, bytes: Int64, texto: Bool)] = []
        while let e = fts_read(fts) {
            guard Int32(e.pointee.fts_info) == FTS_F else { continue }
            let st = e.pointee.fts_statp.pointee
            let ocupa = Int64(st.st_blocks) * 512
            let ruta = String(cString: e.pointee.fts_path)
            o.asignado += ocupa
            if st.st_nlink == 1 {
                o.privado += st.st_flags & UInt32(UF_COMPRESSED) != 0 ? ocupa : min(ocupa, Privado.consultar(ruta)?.privado ?? ocupa)
            }
            // Un objeto suelto: objects/ab/cdef… (40 letras en total, o 64 con SHA-256).
            let carpeta = Rutas.nombre(Rutas.padre(ruta))
            let nombre = Rutas.nombre(ruta)
            guard e.pointee.fts_level == 2, carpeta.count == 2, nombre.count == 38 || nombre.count == 62,
                  carpeta.allSatisfy(\.isHexDigit), nombre.allSatisfy(\.isHexDigit) else { continue }
            o.desperdicio += max(0, ocupa - Int64(st.st_size))
            // Comprime bien si lo guardado es bastante menos que el contenido (lo dice la cabecera del objeto).
            let texto = tamanoSinComprimir(ruta).map { Double(st.st_size) < 0.9 * Double($0) } ?? false
            sueltos.append((carpeta + nombre, Int64(st.st_size), texto))
        }
        // Si git no contesta, se cuenta como si todo tuviera varias versiones.
        let conVersiones = objetosConVersiones(repo)
        for s in sueltos {
            let varias = conVersiones?.contains(s.id) ?? true
            if s.texto {
                o.texto += s.bytes
                if varias { o.textoConVersiones += s.bytes }
            } else {
                o.binario += s.bytes
                if varias { o.binarioConVersiones += s.bytes }
            }
        }
        return o
    }

    /// El tamaño del contenido de un objeto suelto, leído de su cabecera («blob 12345\0»), que va comprimida con zlib.
    static func tamanoSinComprimir(_ ruta: String) -> Int64? {
        let fd = open(ruta, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var origen = [UInt8](repeating: 0, count: 512)
        let leidos = read(fd, &origen, origen.count)
        guard leidos > 2 else { return nil }
        var destino = [UInt8](repeating: 0, count: 64)
        // Los dos primeros bytes son la cabecera de zlib; lo demás, DEFLATE (lo que la biblioteca llama «ZLIB»).
        let n = origen.withUnsafeBufferPointer { o in
            compression_decode_buffer(&destino, destino.count, o.baseAddress! + 2, leidos - 2, nil, COMPRESSION_ZLIB)
        }
        let cabecera = String(decoding: destino.prefix(n).prefix { $0 != 0 }, as: UTF8.self)
        return cabecera.split(separator: " ").last.flatMap { Int64($0) }
    }

    /// Los objetos de los archivos (y carpetas) del historial que tienen más de una versión, según «git rev-list --objects
    /// --all» (solo lectura): solo ellos ganan de verdad al empaquetar. nil si git no contestó.
    static func objetosConVersiones(_ repo: String) -> Set<String>? {
        let r = Shell.ejecutar("/usr/bin/git", ["-C", repo, "rev-list", "--objects", "--all"], limite: 30, prioridad: .utility)
        guard r.estado == 0 else { return nil }
        var porRuta: [Substring: [Substring]] = [:]
        for linea in r.salida.split(separator: "\n") {
            guard let espacio = linea.firstIndex(of: " ") else { continue }
            porRuta[linea[linea.index(after: espacio)...], default: []].append(linea[..<espacio])
        }
        var varias = Set<String>()
        for (_, ids) in porRuta where ids.count > 1 { ids.forEach { varias.insert(String($0)) } }
        return varias
    }
}

enum Huella {
    /// SHA-256 del contenido completo de un archivo, leído por bloques.
    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            guard let bloque = try? h.read(upToCount: 4 * 1024 * 1024), !bloque.isEmpty else { break }
            hasher.update(data: bloque)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Huella rápida: los primeros y los últimos 64 KB. Descarta archivos distintos sin leerlos enteros.
    static func parcial(_ url: URL, tamano: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        guard let inicio = try? h.read(upToCount: 65_536) else { return nil }
        hasher.update(data: inicio)
        if tamano > 131_072 {
            try? h.seek(toOffset: UInt64(tamano - 65_536))
            if let fin = try? h.read(upToCount: 65_536) { hasher.update(data: fin) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
