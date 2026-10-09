import Foundation

/// Qué copias idénticas unir: lo que lleva la acción `.clonar`. Guarda cómo estaba cada archivo cuando se compararon
/// (tamaño y fecha de modificación): al unirlas, lo que haya cambiado desde entonces no se toca.
struct Clonacion: Hashable, Sendable {
    struct Archivo: Hashable, Sendable {
        let ruta: String
        let tamano: Int64
        let modificado: Compresor.Tiempo
    }

    /// El archivo cuyo contenido se queda: las copias pasan a ser clones suyos.
    var original: Archivo
    var copias: [Archivo]
}

/// Une copias idénticas en clones de APFS: cada copia se cambia por un clon del original (comparten los mismos bloques
/// del disco, como lo que hace «Duplicar» en el Finder), así que el contenido se guarda una sola vez. No se borra nada:
/// cada ruta sigue existiendo con el mismo contenido, nombre, permisos, atributos y fechas. Si después alguien cambia una
/// copia, APFS copia solo lo que cambia y las demás se quedan como estaban.
///
/// Por cada copia:
/// 1. clonefile del original en una carpeta temporal del mismo disco;
/// 2. se compara el clon con la copia byte a byte y se le ponen los permisos, el grupo, los atributos extendidos, la
///    ACL, las banderas y las fechas (creación, modificación y acceso) de la copia;
/// 3. si la copia no cambió y nadie la tiene abierta, se intercambian los dos de golpe (renamex_np con RENAME_SWAP).
///    Mientras el intercambio se pueda deshacer, el clon no se deja escribir (lo que alguien escribiera en él se perdería
///    al devolver la copia);
/// 4. se vuelve a mirar: si alguien tenía abierta la copia (ahora estaría en la carpeta temporal) o la cambió durante el
///    intercambio, se deshace; si no, se borra la versión vieja y el clon recupera los permisos de la copia.
/// Ante cualquier fallo, la copia se queda como estaba. Si la app se cierra a mitad, la próxima limpieza recoge lo que
/// quede en la carpeta temporal (solo lo que esté repetido) y devuelve sus permisos a lo que ya estuviera en su sitio.
enum Clonador {
    /// Las banderas con las que un archivo no se toca: inmutable, solo para añadir, del sistema, sin datos en el disco
    /// (dataless: leerlo lo descargaría de la nube) o seguido por su número de documento.
    static let banderasProhibidas = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(UF_TRACKED) | UInt32(SF_IMMUTABLE)
        | UInt32(SF_APPEND) | UInt32(SF_RESTRICTED) | UInt32(SF_NOUNLINK) | UInt32(SF_DATALESS)

    /// Dónde se preparan los clones antes de cambiarlos por las copias: en tu carpeta, en el mismo disco.
    static var carpetaTemporal: String { Rutas.enHome("Library/Application Support/LimpiadorMac/uniendo").path }

    /// Pasos en los que una prueba puede simular un fallo (`.fallar`: esa copia se deja como estaba) o un cierre de golpe
    /// (`.abortar`: se para en seco sin recoger nada).
    enum Paso: Sendable { case clonado, preparado, antesDeCambiar, cambiado, antesDeBorrar }
    typealias Simulacion = (Paso, String) -> Compresor.Simulado

    struct Resultado: Sendable {
        /// El archivo cuyo contenido comparten ahora las copias.
        var fuente = ""
        /// Copias cambiadas por un clon y lo que se ahorró de verdad con cada una (tamaño privado antes − después).
        var unidas: [(ruta: String, ahorro: Int64)] = []
        var ahorro: Int64 { unidas.reduce(0) { $0 + $1.ahorro } }
        /// Ya eran clones del original: no había nada que hacer.
        var yaUnidas = 0
        /// Abiertas por algún programa al ir a cambiarlas: se quedan como estaban.
        var abiertas = 0
        /// Cambiaron (o desaparecieron) desde el análisis: se quedan como estaban.
        var cambiaron = 0
        /// Lo que falló (cada copia se queda como estaba).
        var fallos: [String] = []
        /// De una unión anterior que se cortó: versiones que no se pudieron dar por repetidas. Se dejan donde están.
        var copiasGuardadas: [String] = []
    }

    /// Une las copias de `c` con su original. `simular` solo se usa en las pruebas.
    static func unir(_ c: Clonacion, simular: Simulacion? = nil) -> Resultado {
        var r = Resultado()
        r.copiasGuardadas = recogerRestos()
        let todos = [c.original] + c.copias
        guard todos.allSatisfy({ Seguridad.sePuedeModificar(URL(fileURLWithPath: $0.ruta)) }) else {
            r.fallos.append("\(Formato.rutaCorta(c.original.ruta)): sus copias no están todas en tu carpeta; no toqué nada.")
            return r
        }
        // Cómo está cada uno ahora: lo que cambió desde que se compararon no se toca.
        var estados: [String: Compresor.EstadoArchivo] = [:]
        for a in todos {
            if let e = Compresor.EstadoArchivo(ruta: a.ruta), e.esRegular, e.tamano == a.tamano, e.modificado == a.modificado {
                estados[a.ruta] = e
            }
        }
        // La fuente: el original, o una copia que ya esté comprimida (las demás heredan la compresión al clonarla).
        let comprimidas = todos.filter { estados[$0.ruta].map { $0.banderas & UInt32(UF_COMPRESSED) != 0 } ?? false }
        guard let fuente = comprimidas.min(by: { estados[$0.ruta]!.ocupa < estados[$1.ruta]!.ocupa })
                ?? (estados[c.original.ruta] != nil ? c.original : nil),
              let estadoFuente = estados[fuente.ruta] else {
            r.cambiaron = todos.count
            return r
        }
        r.fuente = fuente.ruta
        r.cambiaron = todos.count - estados.count
        let infoFuente = Privado.consultar(fuente.ruta)

        // La carpeta temporal tiene que estar en el mismo disco: un clon no puede cruzar de disco.
        let base = carpetaTemporal
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let nombreTemporal = UUID().uuidString
        let temporal = base + "/" + nombreTemporal
        guard mkdir(temporal, 0o700) == 0 else {
            r.fallos.append("No pude crear una carpeta temporal en \(Formato.rutaCorta(base)) (\(String(cString: strerror(errno)))).")
            return r
        }
        let temporalReal = Rutas.real(URL(fileURLWithPath: temporal))
        var st = stat()
        guard lstat(temporal, &st) == 0, st.st_dev == estadoFuente.dispositivo else {
            rmdir(temporal)
            r.fallos.append("\(Formato.rutaCorta(fuente.ruta)): no está en el mismo disco que tu carpeta; no se puede unir.")
            return r
        }

        // Qué clon es de qué copia y qué permisos tenía: si la app se cerrara a mitad, sirve para recoger lo que quede.
        let otros = todos.filter { $0.ruta != fuente.ruta && estados[$0.ruta] != nil }
        var manifiesto = ""
        for (k, a) in otros.enumerated() { manifiesto += Compresor.lineaDeManifiesto("\(k)", estados[a.ruta]!.modo, a.ruta) }
        guard FileManager.default.createFile(atPath: temporal + "/lote.txt", contents: Data(manifiesto.utf8)) else {
            rmdir(temporal)
            r.fallos.append("No pude preparar la carpeta temporal en \(Formato.rutaCorta(base)).")
            return r
        }

        // 1 y 2. Un clon del original por copia, comprobado y con los datos de la copia.
        struct Preparada {
            let ruta: String
            let clon: String
            let estado: Compresor.EstadoArchivo
            let estadoClon: Compresor.EstadoArchivo
            let privadoAntes: Int64
        }
        var preparadas: [Preparada] = []
        for (k, a) in otros.enumerated() {
            let e = estados[a.ruta]!
            let clon = temporal + "/\(k)"
            // Lo que no se puede cambiar por un clon sin perder algo: otro disco, varios nombres (enlaces duros), de otro
            // dueño, con banderas especiales o en una carpeta de solo lectura.
            guard e.dispositivo == estadoFuente.dispositivo, e.enlaces == 1, e.dueno == getuid(),
                  e.banderas & banderasProhibidas == 0, access(Rutas.padre(a.ruta), W_OK) == 0 else {
                r.fallos.append("\(Formato.rutaCorta(a.ruta)): no se puede cambiar sin perder algo (otro disco, enlaces, permisos o banderas); la dejé como estaba.")
                continue
            }
            let info = Privado.consultar(a.ruta)
            if let i = info, let f = infoFuente, i.clon != 0, i.clon == f.clon {
                r.yaUnidas += 1
                continue
            }
            // Lo que ocupa solo ella (si ya es un clon de otro archivo, su parte compartida no se libera).
            let privadoAntes = e.banderas & UInt32(UF_COMPRESSED) != 0 ? e.ocupa : min(e.ocupa, info?.privado ?? e.ocupa)
            guard clonefile(fuente.ruta, clon, UInt32(CLONE_NOFOLLOW)) == 0 else {
                r.fallos.append("\(Formato.rutaCorta(a.ruta)): no pude clonar el original (\(String(cString: strerror(errno)))); la dejé como estaba.")
                continue
            }
            switch simular?(.clonado, a.ruta) ?? .seguir {
            case .abortar: return r
            case .fallar:
                unlink(clon)
                continue
            case .seguir: break
            }
            guard Compresor.mismoContenido(a.ruta, clon, tamano: e.tamano) else {
                // Si la copia cambió mientras se leía, no es que no fueran iguales.
                if Compresor.EstadoArchivo(ruta: a.ruta)?.sinCambios(desde: e) ?? false {
                    r.fallos.append("\(Formato.rutaCorta(a.ruta)): ya no es idéntica al original; la dejé como estaba.")
                } else {
                    r.cambiaron += 1
                }
                unlink(clon)
                continue
            }
            guard let listo = igualarDatos(de: a.ruta, e, en: clon) else {
                r.fallos.append("\(Formato.rutaCorta(a.ruta)): no pude darle al clon sus permisos, atributos o fechas; la dejé como estaba.")
                unlink(clon)
                continue
            }
            switch simular?(.preparado, a.ruta) ?? .seguir {
            case .abortar: return r
            case .fallar:
                unlink(clon)
                continue
            case .seguir: break
            }
            preparadas.append(Preparada(ruta: a.ruta, clon: clon, estado: e, estadoClon: listo, privadoAntes: privadoAntes))
        }

        // 3. Cambiar cada copia por su clon, si nadie la tiene abierta ni la cambió.
        var carpetas = FechasDeCarpetas()
        var cambiadas: [Preparada] = []
        var devueltos: [Compresor.Devuelta] = []
        let antes = ArchivosAbiertos.ahora()
        if !antes.leidos && !preparadas.isEmpty {
            r.fallos.append("No pude ver qué archivos estaban abiertos; dejé \(preparadas.count == 1 ? "una copia" : "\(preparadas.count) copias") como estaban.")
            for x in preparadas { unlink(x.clon) }
            preparadas = []
        }
        for x in preparadas {
            if antes.hayAbierto(dentroDe: x.ruta) != nil {
                r.abiertas += 1
                unlink(x.clon)
                continue
            }
            guard Compresor.EstadoArchivo(ruta: x.ruta)?.sinCambios(desde: x.estado) ?? false else {
                r.cambiaron += 1
                unlink(x.clon)
                continue
            }
            carpetas.anotar(Rutas.padre(x.ruta))
            // Mientras el intercambio se pueda deshacer, el clon no se deja escribir: lo que alguien escribiera en él justo
            // antes de devolver la copia se quedaría fuera de tu archivo. Recupera sus permisos al terminar.
            guard Compresor.quitarEscritura(x.clon, x.estado.modo) else {
                r.fallos.append("\(Formato.rutaCorta(x.ruta)): no pude preparar su clon (\(String(cString: strerror(errno)))); la dejé como estaba.")
                unlink(x.clon)
                continue
            }
            switch simular?(.antesDeCambiar, x.ruta) ?? .seguir {
            case .abortar: return r
            case .fallar:
                unlink(x.clon)
                continue
            case .seguir: break
            }
            guard renamex_np(x.clon, x.ruta, UInt32(RENAME_SWAP)) == 0 else {
                r.fallos.append("\(Formato.rutaCorta(x.ruta)): no pude cambiarla por el clon (\(String(cString: strerror(errno)))); la dejé como estaba.")
                unlink(x.clon)
                continue
            }
            // Ahora la copia de siempre está en la carpeta temporal y el clon, en su sitio.
            var deshacer = false
            switch simular?(.cambiado, x.ruta) ?? .seguir {
            case .abortar: return r
            case .fallar: deshacer = true
            case .seguir: break
            }
            // Si alguien escribió en la copia justo durante el intercambio, el clon ya no vale.
            if deshacer || !(Compresor.EstadoArchivo(ruta: x.clon)?.mismoContenido(que: x.estado) ?? false) {
                if !deshacer { r.cambiaron += 1 }
                devolver(x.ruta, x.clon, x.estadoClon, &r, &devueltos)
                continue
            }
            cambiadas.append(x)
        }

        // 4. Volver a mirar lo abierto: quien abrió la copia antes del intercambio la sigue teniendo (en la carpeta
        //    temporal). Nadie más puede llegar a ella: su nombre de siempre ya es el clon.
        let despues = ArchivosAbiertos.ahora()
        for x in cambiadas {
            switch simular?(.antesDeBorrar, x.ruta) ?? .seguir {
            case .abortar: return r
            case .fallar:
                devolver(x.ruta, x.clon, x.estadoClon, &r, &devueltos)
                continue
            case .seguir: break
            }
            let enTemporal = temporalReal + x.clon.dropFirst(temporal.count)
            if !despues.leidos || despues.hayAbierto(rutaReal: enTemporal) != nil {
                r.abiertas += 1
                devolver(x.ruta, x.clon, x.estadoClon, &r, &devueltos)
                continue
            }
            guard Compresor.EstadoArchivo(ruta: x.clon)?.mismoContenido(que: x.estado) ?? false else {
                r.cambiaron += 1
                devolver(x.ruta, x.clon, x.estadoClon, &r, &devueltos)
                continue
            }
            guard unlink(x.clon) == 0 else {
                devolver(x.ruta, x.clon, x.estadoClon, &r, &devueltos)
                continue
            }
            // Ya no hay vuelta atrás: el clon, en su sitio, recupera los permisos de la copia.
            if !Compresor.ponerPermisos(x.ruta, inodo: x.estadoClon.inodo, modo: x.estado.modo) {
                r.fallos.append("\(Formato.rutaCorta(x.ruta)): quedó unida, pero no pude devolverle sus permisos (\(String(x.estado.modo & 0o7777, radix: 8))); pónselos desde la Terminal con «chmod \(String(x.estado.modo & 0o7777, radix: 8))».")
            }
            // Lo que ocupa ahora solo ella: casi nada (un clon comprimido, el sistema lo da como 0).
            let ahora = Compresor.EstadoArchivo(ruta: x.ruta)
            let privadoDespues = ahora.map { $0.banderas & UInt32(UF_COMPRESSED) != 0 ? 0 : min($0.ocupa, Privado.consultar(x.ruta)?.privado ?? $0.ocupa) } ?? 0
            r.unidas.append((x.ruta, max(0, x.privadoAntes - privadoDespues)))
        }

        // 5. Los clones de lo que se devolvió a su sitio se borran si nadie los abrió entretanto (por su nombre de
        //    siempre, mientras estuvieron en su sitio) ni cambiaron; si no, se quedan y se avisa la próxima vez.
        if !devueltos.isEmpty {
            let fin = ArchivosAbiertos.ahora()
            for d in devueltos {
                let real = temporalReal + d.ruta.dropFirst(temporal.count)
                let ahora = Compresor.EstadoArchivo(ruta: d.ruta)
                if let ahora, !ahora.mismoContenido(que: d.estado) {
                    // Alguien escribió en el clon mientras estuvo en su sitio: eso no está en tu archivo.
                    r.fallos.append(Compresor.escritoEnElResto(d.original, resto: d.ruta))
                } else if fin.leidos && fin.hayAbierto(rutaReal: real) == nil && ahora != nil {
                    unlink(d.ruta)
                }
            }
        }

        // 6. Quitar la carpeta temporal si quedó vacía (si no, se queda con su manifiesto para recogerla después) y
        //    devolver sus fechas a las carpetas de las copias.
        let quedan = ((try? FileManager.default.contentsOfDirectory(atPath: temporal)) ?? []).filter { $0 != "lote.txt" }
        if quedan.isEmpty {
            unlink(temporal + "/lote.txt")
            rmdir(temporal)
        } else {
            r.fallos.append("Dejé \(quedan.count == 1 ? "un archivo" : "\(quedan.count) archivos") en \(Formato.rutaCorta(temporal)) para no perder nada; la próxima vez que limpie borraré los que estén repetidos.")
        }
        carpetas.restaurar()
        return r
    }

    /// Le pone al clon lo de la copia: permisos, grupo, atributos extendidos (cuarentena, etiquetas…), ACL, banderas y
    /// fechas de creación, modificación y acceso. Devuelve cómo quedó, o nil si algo no se pudo igualar.
    private static func igualarDatos(de copia: String, _ e: Compresor.EstadoArchivo, en clon: String) -> Compresor.EstadoArchivo? {
        // Mientras se le escriben los atributos, el clon tiene que dejarse escribir (puede venir de un original de solo lectura).
        guard chmod(clon, 0o600) == 0 else { return nil }
        guard Compresor.igualarAtributos(de: copia, en: clon), Compresor.igualarACL(de: copia, en: clon) else { return nil }
        guard let c = Compresor.EstadoArchivo(ruta: clon) else { return nil }
        if c.grupo != e.grupo && lchown(clon, uid_t.max, e.grupo) != 0 { return nil }
        guard chmod(clon, e.modo & 0o7777) == 0 else { return nil }
        // La compresión es la del original (el clon comparte sus bloques); el resto de banderas (oculto…), las de la copia.
        let banderas = (e.banderas & ~UInt32(UF_COMPRESSED)) | (c.banderas & UInt32(UF_COMPRESSED))
        if banderas != c.banderas && lchflags(clon, banderas) != 0 { return nil }
        guard Compresor.ponerFechas(clon, e), let f = Compresor.EstadoArchivo(ruta: clon) else { return nil }
        guard f.modo == e.modo, f.dueno == e.dueno, f.grupo == e.grupo, f.tamano == e.tamano,
              f.banderas & ~UInt32(UF_COMPRESSED) == e.banderas & ~UInt32(UF_COMPRESSED),
              f.modificado == e.modificado, f.creado == e.creado else { return nil }
        return f
    }

    /// Deshace el intercambio: la copia de siempre (que está en la carpeta temporal, en `clon`) vuelve a su sitio. Solo si
    /// en su sitio sigue el clon sin cambios: si alguien lo reemplazó o escribió en él, no se toca nada y se avisa (no se
    /// pierde ninguno de los dos). El clon, que queda en la carpeta temporal, se apunta en `devueltos` para borrarlo al
    /// final si nadie lo abrió entretanto.
    private static func devolver(_ ruta: String, _ clon: String, _ estadoClon: Compresor.EstadoArchivo, _ r: inout Resultado,
                                 _ devueltos: inout [Compresor.Devuelta]) {
        guard let enSuSitio = Compresor.EstadoArchivo(ruta: ruta), enSuSitio.mismoContenido(que: estadoClon),
              renamex_np(clon, ruta, UInt32(RENAME_SWAP)) == 0 else {
            r.fallos.append("\(Formato.rutaCorta(ruta)): cambió mientras la unía; guardé la versión anterior en \(Formato.rutaCorta(clon)).")
            return
        }
        devueltos.append(Compresor.Devuelta(ruta: clon, estado: estadoClon, original: ruta))
    }

    /// Hay alguna carpeta de una unión que se cortó: para decir qué se está haciendo mientras se recoge.
    static var puedeHaberRestos: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: carpetaTemporal)) ?? []).contains { UUID(uuidString: $0) != nil }
    }

    /// Si una unión se cortó (la app se cerró de golpe, se colgó o se apagó el Mac), en la carpeta temporal quedan clones
    /// o copias de siempre: en los dos casos su ruta tiene ya el mismo contenido. Se borra cada uno cuya ruta existe, es
    /// otro archivo y tiene el mismo contenido; los demás se dejan donde están y se devuelven, para avisar. Nunca se borra
    /// uno sin comprobarlo. Si se cortó con un clon ya en su sitio y sin permiso de escritura (paso 3), se le devuelven
    /// los permisos de la copia, apuntados en el manifiesto.
    static func recogerRestos() -> [String] {
        var guardadas: [String] = []
        let fm = FileManager.default
        let base = carpetaTemporal
        for n in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where UUID(uuidString: n) != nil {
            let carpeta = base + "/" + n
            var st = stat()
            guard lstat(carpeta, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { continue }
            let manifiesto = Compresor.leerManifiesto(carpeta)
            for m in manifiesto.values { if let modo = m.modo { Compresor.devolverEscritura(m.ruta, modo: modo) } }
            var quedan = 0
            for archivo in (try? fm.contentsOfDirectory(atPath: carpeta)) ?? [] where archivo != "lote.txt" {
                let resto = carpeta + "/" + archivo
                if let ruta = manifiesto[archivo]?.ruta, let e = Compresor.EstadoArchivo(ruta: resto), e.esRegular,
                   let o = Compresor.EstadoArchivo(ruta: ruta), o.esRegular, o.inodo != e.inodo, o.tamano == e.tamano,
                   Compresor.mismoContenido(ruta, resto, tamano: e.tamano) {
                    unlink(resto)
                } else {
                    guardadas.append(resto)
                    quedan += 1
                }
            }
            if quedan == 0 {
                unlink(carpeta + "/lote.txt")
                rmdir(carpeta)
            }
        }
        return guardadas
    }
}
