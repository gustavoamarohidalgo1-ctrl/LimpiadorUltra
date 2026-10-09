import Foundation

/// Qué copias locales de iCloud Drive quitar: lo que lleva la acción `.quitarDescarga`. Al limpiar se vuelven a buscar
/// (`Nube.buscar`) y cada archivo se comprueba otra vez justo antes de quitarlo.
struct QuitarDescarga: Hashable, Sendable {
    /// Carpetas en las que se busca (rutas completas, de `Nube.raices()`).
    var raices: [String]
    /// Solo archivos que nadie abrió desde hace al menos estos días.
    var minDias: Double
    /// Lo más pequeño que se quita (los archivos pequeños apenas liberan nada).
    var minimo: Int64 = 1_048_576
}

/// iCloud Drive: archivos que ya están en la nube y que el Mac guarda además en el disco. Quitar la copia local
/// (`FileManager.evictUbiquitousItem`) no borra nada: el archivo sigue en iCloud y en su carpeta, con su nombre (con el
/// icono de la nube), y macOS lo vuelve a descargar solo al abrirlo. Solo se quitan los que están subidos y sin cambios
/// pendientes, sin conflictos, que no se están descargando ni subiendo y que nadie abrió en meses.
enum Nube {
    /// Lo que macOS dice de un archivo de iCloud (sus `URLResourceValues`).
    struct Estado: Sendable {
        var enICloud = false
        /// Excluido de la sincronización (.nosync…): solo existe en este Mac.
        var soloAqui = false
        /// La copia local es la última versión (`.current`).
        var alDia = false
        var subido = false
        var subiendo = false
        var bajando = false
        var conflictos = false
        var abierto: Date?
    }

    /// Un archivo cuya copia local se puede quitar.
    struct Candidato: Sendable {
        let ruta: String
        /// Lo que ocupa en el disco (lo que se libera).
        let ocupa: Int64
        let abierto: Date
    }

    struct Busqueda: Sendable {
        var candidatos: [Candidato] = []
        /// Abiertos hace menos de `minDias`.
        var recientes = 0
        /// Con cambios sin subir, subiéndose o con conflictos: solo están completos en este Mac.
        var sinSubir = 0
        /// Abiertos ahora por algún programa.
        var abiertos = 0
        /// Ya estaban solo en la nube.
        var yaEnLaNube = 0
        var ocupan: Int64 { candidatos.reduce(0) { $0 + $1.ocupa } }
    }

    /// Dónde se busca: tu iCloud Drive (com~apple~CloudDocs), la parte visible en iCloud Drive de las carpetas de las apps
    /// («Documents» de Pages, Vista Previa…) y el Escritorio y Documentos si están en iCloud. Nunca los datos internos que
    /// las apps guardan en iCloud (copias de seguridad de WhatsApp…): las apps los esperan en el Mac. `esICloud` solo se
    /// cambia en las pruebas.
    static func raices(esICloud: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false })
        -> [String] {
        var r: [String] = []
        let movil = Rutas.enHome("Library/Mobile Documents")
        for h in Rutas.hijos(movil) where Rutas.esCarpeta(h) {
            if h.lastPathComponent == "com~apple~CloudDocs" {
                r.append(h.path)
            } else if Rutas.esCarpeta(h.appendingPathComponent("Documents")) {
                r.append(h.appendingPathComponent("Documents").path)
            }
        }
        for rel in ["Desktop", "Documents"] where esICloud(Rutas.enHome(rel)) { r.append(Rutas.enHome(rel).path) }
        return r
    }

    /// Lo que macOS dice ahora de ese archivo (sin descargarlo ni abrirlo).
    static func leer(_ url: URL) -> Estado? {
        var u = url
        u.removeAllCachedResourceValues()
        let claves: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsExcludedFromSyncKey,
                                           .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
                                           .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey,
                                           .ubiquitousItemHasUnresolvedConflictsKey, .contentAccessDateKey]
        guard let v = try? u.resourceValues(forKeys: claves) else { return nil }
        return Estado(enICloud: v.isUbiquitousItem ?? false, soloAqui: v.ubiquitousItemIsExcludedFromSync ?? false,
                      alDia: v.ubiquitousItemDownloadingStatus == .current, subido: v.ubiquitousItemIsUploaded ?? false,
                      subiendo: v.ubiquitousItemIsUploading ?? false, bajando: v.ubiquitousItemIsDownloading ?? false,
                      conflictos: v.ubiquitousItemHasUnresolvedConflicts ?? false, abierto: v.contentAccessDate)
    }

    /// Por qué no se puede quitar la copia local (nil si se puede): tiene que estar en iCloud y sincronizarse, la copia
    /// local ser la última versión, estar subido del todo, sin conflictos, sin descargarse ni subirse, y que nadie lo haya
    /// abierto desde hace `minDias`.
    enum NoSe: Equatable { case noEsDeICloud, sinSubir, reciente }
    static func noSePuede(_ e: Estado, ahora: Date, minDias: Double) -> NoSe? {
        guard e.enICloud, !e.soloAqui else { return .noEsDeICloud }
        guard e.alDia, e.subido, !e.subiendo, !e.bajando, !e.conflictos else { return .sinSubir }
        guard let abierto = e.abierto, ahora.timeIntervalSince(abierto) >= minDias * 86400 else { return .reciente }
        return nil
    }

    /// Los archivos de `q` cuya copia local se puede quitar: regulares, tuyos, de `q.minimo` o más, que no estén ya solo en
    /// la nube (SF_DATALESS), que nadie tenga abiertos y que cumplan `noSePuede`. `estado` y `ahora` solo se cambian en
    /// las pruebas.
    static func buscar(_ q: QuitarDescarga, abiertos: ArchivosAbiertos, ahora: Date = Date(),
                       estado: (URL) -> Estado? = Nube.leer) -> Busqueda {
        var b = Busqueda()
        let uid = getuid()
        for raiz in q.raices where Rutas.esCarpeta(URL(fileURLWithPath: raiz)) {
            let real = Rutas.real(URL(fileURLWithPath: raiz))
            guard let rutaC = strdup(raiz) else { continue }
            defer { free(rutaC) }
            var argumentos: [UnsafeMutablePointer<CChar>?] = [rutaC, nil]
            guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { continue }
            defer { fts_close(fts) }
            while let e = fts_read(fts) {
                let tipo = Int32(e.pointee.fts_info)
                if tipo == FTS_D {
                    // Ni paquetes (una biblioteca de Fotos, una app) ni carpetas de git: se tratan enteros o nunca.
                    let n = String(cString: e.pointee.fts_path).lowercased()
                    if e.pointee.fts_level > 0 && (n.hasSuffix(".photoslibrary") || n.hasSuffix(".app") || n.hasSuffix("/.git")) {
                        fts_set(fts, e, FTS_SKIP)
                    }
                    continue
                }
                guard tipo == FTS_F else { continue }
                let st = e.pointee.fts_statp.pointee
                guard st.st_uid == uid, Int64(st.st_size) >= q.minimo else { continue }
                if st.st_flags & UInt32(SF_DATALESS) != 0 {
                    b.yaEnLaNube += 1
                    continue
                }
                let ruta = String(cString: e.pointee.fts_path)
                guard let est = estado(URL(fileURLWithPath: ruta)) else { continue }
                switch noSePuede(est, ahora: ahora, minDias: q.minDias) {
                case .noEsDeICloud: continue
                case .sinSubir:
                    b.sinSubir += 1
                    continue
                case .reciente:
                    b.recientes += 1
                    continue
                case nil: break
                }
                guard abiertos.hayAbierto(rutaReal: real + ruta.dropFirst(raiz.count)) == nil else {
                    b.abiertos += 1
                    continue
                }
                b.candidatos.append(Candidato(ruta: ruta, ocupa: Int64(st.st_blocks) * 512, abierto: est.abierto ?? ahora))
            }
        }
        return b
    }

    struct Resultado: Sendable {
        var quitados = 0
        var bytes: Int64 = 0
        var archivos: [String] = []
        /// Cambiaron entre la búsqueda y el momento de quitarlos (alguien los abrió, cambiaron o se están subiendo).
        var cambiaron = 0
        var abiertos = 0
        var fallos: [String] = []
    }

    /// Quita la copia local de los archivos de `q` que siguen cumpliendo las reglas ahora mismo (se vuelven a buscar y cada
    /// uno se comprueba otra vez justo antes). Solo en las carpetas de `raices()`. `estado`, `quitar` y `ahora` solo se
    /// cambian en las pruebas.
    static func quitar(_ q: QuitarDescarga, raicesValidas: [String] = Nube.raices(), ahora: Date = Date(),
                       cancelado: () -> Bool = { false }, estado: (URL) -> Estado? = Nube.leer,
                       quitar: (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) }) -> Resultado {
        var r = Resultado()
        let validas = Set(raicesValidas)
        let cola = QuitarDescarga(raices: q.raices.filter { validas.contains($0) }, minDias: q.minDias, minimo: q.minimo)
        let abiertos = ArchivosAbiertos.ahora()
        guard abiertos.leidos else {
            r.fallos.append("No pude ver qué archivos tienen abiertos los programas, así que no quité nada.")
            return r
        }
        // Lo abierto se vuelve a leer cada 2 s (leerlo cuesta unas décimas: no por cada archivo).
        var vistos = abiertos
        var leidos = Date()
        for c in buscar(cola, abiertos: abiertos, ahora: ahora, estado: estado).candidatos {
            if cancelado() { break }
            let url = URL(fileURLWithPath: c.ruta)
            // Justo antes: sigue igual de subido y sin abrir, y nadie lo tiene abierto.
            var st = stat()
            guard lstat(c.ruta, &st) == 0, st.st_flags & UInt32(SF_DATALESS) == 0, let e = estado(url),
                  noSePuede(e, ahora: ahora, minDias: q.minDias) == nil else {
                r.cambiaron += 1
                continue
            }
            if Date().timeIntervalSince(leidos) > 2 {
                vistos = ArchivosAbiertos.ahora()
                leidos = Date()
            }
            if !vistos.leidos || vistos.hayAbierto(dentroDe: c.ruta) != nil {
                r.abiertos += 1
                continue
            }
            do {
                try quitar(url)
                r.quitados += 1
                r.bytes += c.ocupa
                r.archivos.append(c.ruta)
            } catch {
                r.fallos.append("\(Formato.rutaCorta(c.ruta)): \(error.localizedDescription)")
            }
        }
        return r
    }
}
