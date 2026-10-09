import AppKit
import Foundation

struct EstadoAnalisis: Sendable {
    var fraccion: Double
    /// Índice dentro de `Escaner.fases`.
    var fase: Int
    var mensaje: String
    var detalle: String = ""
}

/// Hace el análisis profundo: indexa el disco una vez y cada categoría consulta ese índice.
struct Escaner {
    typealias Progreso = @Sendable (EstadoAnalisis) -> Void
    typealias Entrega = @Sendable ([Elemento]) -> Void

    /// Orden de análisis. «Archivos olvidados» y «Archivos grandes» van al final para no repetir
    /// lo que ya ofrecieron otras categorías. «Comprimir sin borrar», después: no borra nada, así que no les quita nada.
    static let orden: [Categoria] = [.emuladores, .desarrollo, .cachesApps, .sistema, .restos, .apps, .proyectos,
                                     .herramientas, .instaladores, .registros, .papelera, .duplicados, .olvidados, .grandes,
                                     .comprimir]
    static let fases: [String] = ["Apps abiertas", "Índice del disco", "Apps instaladas"] + orden.map(\.titulo)

    private let minimo: Int64 = 1_000_000
    /// Carpetas de la propia app: nunca se ofrecen.
    private static let propios: Set<String> = ["LimpiadorMac", "com.gustavo.LimpiadorMac", "com.gustavo.limpiadormac"]

    @discardableResult
    func ejecutar(progreso: Progreso, entrega: Entrega) -> Indice {
        progreso(EstadoAnalisis(fraccion: 0.01, fase: 0, mensaje: "Viendo qué apps están abiertas…"))
        // Lo que ocupan las Command Line Tools se mide mientras tanto: solo es una nota y du tarda un par de segundos.
        final class Pendientes: @unchecked Sendable {
            var elementos: [Elemento] = []
            var nota: NotaGrande?
        }
        let lineaDeComandos = Pendientes()
        let midiendo = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: midiendo) {
            lineaDeComandos.nota = Self.notaDeLineaDeComandos()
        }
        let procesos = Procesos.capturar()
        let acceso = Seguridad.tieneAccesoTotal()

        let anterior = UserDefaults.standard.double(forKey: "bytesIndiceAnterior")
        let estimado = anterior > 0 ? anterior : Double(InfoDisco.actual().usado) * 0.45
        let indice = Indice.construir(accesoTotal: acceso) { p in
            let f = min(0.98, Double(p.bytes) / max(estimado, 1))
            var detalle = "\(Formato.numero(p.archivos)) archivos · \(Formato.bytes(p.bytes))"
            if !p.ruta.isEmpty { detalle += " · \(Formato.rutaCorta(p.ruta))" }
            progreso(EstadoAnalisis(fraccion: 0.03 + 0.6 * f, fase: 1, mensaje: "Indexando tu disco…", detalle: detalle))
        }
        UserDefaults.standard.set(Double(indice.bytesTotales), forKey: "bytesIndiceAnterior")

        progreso(EstadoAnalisis(fraccion: 0.64, fase: 2, mensaje: "Reconociendo tus apps y herramientas…",
                                detalle: "\(Formato.numero(indice.archivosTotales)) archivos indexados"))
        let apps = AppsInstaladas.cargar(appsExtra: indice.apps.filter { !$0.hasPrefix("/Users/Shared/") })
        let c = Contexto(indice: indice, apps: apps, procesos: procesos, accesoTotal: acceso)

        // Lo que se puede comprimir se busca mientras tanto, en segundo plano: lee una muestra de miles de archivos y no
        // depende de las demás categorías (no borra nada, así que no les quita nada ni ellas a él).
        let compresibles = Pendientes()
        let buscandoCompresibles = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: buscandoCompresibles) {
            compresibles.elementos = self.generar(.comprimir, c, ofrecidas: [])
        }

        var ofrecidas: [String] = []
        // Lo que ya se ofrece borrar como Seguro (cachés, transformaciones de Gradle, intermedios…): no se une con sus
        // copias, porque borrarlo libera más.
        var seguras: [String] = []
        for (i, categoria) in Self.orden.enumerated() {
            progreso(EstadoAnalisis(fraccion: 0.66 + 0.34 * Double(i) / Double(Self.orden.count), fase: 3 + i,
                                    mensaje: categoria == .comprimir ? "Viendo qué se puede comprimir sin borrar…"
                                                                     : "Revisando \(categoria.titulo.lowercased())…",
                                    detalle: "\(Formato.numero(indice.archivosTotales)) archivos indexados"))
            var elementos: [Elemento]
            if categoria == .comprimir {
                buscandoCompresibles.wait()
                // Tu material grande (informes, entregas) se busca ahora: depende de lo que las demás categorías ya
                // ofrecen borrar como Seguro.
                elementos = compresibles.elementos + materialPropio(c, seguras: seguras)
            } else {
                elementos = generar(categoria, c, ofrecidas: ofrecidas, seguras: seguras)
            }
            for j in elementos.indices {
                medir(&elementos[j], c)
                Evaluador.evaluar(&elementos[j], c)
                // Lo que no es Seguro nunca se marca solo, en ningún modo; lo que cuesta descargas o esperas
                // (nivel .maximo y siguientes) no se marca en el modo normal, pero queda `marcable` para «Liberar al
                // máximo» si quien lo encontró lo habría marcado.
                if elementos[j].riesgo != .seguro {
                    elementos[j].nivel = .nunca
                    elementos[j].marcable = false
                    // Quien lo encontró pudo prometer marcarlo más adelante antes de que el Evaluador subiera su riesgo.
                    elementos[j].motivos = Self.sinPromesas(elementos[j].motivos)
                }
                // Un aviso que no sea de uso (lo ponga quien lo encontró, como «Compilado hace poco», o el Evaluador) pide
                // mirarlo antes: no se marca solo en ningún modo, igual que con «Seleccionar lo recomendado». Los de uso se
                // vuelven a mirar al limpiar (`Elemento.comprobarUso`).
                if !elementos[j].soloAvisosDeUso {
                    elementos[j].seleccionado = false
                    elementos[j].marcable = false
                }
                if elementos[j].nivel != .normal { elementos[j].seleccionado = false }
                elementos[j].recomendado = elementos[j].seleccionado
            }
            // Lo pequeño no se ofrece, salvo lo que queda de un proyecto con algo valioso dentro (una llave en build/…):
            // al separar sus intermedios puede quedar en poco espacio, y su aviso tiene que seguir viéndose.
            elementos = elementos.filter { $0.tamano >= minimo || ($0.categoria == .proyectos && $0.riesgo == .cuidado) }
                .sorted { $0.tamano > $1.tamano }
            // Lo que no borra nada (unir copias) no se cuenta como ya ofrecido: «Archivos grandes» puede seguir
            // ofreciendo borrar esos archivos.
            ofrecidas += elementos.filter { !$0.accion.noBorraNada }.flatMap { $0.rutas.map(\.path) }
            seguras += elementos.filter { $0.accion == .borrar && $0.riesgo == .seguro }.flatMap { $0.rutas.map(\.path) }
            entrega(elementos)
        }
        midiendo.wait()
        if let nota = lineaDeComandos.nota { indice.notas.append(nota) }
        progreso(EstadoAnalisis(fraccion: 1, fase: Self.fases.count, mensaje: "Análisis terminado",
                                detalle: "\(Formato.numero(indice.archivosTotales)) archivos revisados"))
        return indice
    }

    /// Lo que no es Seguro no se marca nunca, en ningún modo: sin las frases con las que quien lo encontró prometía
    /// marcarlo más adelante («Lo marco cuando lleve 24 h…», ««Liberar al máximo» ya lo incluye…») ni la nota «Solo en
    /// «Liberar al máximo»». Lo demás del motivo (cuándo se usó, por qué) se queda.
    static func sinPromesas(_ motivos: [Motivo]) -> [Motivo] {
        let cortes = [" Lo marco cuando ", ": lo marco solo cuando ", ": las marco solas cuando ", "; «Liberar al máximo» ya l",
                      ". «Liberar al máximo» ya l", ". «Liberar al máximo» lo incluye"]
        return motivos.compactMap { m in
            guard m.etiqueta != "Solo en «Liberar al máximo»" else { return nil }
            var r = m
            for corte in cortes {
                guard let rango = r.texto.range(of: corte) else { continue }
                r.texto = String(r.texto[..<rango.lowerBound])
                while let ultima = r.texto.last, ".:;".contains(ultima) { r.texto.removeLast() }
                r.texto += "."
            }
            return r
        }
    }

    private func generar(_ categoria: Categoria, _ c: Contexto, ofrecidas: [String], seguras: [String] = []) -> [Elemento] {
        let elementos: [Elemento]
        switch categoria {
        case .emuladores: elementos = emuladores(c)
        case .desarrollo: elementos = desarrollo(c)
        case .cachesApps: elementos = cachesApps(c)
        case .sistema: elementos = sistema(c)
        case .restos: elementos = restos(c)
        case .apps: elementos = apps(c)
        case .proyectos: elementos = proyectos(c)
        case .herramientas: elementos = herramientas(c)
        case .instaladores: elementos = instaladores(c)
        case .registros: elementos = registros(c)
        case .papelera: elementos = papelera()
        case .duplicados: elementos = duplicados(c, seguras: seguras)
        case .olvidados: elementos = olvidados(c, ofrecidas: ofrecidas) + copiasDeICloud(c)
        case .grandes: elementos = grandes(c, ofrecidas: ofrecidas)
        case .comprimir: elementos = compresibles(c)
        }
        // Las rutas protegidas nunca se ofrecen, aunque alguna regla las haya encontrado.
        return elementos.compactMap { el in
            var e = el
            switch el.accion {
            case .borrar: e.rutas = el.rutas.filter(Seguridad.sePuedeBorrar)
            case .comprimir(let compresion): e.rutas = el.rutas.filter { Seguridad.sePuedeModificar($0, apps: compresion.apps) }
            default: return el
            }
            return e.rutas.isEmpty ? nil : e
        }
    }

    private func medir(_ el: inout Elemento, _ c: Contexto) {
        if let fijo = el.tamanoFijo {
            el.tamano = fijo
            el.tamanosRutas = el.rutas.map { _ in 0 }
        } else if !el.rutas.isEmpty && el.tamanosRutas.count == el.rutas.count {
            el.tamano = el.tamanosRutas.reduce(0, +)   // ya se midió al encontrarlo
        } else {
            el.tamanosRutas = el.rutas.map { c.indice.bytes(de: $0) }
            el.tamano = el.tamanosRutas.reduce(0, +)
        }
        // Lo que se libera de verdad: sin lo que comparte con clones que se quedan (solo lo que se borra por rutas).
        if el.accion == .borrar && el.tamanoFijo == nil {
            let l = c.indice.liberables(de: el.rutas, asignados: el.tamanosRutas)
            el.liberablesRutas = l.porRuta
            el.liberable = l.porRuta.reduce(0, +)
            el.retenido = l.retenido
        }
        if el.ultimoUso == nil { el.ultimoUso = c.indice.masReciente(de: el.rutas) }
    }

    // MARK: - Emuladores y simuladores

    private func emuladores(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        let avdDir = Rutas.enHome(".android/avd")
        var usoImagenes: [String: [String]] = [:]

        for avd in Rutas.hijos(avdDir) where avd.pathExtension == "avd" {
            let base = avd.deletingPathExtension().lastPathComponent
            let config = (try? String(contentsOf: avd.appendingPathComponent("config.ini"), encoding: .utf8)) ?? ""
            var nombre = base.replacingOccurrences(of: "_", with: " ")
            var imagenes: [String] = []
            for linea in config.split(separator: "\n") {
                let kv = linea.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                if kv[0] == "avd.ini.displayname" { nombre = kv[1] }
                if kv[0].hasPrefix("image.sysdir") { imagenes.append(kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
            }
            for img in imagenes { usoImagenes[img, default: []].append(nombre) }
            // Encendido: un proceso con «-avd», un programa con algo abierto en su carpeta o un candado de un proceso vivo.
            let uso = EnUso.emulador(avd: base, carpeta: avd.path)
            let ini = avdDir.appendingPathComponent(base + ".ini")

            r.append(Elemento(
                nombre: "Emulador Android: \(nombre)",
                detalle: "El emulador completo: su sistema, las apps que instalaste y sus datos.",
                consecuencia: "Desaparece de Android Studio. Puedes crear otro en Device Manager, pero empezará vacío.",
                rutas: Rutas.existe(ini) ? [avd, ini] : [avd],
                categoria: .emuladores, riesgo: .revisar,
                motivos: [.info("lightbulb.fill", "Hay una alternativa",
                                "Si solo necesitas espacio, «Restablecer \(nombre)» libera casi lo mismo y conserva el emulador.")],
                enUso: uso, dueno: "Android Studio"))

            // Datos internos: lo mismo que borra «Wipe Data» en Android Studio.
            let prefijos = ["userdata-qemu.img", "cache.img", "encryptionkey.img"]
            var datos = Rutas.hijos(avd).filter { u in
                let n = u.lastPathComponent
                return prefijos.contains { n.hasPrefix($0) } && !n.hasSuffix(".lock")
            }
            let snaps = avd.appendingPathComponent("snapshots")
            if Rutas.existe(snaps) { datos.append(snaps) }
            if !datos.isEmpty {
                r.append(Elemento(
                    nombre: "Restablecer \(nombre)",
                    detalle: "Lo que hay dentro del emulador: apps instaladas, cuentas, fotos y archivos.",
                    consecuencia: "Es lo mismo que «Wipe Data» en Android Studio: el emulador sigue ahí y arranca como recién creado.",
                    rutas: datos, categoria: .emuladores, riesgo: .revisar,
                    motivos: [.bien("arrow.counterclockwise", "Conserva el emulador",
                                    "El emulador no se elimina: solo vuelve a su estado de fábrica. No hay que configurarlo otra vez.")],
                    enUso: uso, dueno: "Android Studio"))
            }
            // El arranque rápido (Quick Boot) es una foto de la memoria del emulador al cerrarse: se vuelve a crear sola.
            // Los demás snapshots los guardaste tú a propósito, para volver a ese estado.
            let rapido = snaps.appendingPathComponent("default_boot")
            if Rutas.esCarpeta(rapido) {
                r.append(Elemento(
                    nombre: "Arranque rápido de \(nombre)",
                    detalle: "La foto de la memoria del emulador que guarda Quick Boot al cerrarlo, para que la próxima vez arranque en segundos.",
                    consecuencia: "La próxima vez el emulador arranca en frío (uno o dos minutos más). Las apps y los datos del emulador no se tocan. Si tienes activado Quick Boot, el emulador la vuelve a guardar al cerrarse y ocupará lo mismo otra vez.",
                    rutas: [rapido], categoria: .emuladores, riesgo: .seguro, seleccionado: true,
                    motivos: [.bien("bolt.fill", "Sin pérdida",
                                    "Solo se pierde el arranque rápido: lo que tiene el emulador (apps, cuentas, archivos) está en sus datos, que no se tocan."),
                              .info("arrow.clockwise", "Vuelve a crecer",
                                    "Con Quick Boot activado, el emulador la guarda otra vez al cerrarse. Si no quieres que vuelva a ocupar espacio: Device Manager › editar el emulador › Boot option › Cold boot.")],
                    enUso: uso, dueno: "Android Studio", costes: [.arranqueEnFrio]))
            }
            let guardados = Rutas.hijos(snaps).filter { $0.lastPathComponent != "default_boot" && $0.lastPathComponent != ".DS_Store" }
            if !guardados.isEmpty {
                let nombres = guardados.map(\.lastPathComponent).sorted()
                r.append(Elemento(
                    nombre: "Snapshots guardados de \(nombre)",
                    detalle: "Estados del emulador que guardaste a propósito para volver a ellos: \(Formato.listaCorta(nombres)).",
                    consecuencia: "Ya no podrás volver a \(nombres.count == 1 ? "ese estado" : "esos estados"). El emulador, sus datos y su arranque rápido no se tocan.",
                    rutas: guardados, categoria: .emuladores, riesgo: .revisar,
                    motivos: [.info("camera.fill", "Guardados por ti",
                                    "No los crea el emulador solo: los guardaste desde Extended Controls › Snapshots. Bórralos si ya no necesitas volver a ellos.")],
                    enUso: uso, dueno: "Android Studio"))
            }
        }

        // Emuladores que viven en otras carpetas (pruebas aisladas, dispositivos de Gradle): se muestran aparte para que
        // decidas tú (nunca se marcan), y las imágenes del sistema que usan no se tocan.
        for ruta in c.indice.avds where Rutas.padre(ruta) != avdDir.path {
            let config = (try? String(contentsOfFile: ruta + "/config.ini", encoding: .utf8)) ?? ""
            let nombre = Rutas.nombre(ruta).replacingOccurrences(of: ".avd", with: "")
            for linea in config.split(separator: "\n") {
                let kv = linea.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, kv[0].hasPrefix("image.sysdir") {
                    usoImagenes[kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "/")), default: []].append("el emulador de pruebas «\(nombre)»")
                }
            }
            r.append(emuladorAislado(ruta, nombre: nombre))
        }

        // Imágenes del sistema: sdk/system-images/android-XX/<tipo>/<abi>
        let sdk = sdkAndroid(c)
        for version in Rutas.hijos(sdk.appendingPathComponent("system-images")) where Rutas.esCarpeta(version) {
            for tipo in Rutas.hijos(version) where Rutas.esCarpeta(tipo) {
                for abi in Rutas.hijos(tipo) where Rutas.esCarpeta(abi) {
                    let rel = "system-images/\(version.lastPathComponent)/\(tipo.lastPathComponent)/\(abi.lastPathComponent)"
                    let usan = usoImagenes[rel] ?? []
                    let v = version.lastPathComponent.replacingOccurrences(of: "android-", with: "")
                    let nombre = "Imagen de Android \(v) (\(tipo.lastPathComponent.replacingOccurrences(of: "_", with: " ")))"
                    if usan.isEmpty {
                        r.append(Elemento(
                            nombre: nombre,
                            detalle: "Sistema Android que se descargó para crear emuladores.",
                            consecuencia: "Si algún día creas un emulador con esta versión, Android Studio la vuelve a descargar.",
                            rutas: [abi], categoria: .emuladores, riesgo: .seguro, seleccionado: true,
                            motivos: [.bien("checkmark.circle.fill", "Sin usar", "Ningún emulador la usa.")],
                            dueno: "Android Studio"))
                    } else {
                        r.append(Elemento(
                            nombre: nombre,
                            detalle: "Sistema Android sobre el que funcionan tus emuladores.",
                            consecuencia: "\(Formato.lista(usan)) dejaría de arrancar hasta que la vuelvas a descargar.",
                            rutas: [abi], categoria: .emuladores, riesgo: .cuidado,
                            motivos: [.peligro("iphone.gen3", usan.count == 1 ? "La usa \(usan[0])" : "La usan \(usan.count) emuladores",
                                               "La usa \(Formato.lista(usan)). Si la borras, ese emulador deja de funcionar.")],
                            dueno: "Android Studio"))
                    }
                }
            }
        }

        // Versiones antiguas del SDK (se conserva la más nueva).
        // Qué build-tools usan los proyectos: solo se mira si hay alguna versión antigua.
        var buildTools: (porVersion: [String: [String]], sinSaber: [String])?
        for (carpeta, nombre, detalle) in [("build-tools", "Android build-tools", "Herramientas de compilación de Android."),
                                           ("ndk", "Android NDK", "Kit para compilar código nativo (C/C++)."),
                                           ("cmake", "CMake de Android", "Herramienta que usa el NDK para compilar código nativo.")] {
            let versiones = Rutas.hijos(sdk.appendingPathComponent(carpeta)).filter { Rutas.esCarpeta($0) }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            for v in versiones.dropLast() {
                if carpeta == "build-tools" {
                    let usadas = buildTools ?? buildToolsUsadas(c)
                    buildTools = usadas
                    r.append(buildToolsAntigua(v, ultima: versiones.last!.lastPathComponent, usadas: usadas, c))
                    continue
                }
                r.append(Elemento(
                    nombre: "\(nombre) \(v.lastPathComponent) (versión antigua)",
                    detalle: detalle,
                    consecuencia: "Si algún proyecto pide esta versión exacta, Gradle la vuelve a descargar.",
                    rutas: [v], categoria: .emuladores, riesgo: .seguro, seleccionado: true,
                    motivos: [.bien("clock.arrow.circlepath", "Hay una más nueva", "Ya tienes la versión \(versiones.last!.lastPathComponent).")],
                    dueno: "Android Studio"))
            }
        }
        // Plataformas (las librerías de cada versión de Android): sobran las que no usa ningún proyecto.
        let (usadas, desconocido) = sdksUsados(c)
        let plataformas = Rutas.hijos(sdk.appendingPathComponent("platforms")).filter { Rutas.esCarpeta($0) }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        for p in plataformas.dropLast() {
            let v = p.lastPathComponent.replacingOccurrences(of: "android-", with: "")
            // «34-ext10» y «37.0» son el nivel 34 y 37.
            if usadas.contains(String(v.prefix { $0.isNumber })) { continue }
            r.append(Elemento(
                nombre: "Plataforma de Android \(v) (SDK)",
                detalle: "Las librerías de Android \(v) para compilar apps.",
                consecuencia: "Si algún proyecto vuelve a compilar para Android \(v), Android Studio la descarga otra vez.",
                // Si algún proyecto saca su versión de una variable (Flutter, catálogos), no sé cuál usa: nada se marca solo.
                rutas: [p], categoria: .emuladores, riesgo: .seguro, seleccionado: !usadas.isEmpty && !desconocido,
                motivos: [.bien("checkmark.circle.fill", "Ningún proyecto la usa", usadas.isEmpty
                    ? "No encontré ningún proyecto de Android que compile para Android \(v). Ya tienes la \(plataformas.last!.lastPathComponent.replacingOccurrences(of: "android-", with: ""))."
                    : "Tus proyectos compilan para Android \(Formato.lista(usadas.sorted { $0.compare($1, options: .numeric) == .orderedAscending }))."),
                ],
                dueno: "Android Studio"))
        }
        let androidStudio = EnUso.app(nombre: "Android Studio", claves: ["com.google.android.studio"])
        // Paquetes del SDK que se quedaron a medio descargar o instalar.
        let aMedias = [".temp", ".downloadIntermediates"].map { sdk.appendingPathComponent($0) }.filter(Rutas.existe)
        if !aMedias.isEmpty {
            r.append(Elemento(
                nombre: "Descargas a medias del SDK de Android",
                detalle: "Paquetes del SDK que Android Studio estaba descargando o instalando.",
                consecuencia: "Nada: si una instalación quedó a medias, Android Studio la vuelve a descargar.",
                rutas: aMedias, categoria: .emuladores, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("arrow.down.circle.dotted", "Temporal", "Son restos de descargas, no herramientas instaladas.")],
                enUso: androidStudio, dueno: "Android Studio"))
        }
        // Herramientas que Google sustituyó por otras.
        for (carpeta, nombre, detalle) in [("ndk-bundle", "NDK antiguo (ndk-bundle)", "La forma antigua de instalar el NDK: ahora cada versión va en su propia carpeta dentro de «ndk»."),
                                           ("tools", "SDK Tools (obsoletas)", "Herramientas antiguas del SDK que Google sustituyó por «cmdline-tools».")] {
            let u = sdk.appendingPathComponent(carpeta)
            guard Rutas.esCarpeta(u) else { continue }
            r.append(Elemento(
                nombre: nombre, detalle: detalle,
                consecuencia: "Solo las piden proyectos muy antiguos; si alguno las necesita, se instalan otra vez desde el SDK Manager.",
                rutas: [u], categoria: .emuladores, riesgo: .revisar,
                motivos: [.info("clock.arrow.circlepath", "Obsoleto", "Google ya no lo actualiza.")],
                enUso: androidStudio, dueno: "Android Studio"))
        }
        // cmdline-tools: «latest» más las versiones que se quedaron al actualizar.
        if Rutas.existe(sdk.appendingPathComponent("cmdline-tools/latest")) {
            for v in Rutas.hijos(sdk.appendingPathComponent("cmdline-tools"))
            where v.lastPathComponent != "latest" && Rutas.esCarpeta(v) && Self.pareceVersion(v.lastPathComponent) {
                r.append(Elemento(
                    nombre: "Android cmdline-tools \(v.lastPathComponent) (versión antigua)",
                    detalle: "Herramientas de línea de comandos del SDK de Android.",
                    consecuencia: "Nada: Android Studio usa la versión «latest».",
                    rutas: [v], categoria: .emuladores, riesgo: .seguro, seleccionado: true,
                    motivos: [.bien("clock.arrow.circlepath", "Hay una más nueva", "Ya tienes la versión «latest».")],
                    enUso: androidStudio, dueno: "Android Studio"))
            }
        }
        for fuente in Rutas.hijos(sdk.appendingPathComponent("sources")) where Rutas.esCarpeta(fuente) {
            r.append(Elemento(
                nombre: "Código fuente de Android \(fuente.lastPathComponent.replacingOccurrences(of: "android-", with: ""))",
                detalle: "Código de Android para consultarlo desde el editor.",
                consecuencia: "Al abrir una clase de Android verás código descompilado en vez del original. Se puede volver a descargar.",
                // No se pierde nada (se vuelve a descargar), pero cuesta internet: solo «Liberar al máximo».
                rutas: [fuente], categoria: .emuladores, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("book.closed.fill", "Solo consulta", "No se usa para compilar."),
                          .info("arrow.down.circle.fill", "Se vuelve a descargar",
                                "Desde el SDK Manager de Android Studio. Por eso no lo marco solo: solo con «Liberar al máximo».")],
                dueno: "Android Studio", nivel: .maximo, costes: [.descarga(bytes: c.indice.bytes(de: fuente))]))
        }

        r += simuladoresIOS()
        return r
    }

    /// Los emuladores que no están en ~/.android/avd (los crean scripts de prueba o Gradle con su propia carpeta), con
    /// su .ini al lado si lo tienen. Para `proyectos`, que no los incluye en el elemento del proyecto.
    private static func emuladoresAislados(_ c: Contexto) -> [String] {
        let avdDir = Rutas.enHome(".android/avd").path
        return c.indice.avds.filter { Rutas.padre($0) != avdDir }.flatMap { avd -> [String] in
            let ini = Rutas.padre(avd) + "/" + Rutas.nombre(avd).replacingOccurrences(of: ".avd", with: "") + ".ini"
            return Rutas.existe(ini) ? [avd, ini] : [avd]
        }
    }

    /// Un emulador de prueba aislado: lo creó un script de pruebas o Gradle fuera de Device Manager. No se regenera
    /// solo (el script lo vuelve a crear, pero vacío), así que se muestra para revisar y nunca se marca solo.
    private func emuladorAislado(_ ruta: String, nombre: String) -> Elemento {
        let padre = Rutas.padre(ruta)
        let ini = padre + "/" + nombre + ".ini"
        // El .pid que deja el script que lo arrancó (en su carpeta o hasta dos niveles más arriba).
        var pids: [String] = []
        for carpeta in [ruta, padre, Rutas.padre(padre)] {
            pids += ((try? FileManager.default.contentsOfDirectory(atPath: carpeta)) ?? []).filter { $0.hasSuffix(".pid") }
                .map { carpeta + "/" + $0 }
        }
        var motivos: [Motivo] = [.info("testtube.2", "Emulador de prueba",
            "No está en Device Manager: lo creó un script de pruebas o Gradle en \(Formato.rutaCorta(padre)). Dentro están sus datos (las apps instaladas y el estado en que quedó la prueba).")]
        if let vivo = pids.lazy.compactMap({ Procesos.numeroVivo(enArchivo: $0) }).first {
            motivos.append(.aviso("play.circle.fill", "Su prueba sigue viva",
                "El proceso \(vivo), que guardó su número al lado, sigue funcionando: puede que la prueba esté en marcha. Espera a que termine."))
        } else if !pids.isEmpty {
            motivos.append(.bien("stop.circle.fill", "Prueba terminada",
                "Su .pid (\(Formato.listaCorta(pids.map { Rutas.nombre($0) }))) apunta a un proceso que ya no existe: la prueba que lo usaba terminó."))
        }
        return Elemento(
            nombre: "Emulador de prueba: \(nombre.replacingOccurrences(of: "_", with: " "))",
            detalle: "Emulador de Android que creó una prueba en \(Formato.rutaCorta(padre)), fuera de Android Studio.",
            consecuencia: "Se borra el emulador con todo lo que tiene dentro (sus datos y el estado de la prueba). Si el script de pruebas lo vuelve a necesitar, lo crea otra vez, vacío. Va a la Papelera: puedes recuperarlo antes de vaciarla.",
            rutas: Rutas.existe(ini) ? [URL(fileURLWithPath: ruta), URL(fileURLWithPath: ini)] : [URL(fileURLWithPath: ruta)],
            categoria: .emuladores, riesgo: .revisar, motivos: motivos,
            // Encendido: un proceso con «-avd», un candado de un proceso vivo o un programa con algo abierto dentro.
            enUso: .emulador(avd: nombre, carpeta: ruta), dueno: "Pruebas de Android")
    }

    private func simuladoresIOS() -> [Elemento] {
        var r: [Elemento] = []
        let iso = ISO8601DateFormatter()
        // Cuántos simuladores usa cada sistema iOS y cuándo se usó el último.
        var simuladores: [String: (cantidad: Int, ultimo: Date?)] = [:]

        let json = Shell.ejecutar("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], limite: 30).salida
        if let datos = json.data(using: .utf8),
           let raiz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
           let porRuntime = raiz["devices"] as? [String: [[String: Any]]] {
            for (runtime, dispositivos) in porRuntime {
                for d in dispositivos where (d["isAvailable"] as? Bool) ?? true {
                    let uso = (d["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }
                    let antes = simuladores[runtime]
                    simuladores[runtime] = ((antes?.cantidad ?? 0) + 1, [antes?.ultimo, uso].compactMap { $0 }.max())
                }
                // «iOS-27-0» → «iOS 27.0»
                let sufijo = runtime.components(separatedBy: "SimRuntime.").last ?? runtime
                let trozos = sufijo.split(separator: "-")
                let version = trozos.count > 1 ? String(trozos[0]) + " " + trozos.dropFirst().joined(separator: ".") : sufijo
                for d in dispositivos {
                    guard let udid = d["udid"] as? String, let nombre = d["name"] as? String,
                          let dataPath = d["dataPath"] as? String else { continue }
                    let disponible = d["isAvailable"] as? Bool ?? true
                    let ultimo = (d["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }
                    let apps = Rutas.hijos(URL(fileURLWithPath: dataPath + "/Containers/Bundle/Application"))
                    if disponible && ultimo == nil && apps.isEmpty {
                        // Vaciarlo no libera nada: solo tiene el contenido de ejemplo de serie, y se vuelve a crear igual.
                        r.append(Elemento(
                            nombre: "Simulador sin usar: \(nombre) (\(version))",
                            detalle: "Simulador de \(nombre) con \(version) que nunca has encendido. Solo tiene las fotos y contactos de ejemplo de serie.",
                            consecuencia: "Desaparece de la lista de dispositivos de Xcode; puedes volver a crearlo cuando quieras.",
                            rutas: [URL(fileURLWithPath: dataPath).deletingLastPathComponent()],
                            categoria: .emuladores, riesgo: .revisar, accion: .eliminarSimulador(udid: udid),
                            motivos: [.info("moon.zzz.fill", "Nunca encendido", "Vaciarlo no liberaría nada: está igual que recién creado.")],
                            enUso: .simulador(udid: udid), dueno: "Xcode"))
                    } else if disponible {
                        r.append(Elemento(
                            nombre: "Simulador iOS: \(nombre) (\(version))",
                            detalle: "Apps y datos que instalaste en este simulador.",
                            consecuencia: "El simulador sigue en Xcode, pero vacío, como recién creado.",
                            rutas: [URL(fileURLWithPath: dataPath)], ultimoUso: ultimo,
                            categoria: .emuladores, riesgo: apps.isEmpty ? .revisar : .cuidado, accion: .vaciarSimulador(udid: udid),
                            motivos: [apps.isEmpty
                                ? .bien("arrow.counterclockwise", "Conserva el simulador", "Solo se borra su contenido.")
                                : .aviso("app.fill", "Tiene apps instaladas",
                                         "Tiene \(apps.count) \(apps.count == 1 ? "app instalada" : "apps instaladas") con sus datos: se borran todas.")],
                            enUso: .simulador(udid: udid), dueno: "Xcode"))
                    } else {
                        // No funciona sin su sistema, pero sus datos siguen ahí: si vuelves a instalar esa versión de iOS,
                        // el simulador vuelve con sus apps. Y simctl lo borra sin pasar por la Papelera.
                        var motivos: [Motivo] = [.info("xmark.circle.fill", "Sin sistema",
                                                       "Su versión de iOS ya no está en este Mac: no se puede usar hasta que la vuelvas a descargar.")]
                        if !apps.isEmpty {
                            motivos.append(.aviso("app.fill", "Tiene apps instaladas",
                                                  "Tiene \(apps.count) \(apps.count == 1 ? "app instalada" : "apps instaladas") con sus datos: se borran para siempre, sin pasar por la Papelera."))
                        }
                        r.append(Elemento(
                            nombre: "Simulador sin sistema: \(nombre)",
                            detalle: "Su versión de iOS ya no está instalada, así que ahora no se puede usar.",
                            consecuencia: apps.isEmpty
                                ? "Desaparece de Xcode, sin pasar por la Papelera. Si vuelves a descargar su versión de iOS, puedes crear otro igual."
                                : "Se borran para siempre, sin pasar por la Papelera, sus \(apps.count) \(apps.count == 1 ? "app" : "apps") de prueba con sus datos. Si no lo borras y vuelves a descargar su versión de iOS, el simulador vuelve tal como estaba.",
                            rutas: [URL(fileURLWithPath: dataPath).deletingLastPathComponent()], ultimoUso: ultimo,
                            categoria: .emuladores, riesgo: apps.isEmpty ? .revisar : .cuidado,
                            accion: .eliminarSimulador(udid: udid),
                            motivos: motivos, dueno: "Xcode"))
                    }
                }
            }
        }

        // Sistemas iOS descargados para los simuladores. Ocupan varios GB cada uno: se ofrecen todos,
        // y cuanto más reciente es su uso, más cuidado.
        let runtimes = Shell.ejecutar("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], limite: 30).salida
        if let datos = runtimes.data(using: .utf8),
           let lista = try? JSONSerialization.jsonObject(with: datos) as? [String: [String: Any]] {
            // Los que Xcode marca como inutilizables se quitan todos juntos con su comando oficial.
            let inutilizables = Self.runtimesInutilizables(lista)
            if !inutilizables.isEmpty {
                let versiones = inutilizables.map { "iOS \($0.version)" }
                r.append(Elemento(
                    nombre: "Sistemas iOS inutilizables para simuladores",
                    detalle: "Xcode marca como inutilizables (dañados o incompletos) estos sistemas para simuladores: \(Formato.listaCorta(versiones)).",
                    consecuencia: "Lo hace Xcode con su comando oficial «xcrun simctl runtime delete --unusable», que solo quita los que él mismo marca como inutilizables. Ningún simulador puede arrancar con ellos; si necesitas esa versión de iOS, Xcode la vuelve a descargar desde Ajustes › Componentes. No pasa por la Papelera.",
                    rutas: inutilizables.map { URL(fileURLWithPath: $0.ruta) }, tamanoFijo: inutilizables.reduce(Int64(0)) { $0 + $1.tamano },
                    categoria: .emuladores, riesgo: .seguro, seleccionado: true,
                    accion: .comando(programa: "/usr/bin/xcrun", argumentos: ["simctl", "runtime", "delete", "--unusable"], entorno: [:], limite: 300),
                    motivos: [.bien("xmark.octagon.fill", "Inutilizables",
                                    "Xcode los marca como inutilizables: no sirven para ningún simulador. Lo decide su comando oficial.")],
                    enUso: .app(nombre: "Xcode", claves: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]), dueno: "Xcode"))
            }
            let ids = Set(inutilizables.map(\.id))
            for (id, info) in lista where !ids.contains(id) {
                guard let identificador = info["runtimeIdentifier"] as? String, (info["deletable"] as? Bool) == true else { continue }
                let version = info["version"] as? String ?? "?"
                let tamano = (info["sizeBytes"] as? NSNumber)?.int64Value ?? 0
                let ruta = info["path"] as? String ?? "/Library/Developer/CoreSimulator"
                let usoDelSistema = (info["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }
                let suyos = simuladores[identificador]
                let ultimo = [usoDelSistema, suyos?.ultimo].compactMap { $0 }.max()
                let dias = ultimo.map { Date().timeIntervalSince($0) / 86400 }
                let riesgo: Riesgo
                let motivo: Motivo
                if let suyos {
                    let cuantos = suyos.cantidad == 1 ? "un simulador" : "\(suyos.cantidad) simuladores"
                    if let dias, dias < 30 {
                        riesgo = .cuidado
                        motivo = .aviso("iphone", "Lo usaste hace poco",
                                        "Lo usaste \(Formato.haceCuanto(ultimo).lowercased()) (tienes \(cuantos) con iOS \(version)). Si sigues haciendo apps para iPhone, déjalo.")
                    } else {
                        riesgo = .revisar
                        motivo = .info("moon.zzz.fill", ultimo == nil ? "Nunca usado" : "Sin usar",
                                       "Tienes \(cuantos) con iOS \(version), pero " + (ultimo == nil ? "ninguno se ha encendido nunca."
                                           : "el último uso fue \(Formato.haceCuanto(ultimo).lowercased())."))
                    }
                } else {
                    riesgo = .seguro
                    motivo = .bien("checkmark.circle.fill", "Ningún simulador lo usa",
                                   "Ninguno de tus simuladores usa iOS \(version): todos están en otras versiones.")
                }
                r.append(Elemento(
                    nombre: "iOS \(version) para simuladores",
                    detalle: "Sistema iOS \(version) que Xcode descargó para los simuladores.",
                    consecuencia: (suyos == nil ? "" : "Tus simuladores de iOS \(version) dejarán de funcionar hasta que lo vuelvas a descargar. ")
                        + "Xcode lo descarga otra vez desde Ajustes › Componentes (\(Formato.bytes(tamano))).",
                    rutas: [URL(fileURLWithPath: ruta)], tamanoFijo: tamano, ultimoUso: ultimo,
                    categoria: .emuladores, riesgo: riesgo, seleccionado: suyos == nil, accion: .eliminarRuntime(id: id),
                    motivos: [motivo], enUso: .app(nombre: "Xcode", claves: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]),
                    dueno: "Xcode"))
            }
        }
        return r
    }

    /// Los sistemas para simuladores que Xcode marca como inutilizables (su «state» es «Unusable»), de la lista de
    /// «xcrun simctl runtime list -j»: lo que quitaría «xcrun simctl runtime delete --unusable».
    static func runtimesInutilizables(_ lista: [String: [String: Any]]) -> [(id: String, version: String, tamano: Int64, ruta: String)] {
        lista.compactMap { id, info in
            guard (info["state"] as? String)?.lowercased().contains("unusable") == true else { return nil }
            return (id, info["version"] as? String ?? "?", (info["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                    info["path"] as? String ?? "/Library/Developer/CoreSimulator")
        }.sorted { $0.version < $1.version }
    }

    /// Raíces de los proyectos de Android (las carpetas que tienen gradle/wrapper).
    private func proyectosGradle(_ c: Contexto) -> [String] {
        c.indice.wrappersGradle.map { Rutas.padre(Rutas.padre(Rutas.padre($0))) }
    }

    /// Dónde está el SDK de Android: el de Android Studio o el que diga el local.properties de algún proyecto.
    private func sdkAndroid(_ c: Contexto) -> URL {
        var candidatos = [Rutas.enHome("Library/Android/sdk"), Rutas.enHome("Android/Sdk")]
        for raiz in proyectosGradle(c) {
            guard let texto = try? String(contentsOfFile: raiz + "/local.properties", encoding: .utf8),
                  let linea = texto.split(separator: "\n").first(where: { $0.hasPrefix("sdk.dir=") }) else { continue }
            candidatos.append(URL(fileURLWithPath: linea.dropFirst(8).replacingOccurrences(of: "\\:", with: ":")))
        }
        return candidatos.first(where: Rutas.existe) ?? candidatos[0]
    }

    private static let patronSDK = try! NSRegularExpression(
        pattern: #"(?:compileSdk|compileSdkVersion|targetSdk|targetSdkVersion)\s*[=(]?\s*"?(?:android-)?(\d+)"#)

    /// «compileSdk = flutter.compileSdkVersion», «libs.versions…», una variable: la versión no está escrita a mano.
    private static let patronSDKVariable = try! NSRegularExpression(
        pattern: #"(?:compileSdk|compileSdkVersion|targetSdk|targetSdkVersion)\s*[=(]?\s*[A-Za-z_$]"#)

    /// Versiones de Android para las que compilan tus proyectos (compileSdk y targetSdk de sus build.gradle,
    /// incluidos buildSrc y build-logic). `desconocido` es true si algún proyecto la saca de una variable.
    private func sdksUsados(_ c: Contexto) -> (usadas: Set<String>, desconocido: Bool) {
        var r = Set<String>()
        var desconocido = false
        for raiz in proyectosGradle(c) {
            var archivos = [raiz + "/gradle/libs.versions.toml"]
            for carpeta in [raiz] + Rutas.hijos(URL(fileURLWithPath: raiz)).filter({ Rutas.esCarpeta($0) }).map(\.path) {
                archivos += [carpeta + "/build.gradle", carpeta + "/build.gradle.kts"]
            }
            // Plugins de convención: la versión suele estar ahí.
            for especial in ["buildSrc", "build-logic"] {
                let base = URL(fileURLWithPath: raiz + "/" + especial)
                guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
                for case let u as URL in e where ["kt", "kts", "gradle", "toml"].contains(u.pathExtension) && !u.path.contains("/build/") {
                    archivos.append(u.path)
                }
            }
            for a in archivos {
                guard let texto = try? String(contentsOfFile: a, encoding: .utf8) else { continue }
                let todo = NSRange(texto.startIndex..., in: texto)
                for m in Self.patronSDK.matches(in: texto, range: todo) {
                    if let rango = Range(m.range(at: 1), in: texto) { r.insert(String(texto[rango])) }
                }
                if Self.patronSDKVariable.firstMatch(in: texto, range: todo) != nil { desconocido = true }
            }
        }
        return (r, desconocido)
    }

    /// Qué build-tools usa cada proyecto de Android: la que fija su build.gradle (buildToolsVersion, también en
    /// libs.versions.toml, buildSrc y build-logic) y la que apunta su último análisis de lint (los modelos de lint de
    /// build/intermediates nombran «build-tools/<versión>/»). `sinSaber`: los proyectos de los que no se sabe, que usan la
    /// que trae por defecto su versión del plugin de Android.
    private func buildToolsUsadas(_ c: Contexto) -> (porVersion: [String: [String]], sinSaber: [String]) {
        var porVersion: [String: [String]] = [:]
        var sinSaber: [String] = []
        for raiz in proyectosGradle(c) {
            var versiones = Set<String>()
            let modulos = [raiz] + Rutas.hijos(URL(fileURLWithPath: raiz)).filter { Rutas.esCarpeta($0) }.map(\.path)
            var archivos = [raiz + "/gradle/libs.versions.toml"]
            for m in modulos { archivos += [m + "/build.gradle", m + "/build.gradle.kts"] }
            for especial in ["buildSrc", "build-logic"] {
                let base = URL(fileURLWithPath: raiz + "/" + especial)
                guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
                for case let u as URL in e where ["kt", "kts", "gradle", "toml"].contains(u.pathExtension) && !u.path.contains("/build/") {
                    archivos.append(u.path)
                }
            }
            for a in archivos {
                guard let texto = try? String(contentsOfFile: a, encoding: .utf8) else { continue }
                let todo = NSRange(texto.startIndex..., in: texto)
                for m in Self.patronBuildTools.matches(in: texto, range: todo) {
                    if let rango = Range(m.range(at: 1), in: texto) { versiones.insert(String(texto[rango])) }
                }
            }
            // build/intermediates/<lint…model>/<variante>/<tarea>/module.xml de cada módulo (son pequeños).
            for m in modulos {
                for modelo in Rutas.hijos(URL(fileURLWithPath: m + "/build/intermediates"))
                where modelo.lastPathComponent.contains("lint") && modelo.lastPathComponent.hasSuffix("model") {
                    for variante in Rutas.hijos(modelo) {
                        for tarea in Rutas.hijos(variante) {
                            let xml = tarea.appendingPathComponent("module.xml").path
                            var st = stat()
                            guard lstat(xml, &st) == 0, st.st_size <= 1_000_000,
                                  let texto = try? String(contentsOfFile: xml, encoding: .utf8) else { continue }
                            let todo = NSRange(texto.startIndex..., in: texto)
                            for x in Self.patronBuildToolsEnRuta.matches(in: texto, range: todo) {
                                if let rango = Range(x.range(at: 1), in: texto) { versiones.insert(String(texto[rango])) }
                            }
                        }
                    }
                }
            }
            let nombre = Rutas.nombre(raiz)
            if versiones.isEmpty { sinSaber.append(nombre) }
            for v in versiones where !(porVersion[v]?.contains(nombre) ?? false) { porVersion[v, default: []].append(nombre) }
        }
        return (porVersion, sinSaber)
    }

    private static let patronBuildTools = try! NSRegularExpression(
        pattern: #"(?i)build-?tools(?:Version)?[\w-]*\s*[=(:]?\s*["']([0-9][0-9A-Za-z.\-]*)["']"#)
    private static let patronBuildToolsEnRuta = try! NSRegularExpression(pattern: #"/build-tools/([0-9][0-9A-Za-z.\-]*)/"#)

    /// Una versión de build-tools que no es la más nueva. Si algún proyecto la usa, Revisar (Gradle la volvería a descargar
    /// en su próxima compilación). Si se sabe la de todos y ninguno la usa, Seguro y marcada. Si de alguno no se sabe
    /// (usa la que trae por defecto su plugin de Android, que no es siempre la más nueva), solo «Liberar al máximo».
    private func buildToolsAntigua(_ v: URL, ultima: String, usadas: (porVersion: [String: [String]], sinSaber: [String]),
                                   _ c: Contexto) -> Elemento {
        let version = v.lastPathComponent
        let nombre = "Android build-tools \(version) (versión antigua)"
        let detalle = "Herramientas de compilación de Android."
        if let usan = usadas.porVersion[version], !usan.isEmpty {
            return Elemento(
                nombre: nombre, detalle: detalle,
                consecuencia: "La próxima compilación de \(Formato.listaCorta(usan)) la vuelve a descargar (necesita internet).",
                rutas: [v], categoria: .emuladores, riesgo: .revisar,
                motivos: [.aviso("hammer.fill", usan.count == 1 ? "La usa \(usan[0])" : "La usan \(usan.count) proyectos",
                                 "\(Formato.listaCorta(usan)) \(usan.count == 1 ? "compila" : "compilan") con esta versión (lo dice su build.gradle o su último análisis de lint), aunque tengas la \(ultima). Si la borras, Gradle la vuelve a descargar al compilar (necesita internet).")],
                dueno: "Android Studio")
        }
        var motivos: [Motivo] = [.bien("clock.arrow.circlepath", "Hay una más nueva", "Ya tienes la versión \(ultima).")]
        if usadas.sinSaber.isEmpty {
            let conocidas = usadas.porVersion.keys.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            motivos.append(.bien("checkmark.circle.fill", "Ningún proyecto la usa", conocidas.isEmpty
                ? "No encontré ningún proyecto de Android."
                : "Tus proyectos de Android usan la \(Formato.lista(conocidas))."))
            return Elemento(
                nombre: nombre, detalle: detalle,
                consecuencia: "Si algún proyecto pide esta versión exacta, Gradle la vuelve a descargar.",
                rutas: [v], categoria: .emuladores, riesgo: .seguro, seleccionado: true, motivos: motivos,
                dueno: "Android Studio")
        }
        motivos.append(.info("arrow.down.circle.fill", "Puede que la pida un proyecto",
            "Si un proyecto la pide (el plugin de Android usa por defecto una versión fija, como la 35.0.0 en AGP 8.x, aunque el proyecto no la nombre), Gradle la vuelve a descargar (necesita internet). No sé cuál usa \(Formato.listaCorta(usadas.sinSaber)), así que no la marco sola: solo con «Liberar al máximo»."))
        return Elemento(
            nombre: nombre, detalle: detalle,
            consecuencia: "Si un proyecto la pide, Gradle la vuelve a descargar al compilar (necesita internet).",
            rutas: [v], categoria: .emuladores, riesgo: .seguro, seleccionado: true, motivos: motivos,
            dueno: "Android Studio", nivel: .maximo, costes: [.descarga(bytes: c.indice.bytes(de: v))])
    }

    // MARK: - Cachés de desarrollo

    private struct CacheDev {
        let rel: String
        let nombre: String
        let detalle: String
        let consecuencia: String
        var riesgo: Riesgo = .seguro
        var preseleccion = true
        var uso: EnUso? = nil
        var dueno: String? = nil
    }

    private static let xcodeUso = EnUso.app(nombre: "Xcode", claves: ["com.apple.dt.Xcode"])

    private static let cachesDeDesarrollo: [CacheDev] = [
        CacheDev(rel: ".npm/_cacache", nombre: "Caché de npm", detalle: "Paquetes de npm descargados.",
                 consecuencia: "npm los vuelve a descargar la próxima vez que instales paquetes (necesita internet).", dueno: "npm"),
        CacheDev(rel: ".npm/_npx", nombre: "Paquetes temporales de npx", detalle: "Herramientas que npx descargó una vez para ejecutarlas.",
                 consecuencia: "Si vuelves a usar esa herramienta con npx, se descarga otra vez.", dueno: "npm"),
        CacheDev(rel: ".gradle/daemon", nombre: "Registros del daemon de Gradle", detalle: "Registros de procesos de Gradle que ya terminaron.",
                 consecuencia: "Nada: solo son registros.", uso: .gradle, dueno: "Gradle"),
        CacheDev(rel: ".gradle/.tmp", nombre: "Temporales de Gradle", detalle: "Archivos temporales de Gradle.",
                 consecuencia: "Nada: Gradle crea nuevos cuando los necesita.", uso: .gradle, dueno: "Gradle"),
        CacheDev(rel: "Library/Developer/Xcode/UserData/Previews", nombre: "Vistas previas de SwiftUI",
                 detalle: "Simuladores internos que Xcode usa para las vistas previas.",
                 consecuencia: "Xcode los vuelve a crear la próxima vez que abras una vista previa.", uso: xcodeUso, dueno: "Xcode"),
        CacheDev(rel: "Library/Developer/CoreSimulator/Caches", nombre: "Caché de simuladores", detalle: "Caché de los simuladores de iOS.",
                 consecuencia: "Los simuladores la regeneran al arrancar.", dueno: "Xcode"),
        CacheDev(rel: "Library/Caches/CocoaPods", nombre: "Caché de CocoaPods", detalle: "Pods descargados.",
                 consecuencia: "pod install los vuelve a descargar.", dueno: "CocoaPods"),
        CacheDev(rel: ".cocoapods/repos", nombre: "Repositorios de CocoaPods", detalle: "Índices de librerías de CocoaPods.",
                 consecuencia: "pod install los vuelve a descargar (puede tardar).", preseleccion: false, dueno: "CocoaPods"),
        CacheDev(rel: "Library/Caches/pip", nombre: "Caché de pip", detalle: "Paquetes de Python descargados.",
                 consecuencia: "pip los vuelve a descargar si hacen falta.", dueno: "Python"),
        CacheDev(rel: ".cache/pip", nombre: "Caché de pip", detalle: "Paquetes de Python descargados.",
                 consecuencia: "pip los vuelve a descargar si hacen falta.", dueno: "Python"),
        CacheDev(rel: ".cache/uv", nombre: "Caché de uv", detalle: "Paquetes de Python descargados por uv.",
                 consecuencia: "uv los vuelve a descargar si hacen falta.", dueno: "Python"),
        CacheDev(rel: "Library/Caches/pypoetry/cache", nombre: "Caché de Poetry", detalle: "Índices de paquetes de Python que consultó Poetry.",
                 consecuencia: "Poetry los vuelve a descargar si hacen falta.", dueno: "Python"),
        CacheDev(rel: "Library/Caches/pypoetry/artifacts", nombre: "Paquetes descargados por Poetry", detalle: "Paquetes de Python descargados por Poetry.",
                 consecuencia: "Poetry los vuelve a descargar si hacen falta.", dueno: "Python"),
        CacheDev(rel: "Library/Caches/pypoetry/virtualenvs", nombre: "Entornos virtuales de Poetry",
                 detalle: "Los entornos de Python de tus proyectos con Poetry, con sus paquetes instalados.",
                 consecuencia: "Tendrás que ejecutar «poetry install» en cada proyecto antes de volver a usarlo.",
                 riesgo: .revisar, preseleccion: false, dueno: "Python"),
        CacheDev(rel: "Library/Caches/Homebrew", nombre: "Caché de Homebrew", detalle: "Instaladores que descargó brew.",
                 consecuencia: "Nada: los programas ya están instalados.", dueno: "Homebrew"),
        CacheDev(rel: "Library/Caches/electron", nombre: "Caché de Electron", detalle: "Versiones de Electron descargadas al instalar paquetes.",
                 consecuencia: "Se vuelven a descargar al instalar un proyecto de Electron.", dueno: "Electron"),
        CacheDev(rel: "Library/Caches/electron-builder", nombre: "Caché de electron-builder",
                 detalle: "Herramientas descargadas para empaquetar apps de Electron.",
                 consecuencia: "Se vuelven a descargar al empaquetar.", dueno: "Electron"),
        CacheDev(rel: "Library/Caches/node-gyp", nombre: "Caché de node-gyp", detalle: "Cabeceras de Node para compilar módulos nativos.",
                 consecuencia: "Se vuelven a descargar si hacen falta.", dueno: "Node"),
        CacheDev(rel: ".node-gyp", nombre: "Cabeceras de Node (node-gyp)", detalle: "Cabeceras de Node que se descargan para compilar módulos nativos.",
                 consecuencia: "Se vuelven a descargar la próxima vez que compiles un módulo nativo (necesita internet).", dueno: "Node"),
        CacheDev(rel: ".electron-gyp", nombre: "Cabeceras de Electron",
                 detalle: "Cabeceras de Electron que se descargan para compilar módulos nativos (electron-rebuild, electron-builder).",
                 consecuencia: "Se vuelven a descargar la próxima vez que recompiles módulos nativos para Electron. Lo ya compilado no se toca.",
                 dueno: "Electron"),
        CacheDev(rel: ".cmake-js", nombre: "Cabeceras de cmake-js", detalle: "Cabeceras de Node o Electron descargadas por cmake-js.",
                 consecuencia: "Se vuelven a descargar si hacen falta.", dueno: "Node"),
        CacheDev(rel: "Library/Caches/org.swift.swiftpm", nombre: "Caché de Swift Package Manager", detalle: "Paquetes de Swift descargados.",
                 consecuencia: "Se vuelven a descargar al compilar.", dueno: "Xcode"),
        CacheDev(rel: "Library/Caches/Yarn", nombre: "Caché de Yarn", detalle: "Paquetes de Yarn descargados.",
                 consecuencia: "Yarn los vuelve a descargar.", dueno: "Yarn"),
        CacheDev(rel: ".yarn/berry/cache", nombre: "Caché de Yarn", detalle: "Paquetes de Yarn descargados.",
                 consecuencia: "Yarn los vuelve a descargar.", dueno: "Yarn"),
        CacheDev(rel: "Library/Caches/go-build", nombre: "Caché de Go", detalle: "Compilaciones de Go.",
                 consecuencia: "Go vuelve a compilar lo que necesite.", dueno: "Go"),
        CacheDev(rel: "go/pkg/mod", nombre: "Módulos de Go", detalle: "Dependencias de Go descargadas.",
                 consecuencia: "Se vuelven a descargar al compilar (necesita internet).", preseleccion: false, dueno: "Go"),
        CacheDev(rel: "Library/pnpm/store", nombre: "Almacén de pnpm", detalle: "Paquetes de pnpm descargados.",
                 consecuencia: "pnpm los vuelve a descargar.", dueno: "pnpm"),
        CacheDev(rel: ".bun/install/cache", nombre: "Caché de Bun", detalle: "Paquetes descargados por Bun.",
                 consecuencia: "Bun los vuelve a descargar.", dueno: "Bun"),
        CacheDev(rel: ".cargo/registry", nombre: "Registro de Cargo", detalle: "Librerías de Rust descargadas.",
                 consecuencia: "Cargo las vuelve a descargar al compilar.", preseleccion: false, dueno: "Rust"),
        CacheDev(rel: ".m2/repository", nombre: "Repositorio de Maven", detalle: "Dependencias Java descargadas.",
                 consecuencia: "Maven las vuelve a descargar al compilar.", preseleccion: false, dueno: "Maven"),
        CacheDev(rel: ".nuget/packages", nombre: "Paquetes de NuGet", detalle: "Dependencias de .NET descargadas.",
                 consecuencia: "Se vuelven a descargar al compilar.", preseleccion: false, dueno: ".NET"),
        CacheDev(rel: ".pub-cache", nombre: "Caché de Flutter (pub)", detalle: "Paquetes de Dart y Flutter descargados.",
                 consecuencia: "flutter pub get los vuelve a descargar.", riesgo: .revisar, preseleccion: false, dueno: "Flutter"),
        CacheDev(rel: ".cache/pre-commit", nombre: "Caché de pre-commit", detalle: "Entornos de los hooks de pre-commit.",
                 consecuencia: "Se vuelven a crear en el próximo commit.", dueno: "pre-commit"),
        CacheDev(rel: ".cache/node/corepack", nombre: "Caché de Corepack", detalle: "Versiones de gestores de paquetes de Node.",
                 consecuencia: "Se vuelven a descargar si hacen falta.", dueno: "Node"),
        CacheDev(rel: ".cache/firebase", nombre: "Caché de Firebase", detalle: "Emuladores y herramientas descargadas por Firebase CLI.",
                 consecuencia: "Firebase CLI los vuelve a descargar al usarlos.", preseleccion: false, dueno: "Firebase"),
        CacheDev(rel: ".cache/torch", nombre: "Modelos de PyTorch", detalle: "Modelos descargados por PyTorch.",
                 consecuencia: "Se vuelven a descargar si un programa los necesita.", riesgo: .revisar, preseleccion: false, dueno: "PyTorch"),
        CacheDev(rel: ".expo", nombre: "Datos de Expo", detalle: "Caché y sesión de Expo (React Native).",
                 consecuencia: "Tendrás que volver a iniciar sesión en Expo.", riesgo: .revisar, preseleccion: false, dueno: "Expo"),
        CacheDev(rel: ".android/cache", nombre: "Caché de Android", detalle: "Caché de las herramientas de Android.",
                 consecuencia: "Se regenera sola.", dueno: "Android Studio"),
        CacheDev(rel: ".android/build-cache", nombre: "Caché de compilación de Android (antigua)",
                 detalle: "Caché que usaban versiones antiguas del plugin de Android para Gradle.",
                 consecuencia: "Nada: las versiones actuales ya no la usan.", uso: .gradle, dueno: "Android Studio"),
        CacheDev(rel: "Library/Caches/com.apple.dt.Xcode", nombre: "Caché de Xcode", detalle: "Archivos temporales de Xcode.",
                 consecuencia: "Xcode la vuelve a crear.", uso: xcodeUso, dueno: "Xcode"),
        CacheDev(rel: "Library/Developer/XCTestDevices", nombre: "Simuladores de pruebas de Xcode",
                 detalle: "Copias de simuladores que Xcode crea para ejecutar pruebas en paralelo.",
                 consecuencia: "Xcode las vuelve a crear la próxima vez que ejecutes pruebas.", uso: xcodeUso, dueno: "Xcode"),
        CacheDev(rel: "Library/Developer/Xcode/iOS Device Logs", nombre: "Registros de dispositivos iOS",
                 detalle: "Registros que Xcode copió de los iPhone y iPad que conectaste.",
                 consecuencia: "Nada: solo son registros.", dueno: "Xcode"),
        CacheDev(rel: "Library/Developer/Xcode/Products", nombre: "Productos de Xcode",
                 detalle: "Compilaciones que Xcode guarda para la depuración y las vistas previas.",
                 consecuencia: "Xcode las regenera al compilar.", uso: xcodeUso, dueno: "Xcode"),
        CacheDev(rel: "Library/Developer/Xcode/DocumentationCache", nombre: "Caché de documentación de Xcode",
                 detalle: "Documentación descargada para el visor de Xcode.",
                 consecuencia: "Xcode la vuelve a descargar al abrir la documentación.", uso: xcodeUso, dueno: "Xcode"),
        CacheDev(rel: "Library/Developer/XCPGDevices", nombre: "Simuladores de Playgrounds",
                 detalle: "Simuladores que Xcode crea para ejecutar Playgrounds.",
                 consecuencia: "Xcode los vuelve a crear al abrir un Playground.", uso: xcodeUso, dueno: "Xcode"),
        CacheDev(rel: "Library/Developer/DVTDownloads", nombre: "Descargas de Xcode",
                 detalle: "Componentes que Xcode descargó (o dejó a medias) al instalarse o actualizarse.",
                 consecuencia: "Nada: lo instalado no se toca. Xcode vuelve a descargar lo que le falte.", uso: xcodeUso, dueno: "Xcode"),
        CacheDev(rel: "Library/Developer/Shared/Documentation/DocSets", nombre: "Documentación antigua de Xcode",
                 detalle: "Paquetes de documentación de versiones antiguas de Xcode.",
                 consecuencia: "Nada: las versiones actuales de Xcode descargan la documentación de otra forma.",
                 uso: xcodeUso, dueno: "Xcode"),
        CacheDev(rel: "Library/Developer/CoreSimulator/Temp", nombre: "Temporales de los simuladores",
                 detalle: "Archivos temporales de los simuladores de iOS.",
                 consecuencia: "Nada: se crean nuevos al arrancar un simulador.", dueno: "Xcode"),
        CacheDev(rel: "Library/Caches/com.apple.python", nombre: "Caché de Python de macOS",
                 detalle: "Archivos .pyc que el Python de macOS (/usr/bin/python3) compila al usarse.",
                 consecuencia: "Se vuelven a generar la próxima vez que se use Python.", dueno: "Python"),
        CacheDev(rel: ".gradle/jdks", nombre: "Versiones de Java descargadas por Gradle",
                 detalle: "JDKs que Gradle descargó automáticamente para compilar tus proyectos.",
                 consecuencia: "Gradle los vuelve a descargar si un proyecto los pide.", riesgo: .revisar, preseleccion: false,
                 uso: .gradle, dueno: "Gradle"),
        CacheDev(rel: ".konan/dependencies", nombre: "Dependencias de Kotlin/Native",
                 detalle: "Compiladores y librerías que descargó Kotlin Multiplatform.",
                 consecuencia: "Se vuelven a descargar en la próxima compilación (pueden ser varios GB).", riesgo: .revisar,
                 preseleccion: false, uso: .gradle, dueno: "Kotlin"),
        CacheDev(rel: ".konan/cache", nombre: "Caché de Kotlin/Native", detalle: "Librerías precompiladas de Kotlin/Native.",
                 consecuencia: "Se regenera en la próxima compilación.", uso: .gradle, dueno: "Kotlin"),
        CacheDev(rel: ".pnpm-store", nombre: "Almacén de pnpm", detalle: "Paquetes de pnpm descargados.",
                 consecuencia: "pnpm los vuelve a descargar.", dueno: "pnpm"),
        CacheDev(rel: ".dartServer", nombre: "Caché del analizador de Dart", detalle: "Índices del analizador de código de Dart y Flutter.",
                 consecuencia: "El editor los vuelve a crear al abrir un proyecto.", dueno: "Flutter"),
        CacheDev(rel: ".ivy2/cache", nombre: "Caché de Ivy", detalle: "Dependencias de Java y Scala descargadas.",
                 consecuencia: "Se vuelven a descargar al compilar.", preseleccion: false, dueno: "Java"),
        CacheDev(rel: ".nvm/.cache", nombre: "Descargas de nvm", detalle: "Instaladores de Node que nvm descargó.",
                 consecuencia: "Nada: las versiones de Node ya están instaladas.", dueno: "Node"),
        CacheDev(rel: ".rustup/downloads", nombre: "Descargas de rustup", detalle: "Paquetes de Rust a medio instalar.",
                 consecuencia: "Nada: rustup los descarga otra vez si hacen falta.", dueno: "Rust"),
        CacheDev(rel: ".cargo/git", nombre: "Repositorios de Cargo", detalle: "Dependencias de Rust descargadas directamente desde git.",
                 consecuencia: "Cargo las vuelve a descargar al compilar.", preseleccion: false, dueno: "Rust"),
        CacheDev(rel: ".bundle/cache", nombre: "Caché de Bundler", detalle: "Índices y paquetes de Ruby que descargó Bundler.",
                 consecuencia: "Bundler los vuelve a descargar si hacen falta (necesita internet). Las gemas instaladas no se tocan.",
                 dueno: "Ruby"),
        CacheDev(rel: ".gem/specs", nombre: "Índices de RubyGems", detalle: "Listas de gemas que RubyGems descargó al buscar e instalar.",
                 consecuencia: "Se vuelven a descargar al instalar una gema.", dueno: "Ruby"),
        CacheDev(rel: ".local/share/NuGet/http-cache", nombre: "Caché HTTP de NuGet", detalle: "Respuestas y paquetes de NuGet (.NET) descargados.",
                 consecuencia: "NuGet los vuelve a descargar si hacen falta. Los paquetes que usan tus proyectos (~/.nuget/packages) no se tocan.",
                 dueno: ".NET"),
        CacheDev(rel: ".local/share/NuGet/v3-cache", nombre: "Caché de NuGet (antigua)", detalle: "Caché HTTP de versiones anteriores de NuGet (.NET).",
                 consecuencia: "Nada: las versiones actuales usan http-cache, y lo que falte se vuelve a descargar.", dueno: ".NET"),
        CacheDev(rel: "fvm/versions", nombre: "Versiones de Flutter (FVM)", detalle: "SDK de Flutter enteros que instaló FVM, uno por versión.",
                 consecuencia: "Los proyectos que fijan una de estas versiones la necesitarán otra vez: «fvm install» la vuelve a descargar (unos cientos de MB cada una).",
                 riesgo: .revisar, preseleccion: false, dueno: "Flutter"),
    ]

    /// Carpetas de ~/Library/Caches que ya ofrece «Cachés de desarrollo» (para no repetirlas en otras categorías).
    private static let cachesDeDesarrolloEnLibrary: Set<String> = Set(cachesDeDesarrollo.compactMap { d in
        let partes = d.rel.split(separator: "/")
        return partes.count >= 3 && partes[0] == "Library" && partes[1] == "Caches" ? String(partes[2]) : nil
    } + ["ms-playwright", "Cypress"])

    private func desarrollo(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        for d in Self.cachesDeDesarrollo {
            let url = Rutas.enHome(d.rel)
            guard Rutas.existe(url) else { continue }
            r.append(Elemento(
                nombre: d.nombre, detalle: d.detalle, consecuencia: d.consecuencia, rutas: [url],
                categoria: .desarrollo, riesgo: d.riesgo, seleccionado: d.preseleccion,
                motivos: d.riesgo == .seguro
                    ? [.bien("arrow.triangle.2.circlepath", "Se regenera", "Es una caché: se vuelve a crear o descargar cuando hace falta.")]
                    : [.info("arrow.down.circle.fill", "Se vuelve a descargar", d.consecuencia)],
                enUso: d.uso, dueno: d.dueno))
        }
        r += gradle(c)
        r += xcode()
        r += navegadoresDePrueba()
        r += versionesAnterioresDeIDEs()
        r += versionesDeLenguajes(c)
        r += versionesDeProgramas(c)
        r += extensionesAntiguas()
        r += cachesXDG(c)
        r += paquetesDeConda()
        r += runtimesDeCodex(c)
        r += binariosDeAgentes(c)
        r += binariosViejos(c)
        r += comandosTapados(c)
        r += estadoDeProyectosBorrados()
        r += homebrew()
        r += docker(c)
        r += cachesDeGemas()
        r += cachesDeFlutter(c)
        r += ollama(c)
        r += huggingFace(c)

        let hf = Rutas.enHome(".cache/huggingface")
        if Rutas.existe(hf) {
            let modelos = Rutas.hijos(hf.appendingPathComponent("hub")).map(\.lastPathComponent)
                .filter { $0.hasPrefix("models--") }
                .map { String($0.dropFirst(8)).replacingOccurrences(of: "--", with: "/") }
            r.append(Elemento(
                nombre: "Modelos de IA (Hugging Face)",
                detalle: modelos.isEmpty ? "Modelos de inteligencia artificial descargados." : "Modelos descargados: \(Formato.listaCorta(modelos)).",
                consecuencia: "Si un programa vuelve a necesitar un modelo, lo descarga otra vez (pueden ser varios GB).",
                rutas: [hf], categoria: .desarrollo, riesgo: .revisar,
                motivos: [.info("arrow.down.circle.fill", "Descarga pesada", "Volver a descargarlos puede tardar bastante.")],
                dueno: "Hugging Face"))
        }
        return r
    }

    /// Los .gem que RubyGems guarda después de instalar cada gema (~/.gem/ruby/<versión>/cache): la gema ya está
    /// instalada, así que solo sirven para reinstalarla sin internet.
    private func cachesDeGemas() -> [Elemento] {
        let gem = Rutas.enHome(".gem")
        var caches: [URL] = []
        for h in Rutas.hijos(gem) where Rutas.esCarpeta(h) && h.lastPathComponent != "specs" {
            if Rutas.esCarpeta(h.appendingPathComponent("cache")) { caches.append(h.appendingPathComponent("cache")) }
            for v in Rutas.hijos(h) where Rutas.esCarpeta(v.appendingPathComponent("cache")) {
                caches.append(v.appendingPathComponent("cache"))
            }
        }
        return caches.map { u in
            let version = u.deletingLastPathComponent().lastPathComponent
            return Elemento(
                nombre: "Caché de RubyGems \(version)", detalle: "Los paquetes (.gem) de las gemas que instalaste con Ruby \(version).",
                consecuencia: "Nada: las gemas instaladas no se tocan. Si reinstalas una, se vuelve a descargar.",
                rutas: [u], categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("arrow.triangle.2.circlepath", "Se regenera", "Es una caché: se vuelve a crear o descargar cuando hace falta.")],
                enUso: .programas(nombre: "Ruby", ejecutables: ["ruby", "gem", "bundle", "bundler"]), dueno: "Ruby")
        }
    }

    /// La caché del SDK de Flutter (<sdk>/bin/cache: el SDK de Dart y el motor de cada plataforma), que `flutter` vuelve
    /// a descargar entera cuando falta. Se busca el SDK del PATH de tu terminal y los sitios habituales, siempre dentro de
    /// tu carpeta (los de FVM los cubre «Versiones de Flutter (FVM)»). Solo para «Liberar al máximo»: cuesta descargarla.
    private func cachesDeFlutter(_ c: Contexto) -> [Elemento] {
        var sdks: [String] = []
        for dir in c.apps.pathTerminal {
            let programa = dir + "/flutter"
            guard FileManager.default.isExecutableFile(atPath: programa) else { continue }
            let real = Rutas.real(URL(fileURLWithPath: programa))
            if real.hasSuffix("/bin/flutter") { sdks.append(Rutas.padre(Rutas.padre(real))) }
        }
        for rel in ["flutter", "development/flutter", "Developer/flutter", "src/flutter", "sdk/flutter", "sdks/flutter"] {
            let sdk = Rutas.enHome(rel)
            if Rutas.existe(sdk.appendingPathComponent("bin/flutter")) { sdks.append(Rutas.real(sdk)) }
        }
        let casa = Rutas.real(Rutas.home) + "/"
        var vistos = Set<String>()
        var r: [Elemento] = []
        for sdk in sdks where sdk.hasPrefix(casa) && !sdk.contains("/fvm/versions/") && vistos.insert(sdk).inserted {
            let cache = URL(fileURLWithPath: sdk + "/bin/cache")
            guard Rutas.esCarpeta(cache) else { continue }
            let bytes = c.indice.bytes(de: cache)
            r.append(Elemento(
                nombre: "Caché del SDK de Flutter", detalle: "El SDK de Dart y los motores de cada plataforma que Flutter descargó en \(Formato.rutaCorta(cache)).",
                consecuencia: "La próxima vez que uses flutter los vuelve a descargar (necesita internet y unos minutos). Tus proyectos y paquetes no se tocan.",
                rutas: [cache], categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                motivos: [.info("arrow.down.circle.fill", "Se vuelve a descargar",
                                "flutter la vuelve a descargar entera al usarlo: por eso no la marco sola, solo con «Liberar al máximo».")],
                enUso: .programas(nombre: "Flutter", ejecutables: ["dart", "flutter", "dartaotruntime", "dartvm"]), dueno: "Flutter",
                nivel: .maximo, costes: [.descarga(bytes: bytes)]))
        }
        return r
    }

    /// Ollama guarda cada modelo como una lista (manifests/…/<modelo>/<etiqueta>, un JSON) de piezas (blobs/sha256-…),
    /// y varios modelos pueden compartir piezas (uno creado a partir de otro usa su mismo archivo de pesos). Aquí:
    /// - las piezas que ya no usa ningún modelo y las descargas a medias (*-partial), de 24 h o más: Seguro y marcadas
    ///   (el propio Ollama las borra al arrancar);
    /// - cada modelo con lo que es solo suyo, y los que comparten piezas, juntos: Revisar (volver a descargarlos cuesta).
    /// Si algún manifiesto no se puede leer, no se da nada por huérfano.
    private func ollama(_ c: Contexto) -> [Elemento] {
        let modelos = Rutas.enHome(".ollama/models")
        let blobs = modelos.appendingPathComponent("blobs")
        guard Rutas.esCarpeta(blobs) else { return [] }
        let uso = EnUso.rutas(nombre: "Ollama", raiz: modelos.path)
        let fm = FileManager.default
        // Manifiestos: registro/espacio/modelo/etiqueta, a cualquier profundidad.
        var manifiestos: [(nombre: String, ruta: String, piezas: Set<String>)] = []
        let base = modelos.appendingPathComponent("manifests").path
        // Si la carpeta de manifiestos (o alguna de dentro) no se puede leer entera, no se sabe qué usa cada modelo.
        var legibles = (try? fm.contentsOfDirectory(atPath: base)) != nil
        if legibles, let e = fm.enumerator(atPath: base) {
            for case let rel as String in e {
                let ruta = base + "/" + rel
                if Rutas.esCarpeta(URL(fileURLWithPath: ruta)) {
                    if access(ruta, R_OK | X_OK) != 0 { legibles = false }
                    continue
                }
                guard !Rutas.nombre(rel).hasPrefix(".") else { continue }
                guard let datos = fm.contents(atPath: ruta),
                      let json = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else {
                    legibles = false
                    continue
                }
                var piezas = Set<String>()
                for capa in (json["layers"] as? [[String: Any]] ?? []) + [json["config"] as? [String: Any] ?? [:]] {
                    if let d = capa["digest"] as? String { piezas.insert(d.replacingOccurrences(of: ":", with: "-")) }
                }
                // «registry.ollama.ai/library/qwen2.5/3b» → «qwen2.5:3b»; los de otro registro, con su espacio.
                let partes = rel.split(separator: "/").map(String.init)
                let nombre = partes.count >= 2 ? partes[partes.count - 2] + ":" + partes[partes.count - 1] : rel
                let espacio = partes.count >= 4 && partes[1] != "library" ? partes[1] + "/" : ""
                manifiestos.append((espacio + nombre, ruta, piezas))
            }
        }
        var r: [Elemento] = []
        let ahora = Date()
        var huerfanas: [URL] = []
        var reciente = false
        let usadas = manifiestos.reduce(into: Set<String>()) { $0.formUnion($1.piezas) }
        for b in Rutas.hijos(blobs) {
            let n = b.lastPathComponent
            guard n.hasPrefix("sha256") else { continue }
            let edad = Fechas.modificacion(b).map { ahora.timeIntervalSince($0) } ?? 0
            // Algo cambió en la última hora: está descargando (o creando) un modelo.
            if edad < 3600 { reciente = true }
            let aMedias = n.contains("-partial")
            if aMedias || (legibles && !usadas.contains(n)) {
                if edad >= 86400 { huerfanas.append(b) }
            }
        }
        if !huerfanas.isEmpty {
            r.append(Elemento(
                nombre: "Descargas a medias y piezas sueltas de Ollama",
                detalle: "\(huerfanas.count) \(huerfanas.count == 1 ? "archivo" : "archivos") de ~/.ollama/models/blobs que no usa ningún modelo (de modelos que borraste) o que quedaron de una descarga cortada.",
                consecuencia: "Nada: ningún modelo los usa. Si vuelves a descargar un modelo que los necesite, «ollama pull» los descarga otra vez. Ollama también los borra al arrancar.",
                rutas: huerfanas, categoria: .desarrollo, riesgo: reciente ? .revisar : .seguro, seleccionado: !reciente,
                motivos: reciente
                    ? [.aviso("arrow.down.circle.dotted", "Descargando", "Algo cambió en las piezas de Ollama hace menos de una hora: puede que esté descargando o creando un modelo. Vuelve a analizar cuando termine.")]
                    : [.bien("puzzlepiece", "Sin modelo", "Ningún modelo instalado los usa (lo leí en sus manifiestos) y llevan 24 h o más sin cambios.")],
                enUso: uso, dueno: "Ollama"))
        }
        // Modelos que comparten piezas, juntos (grupos conexos).
        var grupo = Array(manifiestos.indices)
        func raiz(_ i: Int) -> Int { var i = i; while grupo[i] != i { i = grupo[i] }; return i }
        for i in manifiestos.indices {
            for j in manifiestos.indices where j > i && !manifiestos[i].piezas.isDisjoint(with: manifiestos[j].piezas) {
                grupo[raiz(j)] = raiz(i)
            }
        }
        let grupos = Dictionary(grouping: manifiestos.indices, by: raiz).values.map { $0.map { manifiestos[$0] } }
        func archivos(_ piezas: Set<String>) -> [URL] {
            piezas.sorted().map { blobs.appendingPathComponent($0) }.filter { Rutas.existe($0) }
        }
        for g in grupos {
            let descarga = "Tendrás que volver a descargarlo con «ollama pull» (el archivo de pesos suele pesar varios GB). Tus conversaciones con él no se guardan aquí."
            if g.count == 1, let m = g.first {
                r.append(Elemento(
                    nombre: "Modelo de Ollama \(m.nombre)", detalle: "Un modelo de IA descargado con Ollama.", consecuencia: descarga,
                    rutas: [URL(fileURLWithPath: m.ruta)] + archivos(m.piezas), categoria: .desarrollo, riesgo: .revisar,
                    motivos: [.info("arrow.down.circle.fill", "Descarga pesada", "Volver a descargarlo puede tardar bastante.")],
                    enUso: uso, dueno: "Ollama"))
                continue
            }
            // Varios modelos con piezas en común: juntos, y cada uno con lo que es solo suyo.
            let comunes = g.flatMap { m in g.filter { $0.ruta != m.ruta }.map { m.piezas.intersection($0.piezas) } }
                .reduce(into: Set<String>()) { $0.formUnion($1) }
            let nombres = g.map(\.nombre).sorted()
            r.append(Elemento(
                nombre: "Modelos de Ollama \(Formato.lista(nombres))",
                detalle: "Modelos de IA descargados con Ollama que comparten piezas (uno se creó a partir del otro).",
                consecuencia: "Tendrás que volver a descargarlos (o a crearlos) con Ollama. Lo que compartían se libera solo al borrarlos todos juntos.",
                rutas: g.map { URL(fileURLWithPath: $0.ruta) } + archivos(g.reduce(into: Set<String>()) { $0.formUnion($1.piezas) }),
                categoria: .desarrollo, riesgo: .revisar,
                motivos: [.info("link", "Comparten datos",
                                "\(Formato.lista(nombres)) usan las mismas piezas (\(comunes.count == 1 ? "una" : "\(comunes.count)"), entre ellas el archivo de pesos). Si borras solo uno, el otro sigue funcionando, pero casi no liberas nada: el espacio vuelve al borrarlos todos.")],
                enUso: uso, dueno: "Ollama"))
            for m in g {
                let suyas = m.piezas.subtracting(comunes)
                r.append(Elemento(
                    nombre: "Modelo de Ollama \(m.nombre) (solo lo suyo)",
                    detalle: "Lo que es solo de \(m.nombre); las piezas que comparte con \(Formato.lista(nombres.filter { $0 != m.nombre })) se quedan.",
                    consecuencia: "\(m.nombre) deja de estar instalado; los demás siguen funcionando. \(descarga)",
                    rutas: [URL(fileURLWithPath: m.ruta)] + archivos(suyas), categoria: .desarrollo, riesgo: .revisar,
                    motivos: [.info("link", "Comparte datos", "Las piezas que comparte con otros modelos no se borran.")],
                    enUso: uso, dueno: "Ollama"))
            }
        }
        return r
    }

    /// Hugging Face guarda cada repositorio (hub/models--org--nombre) con sus revisiones (snapshots/<commit>, enlaces a
    /// blobs/<hash>) y apunta en refs/ cuál usa cada rama. Las revisiones que ya no apunta ninguna ref quedaron de una
    /// versión anterior del modelo: Seguro (solo las usaría un programa que pida ese commit exacto, y la volvería a
    /// descargar), solo para «Liberar al máximo». Se ofrecen con las piezas que solo usan ellas y las descargas a medias
    /// (*.incomplete) de 24 h o más.
    private func huggingFace(_ c: Contexto) -> [Elemento] {
        let hub = Rutas.enHome(".cache/huggingface/hub")
        var rutas: [URL] = []
        var repos: [String] = []
        let ahora = Date()
        for repo in Rutas.hijos(hub) where ["models--", "datasets--", "spaces--"].contains(where: { repo.lastPathComponent.hasPrefix($0) }) {
            let refs = repo.appendingPathComponent("refs")
            // Sin refs no se sabe cuál se usa: no se toca nada de ese repositorio.
            guard let ramas = FileManager.default.enumerator(atPath: refs.path) else { continue }
            var usadas = Set<String>()
            for case let rel as String in ramas {
                if let t = try? String(contentsOfFile: refs.path + "/" + rel, encoding: .utf8) {
                    usadas.insert(t.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            guard !usadas.isEmpty else { continue }
            let snapshots = Rutas.hijos(repo.appendingPathComponent("snapshots")).filter { Rutas.esCarpeta($0) }
            // Las piezas (blobs) a las que apunta cada revisión.
            func piezas(_ s: URL) -> Set<String> {
                var r = Set<String>()
                if let e = FileManager.default.enumerator(atPath: s.path) {
                    for case let rel as String in e {
                        if let destino = try? FileManager.default.destinationOfSymbolicLink(atPath: s.path + "/" + rel) {
                            r.insert(Rutas.nombre(destino))
                        }
                    }
                }
                return r
            }
            let sueltas = snapshots.filter { !usadas.contains($0.lastPathComponent) }
            let retenidas = snapshots.filter { usadas.contains($0.lastPathComponent) }.reduce(into: Set<String>()) { $0.formUnion(piezas($1)) }
            var deEste: [URL] = []
            for s in sueltas {
                deEste.append(s)
                for p in piezas(s).subtracting(retenidas) {
                    let b = repo.appendingPathComponent("blobs/" + p)
                    if Rutas.existe(b) && !deEste.contains(b) { deEste.append(b) }
                }
            }
            for b in Rutas.hijos(repo.appendingPathComponent("blobs")) where b.lastPathComponent.hasSuffix(".incomplete") {
                if let f = Fechas.modificacion(b), ahora.timeIntervalSince(f) >= 86400 { deEste.append(b) }
            }
            if !deEste.isEmpty {
                rutas += deEste
                repos.append(repo.lastPathComponent.split(separator: "--").dropFirst().joined(separator: "/"))
            }
        }
        guard !rutas.isEmpty else { return [] }
        let bytes = rutas.reduce(Int64(0)) { $0 + c.indice.bytes(de: $1) }
        return [Elemento(
            nombre: "Versiones antiguas de modelos de Hugging Face",
            detalle: "Revisiones de \(Formato.listaCorta(repos)) que ya no usa ninguna rama (quedaron al actualizarse el modelo), con los archivos que solo usan ellas y las descargas a medias.",
            consecuencia: "Las versiones actuales no se tocan. Si un programa pide una de estas revisiones exactas, la vuelve a descargar (necesita internet).",
            rutas: rutas, categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
            motivos: [.bien("arrow.triangle.branch", "Sin rama", "Ninguna ref (main…) apunta a estas revisiones: la versión que se usa es otra."),
                      .info("arrow.down.circle.fill", "Se vuelve a descargar", "Solo con «Liberar al máximo»: si algo las pide, se descargan otra vez.")],
            enUso: .rutas(nombre: "Hugging Face", raiz: hub.path), dueno: "Hugging Face",
            nivel: .maximo, costes: [.descarga(bytes: bytes)])]
    }

    /// Gradle separado por partes, sabiendo qué versión usa cada proyecto.
    private func gradle(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        var usos: [String: [String]] = [:]   // versión → proyectos que la usan
        for w in c.indice.wrappersGradle {
            guard let texto = try? String(contentsOfFile: w, encoding: .utf8),
                  let linea = texto.split(separator: "\n").first(where: { $0.hasPrefix("distributionUrl") }),
                  let rango = linea.range(of: "gradle-") else { continue }
            let version = linea[rango.upperBound...].split(separator: "-").first.map(String.init) ?? ""
            let proyecto = Rutas.nombre(Rutas.padre(Rutas.padre(Rutas.padre(w))))
            if !version.isEmpty { usos[version, default: []].append(proyecto) }
        }

        for d in Rutas.hijos(Rutas.enHome(".gradle/wrapper/dists")) where Rutas.esCarpeta(d) {
            let v = d.lastPathComponent.replacingOccurrences(of: "gradle-", with: "")
                .replacingOccurrences(of: "-bin", with: "").replacingOccurrences(of: "-all", with: "")
            let proyectos = usos[v] ?? []
            // El que usa un proyecto también es Seguro (el wrapper lo descarga solo al compilar), pero cuesta una
            // descarga: queda para «Liberar al máximo» y el modo normal no lo marca.
            r.append(Elemento(
                nombre: "Gradle \(v)",
                detalle: "El programa Gradle \(v), descargado por el wrapper de un proyecto.",
                consecuencia: proyectos.isEmpty
                    ? "Si algún proyecto lo vuelve a pedir, se descarga solo (unos 150 MB)."
                    : "La próxima vez que compiles \(Formato.lista(proyectos)), el wrapper lo vuelve a descargar solo (unos 150 MB; necesita internet).",
                rutas: [d], categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                motivos: [proyectos.isEmpty
                    ? .bien("checkmark.circle.fill", "Ningún proyecto lo usa", "Ninguno de tus proyectos usa Gradle \(v).")
                    : .info("hammer.fill", "Lo usa \(proyectos[0])",
                            "Lo usa \(Formato.lista(proyectos)). No se pierde nada, porque se vuelve a descargar solo al compilar, pero necesita internet: por eso no lo marco solo, solo con «Liberar al máximo».")],
                enUso: .gradleVersion(v), dueno: "Gradle",
                nivel: proyectos.isEmpty ? .normal : .maximo,
                costes: proyectos.isEmpty ? [] : [.descarga(bytes: c.indice.bytes(de: d))]))
        }

        var compilacion: [URL] = []
        for h in Rutas.hijos(Rutas.enHome(".gradle/caches")) where Rutas.esCarpeta(h) {
            let n = h.lastPathComponent
            if n.first?.isNumber == true {
                let proyectos = usos[n] ?? []
                // De una versión que usan tus proyectos, las transformaciones se ofrecen aparte: Gradle las recalcula sin
                // internet a partir de las dependencias ya descargadas.
                let transformaciones = deMayorAMenor(Rutas.hijos(h).filter { Self.transformacionesGradle.contains($0.lastPathComponent) }, c)
                if !proyectos.isEmpty && !transformaciones.isEmpty {
                    r.append(transformacionesDeGradle(n, transformaciones, proyectos: proyectos, c))
                }
                let resto = proyectos.isEmpty || transformaciones.isEmpty
                    ? [h] : deMayorAMenor(Rutas.hijos(h).filter { !Self.transformacionesGradle.contains($0.lastPathComponent) }, c)
                guard !resto.isEmpty else { continue }
                r.append(Elemento(
                    nombre: "Caché de Gradle \(n)",
                    detalle: resto.count == 1 ? "Archivos que Gradle \(n) guarda para compilar más rápido."
                        : "Lo demás que Gradle \(n) guarda para compilar más rápido: huellas de archivos, compilación de Java…",
                    consecuencia: proyectos.isEmpty
                        ? "Nada: ningún proyecto usa esta versión."
                        : "La próxima compilación de \(Formato.lista(proyectos)) será más lenta mientras se regenera.",
                    rutas: resto, tamanosRutas: tamanos(resto, c), categoria: .desarrollo, riesgo: .seguro, seleccionado: proyectos.isEmpty,
                    motivos: [proyectos.isEmpty
                        ? .bien("checkmark.circle.fill", "Versión sin usar", "Ninguno de tus proyectos usa Gradle \(n).")
                        : .info("hammer.fill", "Lo usa \(proyectos[0])", "Es la versión de \(Formato.lista(proyectos)).")],
                    enUso: .gradleVersion(n), dueno: "Gradle"))
            } else if n == "modules-2" {
                // No se pierde nada (se vuelve a descargar), pero cuesta internet y tiempo: solo «Liberar al máximo».
                let bytes = c.indice.bytes(de: h)
                r.append(Elemento(
                    nombre: "Dependencias descargadas por Gradle",
                    detalle: "Todas las librerías que descargaron tus proyectos de Android.",
                    consecuencia: "La próxima compilación las vuelve a descargar: necesita internet, puede tardar varios minutos y usar bastantes datos.",
                    rutas: [h], categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                    motivos: [.info("arrow.down.circle.fill", "Se vuelve a descargar", "No se pierde nada, pero descargarlo todo otra vez lleva tiempo y necesita internet: por eso no lo marco solo, solo con «Liberar al máximo».")],
                    enUso: .gradle, dueno: "Gradle", nivel: .maximo, costes: [.descarga(bytes: bytes)]))
            } else {
                compilacion.append(h)
            }
        }
        if !compilacion.isEmpty {
            r.append(Elemento(
                nombre: "Cachés de compilación de Gradle",
                detalle: "Transformaciones y resultados intermedios (\(Formato.listaCorta(compilacion.map(\.lastPathComponent)))).",
                consecuencia: "Gradle los regenera en la próxima compilación.",
                rutas: compilacion, categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("arrow.triangle.2.circlepath", "Se regenera", "Gradle los vuelve a crear al compilar.")],
                enUso: .gradle, dueno: "Gradle"))
        }
        return r
    }

    /// Lo que Gradle calcula a partir de lo ya descargado (dentro de caches/<versión>): librerías transformadas,
    /// el API de Gradle generado y los scripts de compilación compilados.
    private static let transformacionesGradle: Set<String> = ["transforms", "generated-gradle-jars", "kotlin-dsl", "groovy-dsl",
                                                              "dependencies-accessors"]

    /// «Transformaciones de Gradle <v>»: Seguro, y marcado si nada cambió dentro en 24 h. Con 1 h o más, solo en «Liberar
    /// al máximo» (nivel .maximo). Si un daemon de esa versión está funcionando, el Evaluador (`.gradleVersion`) lo
    /// desmarca y Limpiador se lo salta.
    private func transformacionesDeGradle(_ v: String, _ rutas: [URL], proyectos: [String], _ c: Contexto) -> Elemento {
        let cambio = ultimoCambio(rutas, c)
        let horas = cambio.map { Date().timeIntervalSince($0) / 3600 } ?? .infinity
        let quieto: Motivo = horas >= 24
            ? .bien("moon.zzz.fill", "Sin usar desde \(Formato.haceCuanto(cambio).lowercased())",
                    "Nada cambió dentro desde \(Formato.haceCuanto(cambio).lowercased()): Gradle \(v) no las está usando.")
            : .info("clock.fill", "Usadas hace poco",
                    "Gradle \(v) las usó \(Formato.haceCuanto(cambio).lowercased()): las marco solas cuando pasen 24 h sin compilar con esta versión"
                    + (horas >= 1 ? "; «Liberar al máximo» ya las incluye, porque llevan más de 1 h sin cambios." : "."))
        return Elemento(
            nombre: "Transformaciones de Gradle \(v)",
            detalle: "Lo que Gradle \(v) calcula a partir de las dependencias ya descargadas: librerías transformadas, el API de Gradle y los scripts de compilación compilados (\(Formato.listaCorta(rutas.map(\.lastPathComponent).sorted()))).",
            consecuencia: "Gradle las recalcula sin internet a partir de las dependencias ya descargadas; la primera compilación de \(Formato.lista(proyectos)) con Gradle \(v) será más lenta.",
            rutas: rutas, tamanosRutas: tamanos(rutas, c), ultimoUso: cambio, categoria: .desarrollo, riesgo: .seguro,
            seleccionado: horas >= 1,
            motivos: [.bien("arrow.triangle.2.circlepath", "Se regenera sin internet",
                            "Salen de las dependencias que ya tienes descargadas: no hace falta volver a bajar nada."), quieto],
            enUso: .gradleVersion(v), dueno: "Gradle", nivel: horas >= 1 && horas < 24 ? .maximo : .normal,
            costes: proyectos.map { .recompilacion(proyecto: $0) }, cambioAnalizado: cambio)
    }

    /// Lo que ocupa cada ruta: lo que sabe el índice o, si es una carpeta pequeña que no registró, recorriéndola
    /// (para que lo que queda de un proyecto con una llave de 3 KB no diga «0 KB»).
    private func tamanos(_ urls: [URL], _ c: Contexto) -> [Int64] {
        urls.map { u in
            if let i = c.indice.info(u.path) { return i.bytes }
            return Rutas.esCarpeta(u) && c.indice.estaIndexada(u.path) ? Tamanos.recorriendo(u.path) : c.indice.bytes(de: u)
        }
    }

    /// Las rutas de mayor a menor, según el índice.
    private func deMayorAMenor(_ urls: [URL], _ c: Contexto) -> [URL] {
        urls.map { ($0, c.indice.bytes(de: $0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Lo último que cambió dentro de esas rutas (archivos y carpetas). El índice lo sabe de las carpetas que registró
    /// (las de 1 MB o más, con todo lo de dentro); las demás, que son pequeñas, se recorren aquí.
    private func ultimoCambio(_ urls: [URL], _ c: Contexto) -> Date? {
        var mejor = 0
        for u in urls {
            mejor = max(mejor, c.indice.info(u.path)?.masReciente ?? Fechas.ultimoCambio([u.path]))
        }
        return mejor > 0 ? Date(timeIntervalSince1970: TimeInterval(mejor)) : nil
    }

    private func xcode() -> [Elemento] {
        var r: [Elemento] = []
        var modulos: [URL] = []
        for h in Rutas.hijos(Rutas.enHome("Library/Developer/Xcode/DerivedData")) where Rutas.esCarpeta(h) {
            let n = h.lastPathComponent
            if n.hasSuffix(".noindex") { modulos.append(h); continue }
            let partes = n.split(separator: "-")
            let proyecto = partes.count > 1 ? partes.dropLast().joined(separator: "-") : n
            let espacio = NSDictionary(contentsOf: h.appendingPathComponent("info.plist"))?["WorkspacePath"] as? String
            let existe = espacio.map { Rutas.existe($0) } ?? true
            r.append(Elemento(
                nombre: "DerivedData de \(proyecto)",
                detalle: "Compilación intermedia de Xcode" + (espacio.map { " para \(Formato.rutaCorta($0))." } ?? "."),
                consecuencia: existe ? "Xcode la regenera la próxima vez que compiles (esa compilación será más lenta)."
                                     : "Nada: el proyecto ya no existe.",
                rutas: [h], categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                motivos: [existe ? .bien("arrow.triangle.2.circlepath", "Se regenera", "Xcode la vuelve a crear al compilar.")
                                 : .bien("questionmark.folder.fill", "Proyecto borrado", "El proyecto al que pertenecía ya no existe.")],
                enUso: Self.xcodeUso, dueno: "Xcode"))
        }
        if !modulos.isEmpty {
            r.append(Elemento(
                nombre: "Caché de módulos de Xcode", detalle: "Módulos precompilados que comparten tus proyectos.",
                consecuencia: "Xcode los regenera al compilar.", rutas: modulos, categoria: .desarrollo,
                riesgo: .seguro, seleccionado: true,
                motivos: [.bien("arrow.triangle.2.circlepath", "Se regenera", "Xcode los vuelve a crear.")],
                enUso: Self.xcodeUso, dueno: "Xcode"))
        }
        for fecha in Rutas.hijos(Rutas.enHome("Library/Developer/Xcode/Archives")) where Rutas.esCarpeta(fecha) {
            for a in Rutas.hijos(fecha) where a.pathExtension == "xcarchive" {
                r.append(Elemento(
                    nombre: "Archivo de Xcode: \(a.deletingPathExtension().lastPathComponent) (\(fecha.lastPathComponent))",
                    detalle: "Una versión de tu app que archivaste para publicarla.",
                    consecuencia: "Ya no podrás volver a exportar esa versión ni leer bien sus informes de fallos.",
                    rutas: [a], categoria: .desarrollo, riesgo: .revisar,
                    motivos: [.aviso("ladybug.fill", "Símbolos de fallos",
                                     "Contiene los símbolos (dSYM) de esa versión: sirven para entender los informes de fallos de la app publicada.")],
                    dueno: "Xcode"))
            }
        }
        for tipo in ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport", "macOS DeviceSupport"] {
            let versiones = Rutas.hijos(Rutas.enHome("Library/Developer/Xcode/\(tipo)")).filter { Rutas.esCarpeta($0) }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            for (i, v) in versiones.enumerated() {
                let ultima = i == versiones.count - 1
                r.append(Elemento(
                    nombre: "Soporte de dispositivo: \(v.lastPathComponent)",
                    detalle: "Símbolos que Xcode copió de un dispositivo que conectaste.",
                    consecuencia: "Si conectas un dispositivo con esa versión, Xcode los vuelve a copiar (tarda unos minutos).",
                    rutas: [v], categoria: .desarrollo, riesgo: .seguro, seleccionado: !ultima,
                    motivos: [ultima ? .info("iphone", "Versión más reciente", "Es la versión más nueva que conectaste.")
                                     : .bien("clock.arrow.circlepath", "Versión antigua", "Ya conectaste versiones más nuevas.")],
                    dueno: "Xcode"))
            }
        }
        return r
    }

    /// Las Command Line Tools (/Library/Developer/CommandLineTools) cuando la terminal ya usa las herramientas de Xcode
    /// (xcode-select apunta dentro de una Xcode.app): probablemente sobran. Son del sistema y quitarlas pide la contraseña
    /// de administrador, así que no se ofrecen para borrar: solo una nota con cuánto ocupan y cómo se quitarían a mano.
    /// Medirlas tarda un par de segundos (du): se hace mientras se analiza lo demás.
    static func notaDeLineaDeComandos() -> NotaGrande? {
        let clt = "/Library/Developer/CommandLineTools"
        guard !Rutas.casaDePrueba, Rutas.esCarpeta(URL(fileURLWithPath: clt)) else { return nil }
        let elegida = Shell.ejecutar("/usr/bin/xcode-select", ["-p"], limite: 10).salida.trimmingCharacters(in: .whitespacesAndNewlines)
        guard elegida.hasPrefix("/Applications/"), elegida.contains(".app/Contents/Developer") else { return nil }
        let bytes = Tamanos.de(URL(fileURLWithPath: clt))
        guard bytes >= 100_000_000 else { return nil }
        let xcode = Rutas.nombre(elegida.components(separatedBy: "/Contents/Developer")[0])
        return NotaGrande(
            categoria: .desarrollo, titulo: "Command Line Tools que \((xcode as NSString).deletingPathExtension) ya trae",
            texto: "La terminal usa las herramientas de \(xcode) (xcode-select apunta ahí), así que las Command Line Tools de \(clt) probablemente no se usan. No las ofrezco para borrar: son del sistema y hace falta tu contraseña de administrador. Si quieres quitarlas, en la Terminal: «sudo rm -rf \(clt)» y «sudo pkgutil --forget com.apple.pkg.CLTools_Executables». Si algo las vuelve a pedir (Homebrew, por ejemplo), se reinstalan con «xcode-select --install».",
            ruta: clt, bytes: bytes)
    }

    /// Playwright y Puppeteer guardan un navegador por versión: las antiguas sobran.
    private func navegadoresDePrueba() -> [Elemento] {
        var r: [Elemento] = []
        func versiones(_ lista: [URL], herramienta: String, navegador: String) {
            let orden = lista.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            for (i, v) in orden.enumerated() {
                let ultima = i == orden.count - 1
                r.append(Elemento(
                    nombre: "\(herramienta): \(navegador) \(v.lastPathComponent)",
                    detalle: "Navegador que \(herramienta) descargó para pruebas automáticas.",
                    consecuencia: ultima ? "\(herramienta) lo vuelve a descargar cuando lo necesite." : "Nada: ya tienes una versión más nueva.",
                    rutas: [v], categoria: .desarrollo, riesgo: .seguro, seleccionado: !ultima,
                    motivos: [ultima ? .info("globe", "Versión actual", "Es la versión más reciente descargada.")
                                     : .bien("clock.arrow.circlepath", "Versión antigua", "Hay una versión más nueva de \(navegador).")],
                    dueno: herramienta))
            }
        }
        var porNavegador: [String: [URL]] = [:]
        for h in Rutas.hijos(Rutas.enHome("Library/Caches/ms-playwright")) where Rutas.esCarpeta(h) {
            let n = h.lastPathComponent
            guard let guion = n.lastIndex(of: "-") else { continue }
            porNavegador[String(n[..<guion]), default: []].append(h)
        }
        for (nav, lista) in porNavegador { versiones(lista, herramienta: "Playwright", navegador: nav) }
        for nav in Rutas.hijos(Rutas.enHome(".cache/puppeteer")) where Rutas.esCarpeta(nav) {
            versiones(Rutas.hijos(nav).filter { Rutas.esCarpeta($0) }, herramienta: "Puppeteer", navegador: nav.lastPathComponent)
        }
        return r
    }

    private static let patronIDE = try! NSRegularExpression(pattern: "^([A-Za-z]+?)(\\d{4}\\.\\d+(?:\\.\\d+)?)$")

    private static func versionIDE(_ nombre: String) -> (producto: String, version: String)? {
        guard let m = patronIDE.firstMatch(in: nombre, range: NSRange(nombre.startIndex..., in: nombre)),
              let rp = Range(m.range(at: 1), in: nombre), let rv = Range(m.range(at: 2), in: nombre) else { return nil }
        return (String(nombre[rp]), String(nombre[rv]))
    }

    /// Android Studio e IDEs de JetBrains dejan una carpeta por versión. Las de versiones anteriores sobran.
    private func versionesAnterioresDeIDEs() -> [Elemento] {
        var r: [Elemento] = []
        let lugares: [(String, String, Riesgo, Bool)] = [
            ("Library/Caches/Google", "Caché", .seguro, true), ("Library/Caches/JetBrains", "Caché", .seguro, true),
            ("Library/Logs/Google", "Registros", .seguro, true), ("Library/Logs/JetBrains", "Registros", .seguro, true),
            ("Library/Application Support/Google", "Configuración", .revisar, false),
            ("Library/Application Support/JetBrains", "Configuración", .revisar, false),
        ]
        for (rel, tipo, riesgo, sel) in lugares {
            var porProducto: [String: [(URL, String)]] = [:]
            for h in Rutas.hijos(Rutas.enHome(rel)) where Rutas.esCarpeta(h) {
                guard let (producto, version) = Self.versionIDE(h.lastPathComponent) else { continue }
                porProducto[producto, default: []].append((h, version))
            }
            for (producto, versiones) in porProducto where versiones.count > 1 {
                let orden = versiones.sorted { $0.1.compare($1.1, options: .numeric) == .orderedAscending }
                let actual = orden.last!.1
                let nombre = producto == "AndroidStudio" ? "Android Studio" : producto
                for (url, v) in orden.dropLast() {
                    var rutas = [url]
                    // La caché de una versión anterior también guarda su historial local: no se copia a la nueva.
                    let historial = url.appendingPathComponent(Self.historialLocalIDE)
                    if tipo == "Caché" && Rutas.esCarpeta(historial) {
                        rutas = Rutas.hijos(url).filter { $0.lastPathComponent != Self.historialLocalIDE }
                        r.append(historialLocal(historial, app: nombre, version: v, enUso: nil))
                    }
                    guard !rutas.isEmpty else { continue }
                    r.append(Elemento(
                        nombre: "\(tipo) de \(nombre) \(v) (versión anterior)",
                        detalle: "\(tipo) de una versión de \(nombre) que ya actualizaste a la \(actual).",
                        consecuencia: tipo == "Configuración"
                            ? "Al actualizar, la versión \(actual) ya copió tus ajustes: esta copia antigua no se usa."
                            : "Nada: la versión \(actual) usa su propia carpeta.",
                        rutas: rutas, categoria: .desarrollo, riesgo: riesgo, seleccionado: sel,
                        motivos: [.bien("clock.arrow.circlepath", "Versión anterior", "Ya usas \(nombre) \(actual).")],
                        dueno: nombre))
                }
            }
        }
        return r
    }

    /// Dentro de la caché de Android Studio y de los IDE de JetBrains, la carpeta con el historial local
    /// (Local History): la copia de cada edición, la única forma de recuperar cambios que no están en git.
    private static let historialLocalIDE = "LocalHistory"

    /// La caché de Android Studio o de un IDE de JetBrains: todo se regenera salvo el historial local, que va aparte
    /// y sin marcar. nil si no tiene historial local (entonces es una caché normal).
    private func cachesDeIDE(_ h: URL, app: String, clave: String) -> [Elemento]? {
        let historial = h.appendingPathComponent(Self.historialLocalIDE)
        guard Rutas.esCarpeta(historial) else { return nil }
        var r: [Elemento] = []
        let resto = Rutas.hijos(h).filter { $0.lastPathComponent != Self.historialLocalIDE }
        if !resto.isEmpty { r.append(cacheDeApp(app: app, clave: clave, rutas: resto)) }
        r.append(historialLocal(historial, app: app, version: nil, enUso: .app(nombre: app, claves: [clave, app])))
        return r
    }

    private func historialLocal(_ url: URL, app: String, version: String?, enUso: EnUso?) -> Elemento {
        Elemento(
            nombre: "Historial local de \(app)" + (version.map { " \($0) (versión anterior)" } ?? ""),
            detalle: "Copia de cada cambio que hiciste en tus archivos desde \(app) (Local History).",
            consecuencia: "Pierdes la única forma de recuperar cambios que no guardaste en git o archivos que borraste desde \(app).",
            rutas: [url], categoria: version == nil ? .cachesApps : .desarrollo, riesgo: .cuidado,
            motivos: [.aviso("clock.arrow.circlepath", "No es caché",
                             "\(app) guarda aquí el historial de tus ediciones y no lo puede volver a crear.")],
            enUso: enUso, dueno: app)
    }

    /// Una carpeta con una subcarpeta por versión: sobran las antiguas.
    /// Se conservan la más nueva y las de `conservar` (la predeterminada de la herramienta).
    private func versionesAntiguas(en carpeta: URL, herramienta: String, que: String, conservar: Set<String> = [],
                                   consecuencia: String) -> [Elemento] {
        let versiones = Rutas.hijos(carpeta)
            .filter { !$0.lastPathComponent.hasPrefix(".") && Rutas.esCarpeta($0)
                && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        guard versiones.count > 1, let nueva = versiones.last?.lastPathComponent else { return [] }
        return versiones.dropLast().filter { !conservar.contains($0.lastPathComponent) }.map { v in
            var motivos: [Motivo] = [.info("clock.arrow.circlepath", "Versión anterior",
                                           "Tienes una más nueva (\(nueva)). \(consecuencia)")]
            if !conservar.isEmpty {
                motivos.append(.bien("checkmark.circle.fill", "No es la predeterminada",
                                     "La que \(herramienta) usa por defecto es \(Formato.lista(conservar.sorted())); esa no se toca."))
            }
            return Elemento(
                nombre: "\(que) \(v.lastPathComponent) (\(herramienta))",
                detalle: "\(que) instalado con \(herramienta). La versión más nueva que tienes es \(nueva).",
                consecuencia: consecuencia,
                rutas: [v], categoria: .desarrollo, riesgo: .revisar, motivos: motivos,
                enUso: .rutas(nombre: herramienta, raiz: v.path), dueno: herramienta)
        }
    }

    /// Node, Python, Rust, Java… instalados en varias versiones: sobran las antiguas que no son la predeterminada.
    private func versionesDeLenguajes(_ c: Contexto) -> [Elemento] {
        func leer(_ rel: String) -> String? {
            (try? String(contentsOf: Rutas.enHome(rel), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let reinstalar = "Si algún proyecto pide esta versión exacta, tendrás que volver a instalarla."
        var r: [Elemento] = []

        // nvm: la predeterminada puede ser «20», «v20.11.0» o «lts/iron».
        let nvm = Rutas.enHome(".nvm/versions/node")
        var nodeNvm = Set<String>()
        if let a = leer(".nvm/alias/default") {
            nodeNvm = Set(Rutas.hijos(nvm).map(\.lastPathComponent).filter { $0 == a || $0 == "v" + a || $0.hasPrefix("v" + a + ".") })
        }
        r += versionesAntiguas(en: nvm, herramienta: "nvm", que: "Node", conservar: nodeNvm, consecuencia: reinstalar)

        // fnm: «aliases/default» es un enlace a la versión predeterminada.
        for base in [".local/share/fnm", "Library/Application Support/fnm"] {
            let defecto = Rutas.enHome(base + "/aliases/default").resolvingSymlinksInPath().pathComponents
            let nodeFnm = defecto.firstIndex(of: "node-versions").flatMap { $0 + 1 < defecto.count ? defecto[$0 + 1] : nil }
            r += versionesAntiguas(en: Rutas.enHome(base + "/node-versions"), herramienta: "fnm", que: "Node",
                                   conservar: Set([nodeFnm].compactMap { $0 }), consecuencia: reinstalar)
        }

        // Volta guarda la predeterminada en platform.json.
        var nodeVolta = Set<String>()
        if let datos = try? Data(contentsOf: Rutas.enHome(".volta/tools/user/platform.json")),
           let json = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
           let v = (json["node"] as? [String: Any])?["runtime"] as? String {
            nodeVolta.insert(v)
        }
        r += versionesAntiguas(en: Rutas.enHome(".volta/tools/image/node"), herramienta: "Volta", que: "Node",
                               conservar: nodeVolta, consecuencia: reinstalar)

        // pyenv: «~/.pyenv/version» tiene la global (una por línea). «3.11» vale para cualquier 3.11.x, y un entorno
        // de pyenv-virtualenv (un enlace dentro de versions/) apunta a la versión donde vive.
        let versionesPyenv = Rutas.enHome(".pyenv/versions")
        func versionDe(_ u: URL) -> String? {
            let real = u.resolvingSymlinksInPath().path
            guard let r = real.range(of: "/.pyenv/versions/") else { return nil }
            return real[r.upperBound...].split(separator: "/").first.map(String.init)
        }
        var pyenv = Set<String>()
        for g in (leer(".pyenv/version") ?? "").split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !g.isEmpty {
            for v in Rutas.hijos(versionesPyenv) where v.lastPathComponent == g || v.lastPathComponent.hasPrefix(g + ".") {
                pyenv.insert(v.lastPathComponent)
            }
            if let v = versionDe(versionesPyenv.appendingPathComponent(g)) { pyenv.insert(v) }
        }
        for enlace in Rutas.hijos(versionesPyenv) where Self.esEnlace(enlace) {
            if let v = versionDe(enlace) { pyenv.insert(v) }
        }
        var dePyenv = versionesAntiguas(en: versionesPyenv, herramienta: "pyenv", que: "Python", conservar: pyenv, consecuencia: reinstalar)
        // Una versión con entornos dentro (pyenv-virtualenv) se los lleva al borrarla.
        for i in dePyenv.indices {
            let entornos = Rutas.hijos(dePyenv[i].rutaPrincipal.appendingPathComponent("envs")).map(\.lastPathComponent)
            guard !entornos.isEmpty else { continue }
            dePyenv[i].riesgo = .cuidado
            dePyenv[i].consecuencia = "Se borran también sus entornos (\(Formato.listaCorta(entornos))) con todos sus paquetes. " + reinstalar
            dePyenv[i].motivos.insert(.aviso("shippingbox.fill", "Tiene entornos dentro",
                                             "Dentro hay \(entornos.count == 1 ? "un entorno" : "\(entornos.count) entornos") de pyenv-virtualenv: \(Formato.listaCorta(entornos))."), at: 0)
        }
        r += dePyenv
        r += pythonsDeUv(c)

        // rustup: la predeterminada está en settings.toml.
        var rust = Set<String>()
        if let ajustes = leer(".rustup/settings.toml"),
           let linea = ajustes.split(separator: "\n").first(where: { $0.hasPrefix("default_toolchain") }) {
            rust.insert(linea.split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? "")
        }
        r += versionesAntiguas(en: Rutas.enHome(".rustup/toolchains"), herramienta: "rustup", que: "Rust",
                               conservar: rust, consecuencia: reinstalar)

        // SDKMAN: cada herramienta (java, gradle, kotlin…) tiene un enlace «current».
        for candidato in Rutas.hijos(Rutas.enHome(".sdkman/candidates")) where Rutas.esCarpeta(candidato) {
            let actual = candidato.appendingPathComponent("current").resolvingSymlinksInPath().lastPathComponent
            r += versionesAntiguas(en: candidato, herramienta: "SDKMAN", que: candidato.lastPathComponent.capitalized,
                                   conservar: [actual], consecuencia: reinstalar)
        }

        // rbenv: «~/.rbenv/version» tiene la versión global de Ruby.
        let ruby = Set((leer(".rbenv/version") ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        r += versionesAntiguas(en: Rutas.enHome(".rbenv/versions"), herramienta: "rbenv", que: "Ruby",
                               conservar: ruby, consecuencia: reinstalar)

        // asdf y mise: una carpeta por herramienta (nodejs, python…) y otra por versión.
        // Las globales están en ~/.tool-versions y en ~/.config/mise/config.toml.
        var globales: [String: Set<String>] = [:]
        for linea in (leer(".tool-versions") ?? "").split(separator: "\n") {
            let partes = linea.split(separator: " ").map(String.init)
            if partes.count >= 2 { globales[partes[0], default: []].formUnion(partes.dropFirst()) }
        }
        for linea in (leer(".config/mise/config.toml") ?? "").split(separator: "\n") where linea.contains("=") {
            let partes = linea.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'[]")) }
            if partes.count == 2 { globales[partes[0], default: []].insert(partes[1]) }
        }
        for (base, gestor) in [(".asdf/installs", "asdf"), (".local/share/mise/installs", "mise")] {
            for herramienta in Rutas.hijos(Rutas.enHome(base)) where Rutas.esCarpeta(herramienta) {
                let n = herramienta.lastPathComponent
                r += versionesAntiguas(en: herramienta, herramienta: gestor, que: n.capitalized,
                                       conservar: globales[n] ?? [], consecuencia: reinstalar)
            }
        }

        r += versionesAntiguas(en: Rutas.enHome("Library/Caches/Cypress"), herramienta: "Cypress", que: "Navegador de pruebas",
                               consecuencia: "Si un proyecto pide esta versión de Cypress, la vuelve a descargar al instalarse.")
        return r
    }

    private static let patronPythonUv = try! NSRegularExpression(pattern: #"^(cpython|pypy|graalpy)-(\d+)\.(\d+)\.(\d+)(.*)$"#)

    /// uv instala una carpeta por versión exacta de Python. Solo sobra un parche viejo de la misma serie (3.12.1 si
    /// tienes 3.12.4): las series distintas (3.8, 3.11…) pueden ser justo las que piden tus proyectos y entornos.
    private func pythonsDeUv(_ c: Contexto) -> [Elemento] {
        var grupos: [String: [(url: URL, parche: Int)]] = [:]
        for h in Rutas.hijos(Rutas.enHome(".local/share/uv/python")) where Rutas.esCarpeta(h) && !Self.esEnlace(h) {
            let n = h.lastPathComponent
            guard let m = Self.patronPythonUv.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) else { continue }
            func parte(_ i: Int) -> String { Range(m.range(at: i), in: n).map { String(n[$0]) } ?? "" }
            // Misma implementación, serie X.Y, variante, sistema y arquitectura: solo cambia el parche.
            grupos["\(parte(1))-\(parte(2)).\(parte(3))\(parte(5))", default: []].append((h, Int(parte(4)) ?? 0))
        }
        // Entornos virtuales que dependen de un Python concreto («home = …» en su pyvenv.cfg).
        var entornos: [String] = c.indice.artefactos.filter { $0.tipo == .venv }.map(\.ruta)
        entornos += Rutas.hijos(Rutas.home).filter { $0.lastPathComponent.hasPrefix(".venv") }.map(\.path)
        for base in [".local/share/uv/tools", ".local/pipx/venvs", ".virtualenvs"] {
            entornos += Rutas.hijos(Rutas.enHome(base)).map(\.path)
        }
        let usados: [String] = entornos.compactMap { e in
            guard let texto = try? String(contentsOfFile: e + "/pyvenv.cfg", encoding: .utf8),
                  let linea = texto.split(separator: "\n").first(where: { $0.hasPrefix("home") }),
                  let valor = linea.split(separator: "=", maxSplits: 1).last else { return nil }
            return Rutas.real(URL(fileURLWithPath: valor.trimmingCharacters(in: .whitespaces)))
        }

        var r: [Elemento] = []
        for (_, versiones) in grupos where versiones.count > 1 {
            let orden = versiones.sorted { $0.parche < $1.parche }
            let nueva = orden.last!.url.lastPathComponent
            for v in orden.dropLast() {
                let real = Rutas.real(v.url) + "/"
                if usados.contains(where: { ($0 + "/").hasPrefix(real) }) || c.apps.comandoDentro(de: v.url.path) != nil
                    || c.procesos.usando(v.url.path) != nil { continue }
                r.append(Elemento(
                    nombre: "Python \(v.url.lastPathComponent) (uv)",
                    detalle: "Python instalado con uv. Tienes otro más nuevo de la misma serie: \(nueva).",
                    consecuencia: "Los entornos creados con esta versión exacta dejarán de funcionar hasta que la reinstales con «uv python install» (necesita internet).",
                    rutas: [v.url], categoria: .desarrollo, riesgo: .revisar,
                    motivos: [.info("clock.arrow.circlepath", "Parche anterior", "Hay una versión más nueva de la misma serie y ningún entorno de los que encontré usa esta.")],
                    enUso: .rutas(nombre: "Python", raiz: v.url.path), dueno: "uv"))
            }
        }
        return r
    }

    private static let patronVersion = try! NSRegularExpression(pattern: #"^v?\d+(\.\d+)+"#)

    private static func pareceVersion(_ n: String) -> Bool {
        patronVersion.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
    }

    /// «base.sqlite-wal», «-shm», «-journal»: no se ofrecen solos (van con su base, y sin ella la dejan rota).
    private static func esCompaneroDeBase(_ ruta: String) -> Bool {
        let l = ruta.lowercased()
        return l.hasSuffix("-wal") || l.hasSuffix("-shm") || l.hasSuffix("-journal") || l.hasSuffix(".wal")
    }

    /// Una base de datos SQLite junto con sus archivos -wal, -shm y -journal (si existen).
    private static func conCompaneros(_ u: URL) -> [URL] {
        let ext = u.pathExtension.lowercased()
        guard ["sqlite", "sqlite3", "db"].contains(ext) else { return [u] }
        return [u] + ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: u.path + $0) }.filter(Rutas.existe)
    }

    private static func esEnlace(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// Programas que se actualizan solos y dejan la versión anterior guardada (comprobado en cada uno).
    private static let programasAutoactualizables: Set<String> = ["codex", "claude code", "cursor-agent", "cursor agent"]

    /// Programas que se actualizan solos y guardan cada versión en su propia carpeta («releases», «versions»):
    /// Codex, Claude Code, Cursor Agent… Solo usan una; las demás se quedan ahí ocupando espacio.
    private func versionesDeProgramas(_ c: Contexto) -> [Elemento] {
        // Gestores de versiones de lenguajes: ahí una versión vieja puede ser la que pide un proyecto (van aparte).
        // (~/.local/share se recorre aparte, carpeta por carpeta.)
        let lenguajes: Set<String> = [".Trash", ".git", ".npm", ".nvm", ".pyenv", ".rbenv", ".rustup", ".sdkman", ".asdf", ".local",
                                      ".volta", ".m2", ".cargo", ".cache", ".gradle", ".android", ".jenv", ".goenv", ".nodenv"]
        var carpetas: [(carpeta: URL, programa: String)] = []
        /// Un gestor de versiones (tfenv, swiftenv, anyenv…): sus versiones se instalan a propósito, no por actualizarse.
        func esGestor(_ u: URL) -> Bool {
            let n = u.lastPathComponent.lowercased()
            return n.hasSuffix("env") || n.hasSuffix("envs")
                || (Rutas.existe(u.appendingPathComponent("version")) && Rutas.esCarpeta(u.appendingPathComponent("versions")))
        }
        func buscar(en raiz: URL, programa: String, profundidad: Int) {
            guard profundidad > 0, !esGestor(raiz) else { return }
            for h in Rutas.hijos(raiz) where Rutas.esCarpeta(h) && !Self.esEnlace(h) {
                let n = h.lastPathComponent.lowercased()
                if n == "versions" || n == "releases" { carpetas.append((h, programa)) }
                else if !["node_modules", "sessions", "logs", "cache", "extensions", "plugins"].contains(n) {
                    buscar(en: h, programa: programa, profundidad: profundidad - 1)
                }
            }
        }
        for h in Rutas.hijos(Rutas.home) where h.lastPathComponent.hasPrefix(".") && Rutas.esCarpeta(h) && !lenguajes.contains(h.lastPathComponent) {
            buscar(en: h, programa: String(h.lastPathComponent.dropFirst()).capitalized, profundidad: 3)
        }
        for h in Rutas.hijos(Rutas.enHome(".local/share")) where Rutas.esCarpeta(h) && !["uv", "fnm", "mise"].contains(h.lastPathComponent) {
            buscar(en: h, programa: h.lastPathComponent.capitalized, profundidad: 2)
        }
        // La app de Claude guarda cada versión de Claude Code que descarga.
        carpetas.append((Rutas.enHome("Library/Application Support/Claude/claude-code"), "Claude Code"))

        var r: [Elemento] = []
        for (carpeta, programa) in carpetas {
            let versiones = Rutas.hijos(carpeta)
                .filter { Rutas.esCarpeta($0) && !Self.esEnlace($0) && Self.pareceVersion($0.lastPathComponent) }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            guard versiones.count > 1, let nueva = versiones.last?.lastPathComponent else { continue }
            // Cuál usa: la que diga un enlace («current») o un archivo de versión, y las que estén funcionando ahora.
            var usadas: Set<String> = [nueva]
            var confirmada = false
            for f in Rutas.hijos(carpeta.deletingLastPathComponent()) + Rutas.hijos(carpeta) {
                if Self.esEnlace(f) {
                    let destino = f.resolvingSymlinksInPath().lastPathComponent
                    if versiones.contains(where: { $0.lastPathComponent == destino }) { usadas.insert(destino); confirmada = true }
                } else if !Rutas.esCarpeta(f), (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max < 256,
                          let texto = try? String(contentsOf: f, encoding: .utf8) {
                    // Un archivo de versión dice exactamente cuál («0.159.2-aarch64-apple-darwin»), no una nota cualquiera.
                    let valor = texto.trimmingCharacters(in: .whitespacesAndNewlines)
                    for v in versiones where valor == v.lastPathComponent { usadas.insert(v.lastPathComponent); confirmada = true }
                }
            }
            // Las que están funcionando ahora y las que abre un comando de la terminal (aunque no sea la más nueva).
            // (Se miran los ejecutables reales: un programa abierto con un enlace, como «codex», no lleva la ruta en ps.)
            for v in versiones where c.procesos.usando(v.path) != nil || c.apps.comandoDentro(de: v.path) != nil {
                usadas.insert(v.lastPathComponent)
                confirmada = true
            }
            // Solo los programas que sé que se actualizan solos y dejan atrás su versión anterior se marcan solos.
            let seguro = confirmada && Self.programasAutoactualizables.contains(programa.lowercased())
            for v in versiones where !usadas.contains(v.lastPathComponent) {
                r.append(Elemento(
                    nombre: "\(programa) \(v.lastPathComponent) (versión anterior)",
                    detalle: "Una versión anterior de \(programa) que se quedó guardada al actualizarse. Ahora usa la \(Formato.lista(usadas.sorted())).",
                    consecuencia: seguro ? "Nada: \(programa) usa la versión \(Formato.lista(usadas.sorted()))."
                                         : "Si algo sigue usando esta versión exacta, tendrás que volver a instalarla.",
                    rutas: [v], categoria: .desarrollo, riesgo: seguro ? .seguro : .revisar, seleccionado: seguro,
                    motivos: [confirmada
                        ? .bien("clock.arrow.circlepath", "Versión anterior", "\(programa) ya usa otra versión: esta no la abre nadie.")
                        : .info("clock.arrow.circlepath", "Versión anterior", "Hay una más nueva (\(nueva)), aunque no pude confirmar cuál usa \(programa).")],
                    enUso: .rutas(nombre: programa, raiz: v.path), dueno: programa))
            }
        }
        return r
    }

    /// VS Code, Cursor y otros editores parecidos dejan versiones viejas de cada extensión al actualizarla.
    private func extensionesAntiguas() -> [Elemento] {
        var r: [Elemento] = []
        // (carpeta de extensiones, nombre, clave de la app, carpeta de datos en Application Support)
        let editores = [(".vscode/extensions", "VS Code", "com.microsoft.VSCode", "Code"),
                        (".vscode-insiders/extensions", "VS Code Insiders", "com.microsoft.VSCodeInsiders", "Code - Insiders"),
                        (".cursor/extensions", "Cursor", "Cursor", "Cursor"), (".windsurf/extensions", "Windsurf", "Windsurf", "Windsurf"),
                        (".antigravity/extensions", "Antigravity", "Antigravity", "Antigravity"),
                        (".vscode-oss/extensions", "VSCodium", "VSCodium", "VSCodium")]
        /// «ms-python.python-2024.2.1-darwin-arm64» → («ms-python.python», «2024.2.1»)
        func idYVersion(_ n: String) -> (id: String, version: String)? {
            guard let rango = n.range(of: #"-\d+\.\d+(\.\d+)*"#, options: .regularExpression) else { return nil }
            return (String(n[..<rango.lowerBound]).lowercased(), String(n[rango].dropFirst()))
        }
        for (rel, editor, clave, datosApp) in editores {
            let carpeta = Rutas.enHome(rel)
            let hijos = Rutas.hijos(carpeta).filter { Rutas.esCarpeta($0) && !$0.lastPathComponent.hasPrefix(".") }
            guard !hijos.isEmpty else { continue }
            // Cada perfil del editor tiene su propia lista de extensiones: la global y User/profiles/*/extensions.json.
            let perfiles = Rutas.enHome("Library/Application Support/\(datosApp)/User/profiles")
            var manifiestos = [carpeta.appendingPathComponent("extensions.json")]
            manifiestos += Rutas.hijos(perfiles).map { $0.appendingPathComponent("extensions.json") }.filter(Rutas.existe)
            var usadas = Set<String>()
            // Si alguna lista no se pudo leer, no se puede saber qué sobra: nada se marca solo.
            var completo = Rutas.existe(perfiles) ? (try? FileManager.default.contentsOfDirectory(atPath: perfiles.path)) != nil : true
            for m in manifiestos {
                guard let datos = try? Data(contentsOf: m), let lista = try? JSONSerialization.jsonObject(with: datos) as? [[String: Any]] else {
                    completo = false
                    continue
                }
                for e in lista {
                    if let rel = e["relativeLocation"] as? String { usadas.insert(rel) }
                    else if let ruta = (e["location"] as? [String: Any])?["path"] as? String { usadas.insert(Rutas.nombre(ruta)) }
                }
            }
            var viejas: [URL] = []      // otra versión de una extensión que sigue instalada
            var sinLista: [URL] = []    // no está en ninguna lista de ningún perfil
            if !usadas.isEmpty {
                let idsEnUso = Set(usadas.compactMap { idYVersion($0)?.id })
                for h in hijos where !usadas.contains(h.lastPathComponent) {
                    if let id = idYVersion(h.lastPathComponent)?.id, idsEnUso.contains(id) { viejas.append(h) } else { sinLista.append(h) }
                }
            } else {
                // Sin listas: varias versiones de la misma extensión, se conserva la más nueva.
                var porID: [String: [(URL, String)]] = [:]
                for h in hijos {
                    guard let (id, version) = idYVersion(h.lastPathComponent) else { continue }
                    porID[id, default: []].append((h, version))
                }
                for (_, versiones) in porID where versiones.count > 1 {
                    viejas += versiones.sorted { $0.1.compare($1.1, options: .numeric) == .orderedAscending }.dropLast().map(\.0)
                }
                completo = false
            }
            if !viejas.isEmpty {
                r.append(Elemento(
                    nombre: "Versiones viejas de extensiones de \(editor)",
                    detalle: "\(viejas.count) \(viejas.count == 1 ? "carpeta" : "carpetas") con versiones anteriores de extensiones que se actualizaron: \(Formato.listaCorta(viejas.map(\.lastPathComponent)))",
                    consecuencia: "Nada: \(editor) usa la versión nueva de cada una.",
                    rutas: viejas, categoria: .desarrollo, riesgo: completo ? .seguro : .revisar, seleccionado: completo,
                    motivos: [completo
                        ? .bien("puzzlepiece.extension.fill", "Versiones viejas", "De cada una hay una versión más nueva instalada en tus perfiles.")
                        : .info("puzzlepiece.extension.fill", "Versiones viejas", "Hay versiones más nuevas, pero no pude leer las listas de todos tus perfiles.")],
                    enUso: .app(nombre: editor, claves: [clave, editor]), dueno: editor))
            }
            if !sinLista.isEmpty {
                r.append(Elemento(
                    nombre: "Extensiones de \(editor) que no usa ningún perfil",
                    detalle: "\(sinLista.count) \(sinLista.count == 1 ? "extensión" : "extensiones") que no aparecen en la lista de ningún perfil: \(Formato.listaCorta(sinLista.map(\.lastPathComponent)))",
                    consecuencia: "Si alguna la usas, tendrás que volver a instalarla desde el editor.",
                    rutas: sinLista, categoria: .desarrollo, riesgo: .revisar,
                    motivos: [.info("puzzlepiece.extension.fill", "Sin instalar", "Suelen ser extensiones que quitaste; el editor no siempre borra su carpeta.")],
                    enUso: .app(nombre: editor, claves: [clave, editor]), dueno: editor))
            }
        }
        return r
    }

    /// El resto de ~/.cache: por convención (XDG) ahí solo se guarda lo que se puede volver a generar.
    /// Cachés de ~/.cache que sé que solo guardan cosas regenerables.
    private static let cachesXDGRegenerables: Set<String> = [
        "pip", "yarn", "go-build", "fontconfig", "mesa_shader_cache", "pnpm", "deno", "bazel", "coursier", "gh", "prisma",
        "typescript", "vscode-ripgrep", "selenium", "electron", "electron-builder", "jedi", "black", "ruff", "mypy", "pylint",
        "matplotlib", "cycles", "thumbnails", "node-gyp", "esbuild", "turbo", "nx", "next-swc", "sccache", "ccache", "clangd",
        "bun", "puppeteer", "ms-playwright", "cypress",
    ]

    private func cachesXDG(_ c: Contexto) -> [Elemento] {
        // Algunos programas guardan en ~/.cache datos de verdad (modelos de LM Studio, carpetas ocultas de otras
        // herramientas): esos no son caché.
        let conocidas = Set(Self.cachesDeDesarrollo.map(\.rel).filter { $0.hasPrefix(".cache/") }
            .compactMap { $0.split(separator: "/").dropFirst().first.map(String.init) }
            + ["huggingface", "puppeteer", "codex-runtimes", "lm-studio", "ollama"])
        var r: [Elemento] = []
        for h in Rutas.hijos(Rutas.enHome(".cache"))
        where Rutas.esCarpeta(h) && !h.lastPathComponent.hasPrefix(".") && !conocidas.contains(h.lastPathComponent) {
            let n = h.lastPathComponent
            let pesada = c.indice.bytes(de: h) >= 1_000_000_000
            // Solo las cachés que sé que se regeneran se marcan solas; el resto de ~/.cache suele serlo, pero
            // hay programas que guardan ahí perfiles, historiales o bases de datos.
            let conocida = Self.cachesXDGRegenerables.contains(n.lowercased())
            r.append(Elemento(
                nombre: "Caché de \(n)",
                detalle: "Lo que \(n) guarda en ~/.cache, la carpeta estándar de caché de los programas de terminal.",
                consecuencia: pesada ? "\(n) lo vuelve a descargar o generar cuando lo necesite (ocupa mucho: puede tardar)."
                                     : (conocida ? "\(n) lo vuelve a generar cuando lo necesite."
                                                 : "Normalmente \(n) lo vuelve a generar; revisa que no guarde ahí algo tuyo."),
                rutas: [h], categoria: .desarrollo, riesgo: conocida ? .seguro : .revisar, seleccionado: conocida && !pesada,
                motivos: [conocida
                    ? .bien("arrow.triangle.2.circlepath", "Carpeta de caché", "Es una caché conocida: \(n) la regenera.")
                    : .info("arrow.triangle.2.circlepath", "Carpeta de caché", "Está en ~/.cache, donde los programas guardan lo que pueden regenerar, pero no conozco \(n).")],
                enUso: .proceso(nombre: n, patron: "/.cache/\(n.lowercased())/"), dueno: n))
        }
        return r
    }

    /// Conda guarda los paquetes descargados (.conda, .tar.bz2) aunque ya estén instalados.
    private func paquetesDeConda() -> [Elemento] {
        var r: [Elemento] = []
        for base in ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "opt/miniconda3", "opt/anaconda3", "opt/miniforge3"] {
            let pkgs = Rutas.enHome(base + "/pkgs")
            let archivos = Rutas.hijos(pkgs).filter { $0.lastPathComponent.hasSuffix(".conda") || $0.lastPathComponent.hasSuffix(".tar.bz2") }
            let cache = pkgs.appendingPathComponent("cache")
            let rutas = archivos + (Rutas.existe(cache) ? [cache] : [])
            guard !rutas.isEmpty else { continue }
            r.append(Elemento(
                nombre: "Paquetes descargados de Conda (\(base))",
                detalle: "Los archivos comprimidos que conda descargó para instalar paquetes, y su índice.",
                consecuencia: "Tus entornos no cambian: los paquetes ya están descomprimidos. Es lo mismo que «conda clean --tarballs --index-cache».",
                rutas: rutas, categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("shippingbox.fill", "Ya instalados", "Solo son los archivos descargados; lo instalado no se toca.")],
                enUso: .proceso(nombre: "conda", patron: "/\(base.lowercased())/"), dueno: "Conda"))
        }
        return r
    }

    /// VS Code y sus derivados guardan por proyecto (workspaceStorage) las pestañas, los índices y el historial de
    /// chats de IA. Solo sobra el de proyectos cuya carpeta ya no existe.
    private func estadoDeProyectosBorrados() -> [Elemento] {
        var r: [Elemento] = []
        for (datosApp, editor, clave) in [("Code", "VS Code", "com.microsoft.VSCode"), ("Code - Insiders", "VS Code Insiders", "com.microsoft.VSCodeInsiders"),
                                          ("Cursor", "Cursor", "Cursor"), ("Windsurf", "Windsurf", "Windsurf"), ("Antigravity", "Antigravity", "Antigravity"),
                                          ("VSCodium", "VSCodium", "VSCodium")] {
            var huerfanos: [URL] = []
            var nombres: [String] = []
            for w in Rutas.hijos(Rutas.enHome("Library/Application Support/\(datosApp)/User/workspaceStorage")) where Rutas.esCarpeta(w) {
                // workspace.json dice qué carpeta (o archivo .code-workspace) era: «file:///Users/…».
                guard let datos = try? Data(contentsOf: w.appendingPathComponent("workspace.json")),
                      let json = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
                      let destino = (json["folder"] as? String) ?? (json["workspace"] as? String),
                      let url = URL(string: destino), url.isFileURL else { continue }
                // Un proyecto en un disco externo desconectado no está borrado.
                if !Rutas.existe(url) && !url.path.hasPrefix("/Volumes/") {
                    huerfanos.append(w)
                    nombres.append(url.lastPathComponent)
                }
            }
            guard !huerfanos.isEmpty else { continue }
            r.append(Elemento(
                nombre: "Estado de proyectos borrados en \(editor)",
                detalle: "Lo que \(editor) recordaba de \(huerfanos.count) \(huerfanos.count == 1 ? "proyecto que ya no existe" : "proyectos que ya no existen"): \(Formato.listaCorta(nombres)).",
                consecuencia: "Se pierden sus pestañas, índices y el historial de chats de IA de esos proyectos. Los proyectos que siguen existiendo no se tocan.",
                rutas: huerfanos, categoria: .desarrollo, riesgo: .revisar,
                motivos: [.info("folder.badge.questionmark", "Proyecto borrado",
                                "La carpeta de cada uno de estos proyectos ya no está en el Mac.")],
                enUso: .app(nombre: editor, claves: [clave, editor]), dueno: editor))
        }
        return r
    }

    /// ~/.cache/codex-runtimes: el entorno que usa la app de ChatGPT/Codex y, a veces, instalaciones que se cortaron.
    private func runtimesDeCodex(_ c: Contexto) -> [Elemento] {
        let chatGPT = EnUso.app(nombre: "ChatGPT", claves: ["com.openai.codex", "com.openai.chat", "ChatGPT"])
        var fallidas: [URL] = []
        var r: [Elemento] = []
        for h in Rutas.hijos(Rutas.enHome(".cache/codex-runtimes")) where Rutas.esCarpeta(h) {
            let n = h.lastPathComponent
            if n.hasPrefix("codex-runtime-install-") {
                // Se crean al instalar: si llevan más de un día y su contenido nunca llegó a descomprimirse, se cortaron.
                let viejo = (c.indice.masReciente(de: [h]).map { Date().timeIntervalSince($0) > 86400 }) ?? false
                if viejo && Rutas.hijos(h.appendingPathComponent("payload")).isEmpty { fallidas.append(h) }
                continue
            }
            r.append(Elemento(
                nombre: "Entorno de Codex (\(n))",
                detalle: "Node, Python y herramientas que la app de ChatGPT/Codex descargó para ejecutar tareas.",
                consecuencia: "La app lo vuelve a descargar la próxima vez que lo necesite (puede tardar).",
                rutas: [h], categoria: .desarrollo, riesgo: .revisar,
                motivos: [.info("arrow.down.circle.fill", "Se vuelve a descargar", "Es el entorno que usa Codex: si lo borras, lo descarga de nuevo.")],
                enUso: chatGPT, dueno: "Codex"))
        }
        if !fallidas.isEmpty {
            r.append(Elemento(
                nombre: "Instalaciones fallidas del entorno de Codex",
                detalle: "\(fallidas.count) \(fallidas.count == 1 ? "descarga" : "descargas") del entorno de Codex que se cortaron a medias y quedaron abandonadas.",
                consecuencia: "Nada: están incompletas y Codex no las usa.",
                rutas: fallidas, categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("xmark.bin.fill", "Incompletas", "Nunca llegaron a instalarse: Codex usa su entorno de otra carpeta.")],
                dueno: "Codex"))
        }
        return r
    }

    /// Freebuff y Codebuff (npm) descargan su programa a ~/.config/manicode; su instalador lo vuelve a bajar si falta.
    private func binariosDeAgentes(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        for base in Rutas.hijos(Rutas.enHome(".config")) where base.lastPathComponent.hasPrefix("manicode") && Rutas.esCarpeta(base) {
            let archivos = Rutas.hijos(base)
            for pkg in ["freebuff", "codebuff"] where archivos.contains(where: { $0.lastPathComponent == "\(pkg)-metadata.json" }) {
                // Con el programa abierto no se toca.
                if c.procesos.lineas.contains(where: { $0.contains("/node_modules/\(pkg)/index.js") }) || c.procesos.usando(base.path) != nil {
                    continue
                }
                // Solo binarios descargados; credenciales, ajustes, historial y projects/ no.
                let rutas = archivos.filter { f in
                    let n = f.lastPathComponent
                    return n == pkg || n == "rg" || n == "tree-sitter.wasm" || n.hasPrefix("\(pkg).old.") || n.hasPrefix("tree-sitter.wasm.old.")
                        || (n.hasPrefix(".\(pkg)-") && (n.hasSuffix(".tar.gz.part") || n.contains("-download-temp")))
                }
                guard rutas.contains(where: { $0.lastPathComponent == pkg }) else { continue }
                let instalado = c.apps.comandos.contains(pkg)
                let nombre = pkg.capitalized
                r.append(Elemento(
                    nombre: "Programa descargado de \(nombre)",
                    detalle: "El programa de \(nombre) y sus herramientas (rg, tree-sitter) que descargó su instalador de npm. Tus chats y tu sesión están en otros archivos y no se tocan.",
                    consecuencia: "La próxima vez que abras \(pkg) vuelve a descargar unos 90 MB (la misma versión).",
                    // Si sigue instalado, cuesta volver a descargarlo: solo «Liberar al máximo».
                    rutas: rutas, categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                    motivos: [instalado
                        ? .info("arrow.down.circle.fill", "Se vuelve a descargar", "\(pkg) sigue instalado: lo descarga otra vez al abrirlo. Por eso no lo marco solo: solo con «Liberar al máximo».")
                        : .bien("questionmark.folder.fill", "Sin el comando", "No encontré el comando \(pkg) instalado: estos binarios ya no los usa nadie.")],
                    enUso: .rutas(nombre: nombre, raiz: base.path), dueno: nombre,
                    nivel: instalado ? .maximo : .normal, costes: instalado ? [.descarga(bytes: 90_000_000)] : []))
            }
        }
        return r
    }

    /// «agy.1791313352848222000.old», «herr.old»: el nombre del programa, un número opcional y «.old».
    private static let patronOld = try! NSRegularExpression(pattern: #"^(.+?)(\.\d+)?\.old$"#)

    /// Algunos programas que se actualizan solos (agy, el de Antigravity, por ejemplo) renombran su versión anterior
    /// a «programa.<número>.old» y la dejan al lado de la nueva. Solo se ofrece si la nueva está ahí, es más nueva
    /// y ningún comando apunta a la vieja. (En /opt/homebrew/bin manda brew: no se mira.)
    private func binariosViejos(_ c: Contexto) -> [Elemento] {
        let fm = FileManager.default
        let home = Rutas.real(Rutas.home) + "/"
        var carpetas: [String] = []
        for d in [".local/bin", ".bun/bin", ".cargo/bin", ".deno/bin", "bin"].map({ Rutas.enHome($0).path }) + c.apps.pathEnCasa {
            let real = Rutas.real(URL(fileURLWithPath: d))
            if real.hasPrefix(home), Rutas.esCarpeta(URL(fileURLWithPath: real)), !carpetas.contains(real) { carpetas.append(real) }
        }
        // A dónde apunta cada enlace de esas carpetas: un .old al que apunte alguno todavía se usa.
        var apuntados = Set<String>()
        for d in carpetas {
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] {
                var st = stat()
                if lstat(d + "/" + n, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                    apuntados.insert(Rutas.real(URL(fileURLWithPath: d + "/" + n)))
                }
            }
        }
        let ahora = Date().timeIntervalSince1970
        var r: [Elemento] = []
        for d in carpetas {
            for n in ((try? fm.contentsOfDirectory(atPath: d)) ?? []).sorted() where n.hasSuffix(".old") {
                guard let m = Self.patronOld.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                      let rango = Range(m.range(at: 1), in: n) else { continue }
                let base = String(n[rango])
                let viejo = d + "/" + n
                let nuevo = d + "/" + base
                var sv = stat()
                var sn = stat()
                // El viejo: un archivo normal, tuyo. El nuevo: existe, se puede ejecutar y es más reciente.
                guard lstat(viejo, &sv) == 0, (sv.st_mode & S_IFMT) == S_IFREG, sv.st_uid == getuid(),
                      stat(nuevo, &sn) == 0, (sn.st_mode & S_IFMT) == S_IFREG, access(nuevo, X_OK) == 0,
                      sn.st_mtimespec.tv_sec > sv.st_mtimespec.tv_sec,
                      !apuntados.contains(viejo) else { continue }
                // La actualización terminó hace rato: el nuevo lleva 10 minutos sin cambiar. Se mira también su fecha
                // de estado (ctime), que cambia al escribirlo aunque el paquete conserve la fecha de modificación.
                // Y la versión vieja es de hace al menos un día.
                guard ahora - TimeInterval(max(sn.st_mtimespec.tv_sec, sn.st_ctimespec.tv_sec)) >= 600,
                      ahora - TimeInterval(sv.st_mtimespec.tv_sec) >= 86400 else { continue }
                let fechaNuevo = Date(timeIntervalSince1970: TimeInterval(sn.st_mtimespec.tv_sec))
                r.append(Elemento(
                    nombre: "\(base): versión anterior guardada al actualizarse",
                    detalle: "Copia del programa «\(base)» que su actualizador guardó como «\(n)» al instalar la versión nueva. El comando \(base) ya usa la nueva.",
                    consecuencia: "Nada: \(base) sigue funcionando con la versión nueva. Solo pierdes la copia de la anterior (si la mandas a la Papelera, puedes devolverla con «Deshacer»).",
                    rutas: [URL(fileURLWithPath: viejo)], categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                    motivos: [.bien("clock.arrow.circlepath", "Versión anterior",
                                    "Al lado está «\(base)», más nuevo (\(Formato.haceCuanto(fechaNuevo).lowercased())), y ningún comando apunta a esta copia.")],
                    enUso: .rutas(nombre: base, raiz: viejo), dueno: base))
            }
        }
        return r
    }

    // MARK: Comandos oficiales: Homebrew y Docker

    /// Algo que Homebrew ya no usa: una versión vieja de una fórmula, un Ruby portátil anterior o los restos de una
    /// instalación a medias.
    struct RestoDeHomebrew: Equatable {
        let que: String
        let ruta: String
    }

    /// Lo que quitaría «brew cleanup», leído del disco sin ejecutar brew (que podría ponerse a descargar o a actualizarse):
    /// - en Cellar, las versiones de cada fórmula más viejas que la que se usa (a la que apunta opt/<fórmula>), salvo las
    ///   de las fórmulas fijadas con «brew pin» (var/homebrew/pinned), la enlazada (var/homebrew/linked) y las que necesita
    ///   una app instalada con brew (.keepme); y las reinstalaciones a medias (*.reinstall);
    /// - los Ruby portátiles de vendor/portable-ruby que no son el de portable-ruby-version;
    /// - lo que quedó en var/homebrew/tmp/.cellar de instalaciones a medias.
    static func restosDeHomebrew(prefijo: String) -> [RestoDeHomebrew] {
        let fm = FileManager.default
        func carpetas(_ ruta: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: ruta)) ?? [])
                .filter { !$0.hasPrefix(".") && Rutas.esCarpeta(URL(fileURLWithPath: ruta + "/" + $0)) }.sorted()
        }
        func destino(_ enlace: String) -> String? { (try? fm.destinationOfSymbolicLink(atPath: enlace)).map { Rutas.nombre($0) } }
        var r: [RestoDeHomebrew] = []
        let cellar = prefijo + "/Cellar"
        for f in carpetas(cellar) {
            guard !Rutas.existe(prefijo + "/var/homebrew/pinned/" + f), let usada = destino(prefijo + "/opt/" + f) else { continue }
            let enlazada = destino(prefijo + "/var/homebrew/linked/" + f)
            for v in carpetas(cellar + "/" + f) where v != usada && v != enlazada {
                let ruta = cellar + "/" + f + "/" + v
                if v.hasSuffix(".reinstall") {
                    r.append(RestoDeHomebrew(que: "\(f) \(v.dropLast(10)) (reinstalación a medias)", ruta: ruta))
                } else if v.compare(usada, options: .numeric) == .orderedAscending, !Rutas.existe(ruta + "/.keepme") {
                    r.append(RestoDeHomebrew(que: "\(f) \(v)", ruta: ruta))
                }
            }
        }
        // En /opt/homebrew el repositorio es la misma carpeta; en /usr/local, /usr/local/Homebrew.
        let repositorio = Rutas.existe(prefijo + "/Library/Homebrew/brew.rb") ? prefijo : prefijo + "/Homebrew"
        let vendor = repositorio + "/Library/Homebrew/vendor"
        if let actual = (try? String(contentsOfFile: vendor + "/portable-ruby-version", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !actual.isEmpty {
            for v in carpetas(vendor + "/portable-ruby") where v.contains(".") && v != actual {
                r.append(RestoDeHomebrew(que: "Ruby portátil \(v)", ruta: vendor + "/portable-ruby/" + v))
            }
        }
        let aMedias = prefijo + "/var/homebrew/tmp/.cellar"
        for n in ((try? fm.contentsOfDirectory(atPath: aMedias)) ?? []).sorted() {
            r.append(RestoDeHomebrew(que: "restos de instalar \(n)", ruta: aMedias + "/" + n))
        }
        return r
    }

    /// Las variables con las que se ejecuta brew: sin actualizarse, sin estadísticas, sin consejos, sin desinstalar
    /// dependencias que ya nadie pide (eso lo decides tú con «brew autoremove») y sin colores en su salida.
    static let entornoDeBrew = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                                "HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_COLOR": "1", "HOMEBREW_NO_EMOJI": "1"]

    /// Versiones antiguas de Homebrew: Seguro y marcado, con su comando oficial «brew cleanup». Solo el Homebrew de tu
    /// usuario (si Cellar es de otro, brew no podría). No se toca si hay otro brew funcionando ni si algo usa lo que se va
    /// a quitar (un programa en marcha desde una versión vieja).
    private func homebrew() -> [Elemento] {
        var r: [Elemento] = []
        for prefijo in Rutas.homebrew {
            let brew = prefijo + "/bin/brew"
            var st = stat()
            guard lstat(prefijo + "/Cellar", &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(),
                  FileManager.default.isExecutableFile(atPath: brew) else { continue }
            let restos = Self.restosDeHomebrew(prefijo: prefijo)
            guard !restos.isEmpty else { continue }
            let tamano = restos.reduce(Int64(0)) { $0 + Tamanos.recorriendo($1.ruta) }
            r.append(Elemento(
                nombre: "Versiones antiguas de Homebrew",
                detalle: "Lo que Homebrew ya no usa: \(Formato.listaCorta(restos.map(\.que), maximo: 10)).",
                consecuencia: "Lo hace el propio Homebrew con su comando «brew cleanup»: quita las versiones antiguas de tus fórmulas (se quedan la que usas, las fijadas con «brew pin» y las enlazadas), el Ruby portátil anterior y los restos de instalaciones a medias, y ordena su caché de descargas. No actualiza Homebrew ni desinstala nada. No pasa por la Papelera: si algún día necesitaras una versión antigua, se vuelve a instalar con brew. Tarda unos segundos (lo detengo si pasa de 5 minutos) y lo que diga queda en el historial.",
                rutas: restos.map { URL(fileURLWithPath: $0.ruta) }, tamanoFijo: tamano,
                ultimoUso: restos.compactMap { Fechas.modificacion(URL(fileURLWithPath: $0.ruta)) }.max(),
                categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                accion: .comando(programa: brew, argumentos: ["cleanup"], entorno: Self.entornoDeBrew, limite: 300),
                motivos: [.bien("shippingbox.fill", "Comando oficial",
                                "Lo decide Homebrew con «brew cleanup», sin actualizarse (HOMEBREW_NO_AUTO_UPDATE) ni desinstalar dependencias que ya nadie pide (HOMEBREW_NO_AUTOREMOVE): solo quita versiones que no usa ninguna fórmula."),
                          .info("magnifyingglass", "Leído del disco",
                                "Para saber qué hay miré Cellar y opt/ sin ejecutar brew (que podría ponerse a descargar). Si una fórmula tiene una versión más nueva sin instalar, brew deja sus versiones antiguas como están.")],
                enUso: .proceso(nombre: "Homebrew", patron: "/library/homebrew/brew."), dueno: "Homebrew"))
        }
        return r
    }

    /// El programa docker (Docker Desktop, OrbStack, Colima…): el del PATH de tu terminal o el de las apps. En una casa
    /// de prueba, solo el del PATH de prueba.
    private static func programaDocker(_ c: Contexto) -> String? {
        var carpetas = c.apps.pathTerminal
        if !Rutas.casaDePrueba {
            carpetas += ["/usr/local/bin", "/opt/homebrew/bin", Rutas.enHome(".orbstack/bin").path,
                         "/Applications/Docker.app/Contents/Resources/bin", "/Applications/OrbStack.app/Contents/MacOS/xbin"]
        }
        for d in carpetas where FileManager.default.isExecutableFile(atPath: d + "/docker") {
            return Rutas.real(URL(fileURLWithPath: d + "/docker"))
        }
        return nil
    }

    /// Lo que Docker dice que se puede recuperar de cada tipo («Images», «Build Cache»…), leído de
    /// «docker system df --format '{{json .}}'» (una línea JSON por tipo, con «Reclaimable»: «1.2GB (50%)»).
    static func recuperableDeDocker(_ salida: String) -> [String: Int64] {
        var r: [String: Int64] = [:]
        for linea in salida.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(linea.utf8)) as? [String: Any],
                  let tipo = d["Type"] as? String, let texto = d["Reclaimable"] as? String,
                  let bytes = Formato.bytes(deTexto: String(texto.split(separator: " ").first ?? "")) else { continue }
            r[tipo] = bytes
        }
        return r
    }

    /// Docker, solo si su servicio responde («docker info»): la caché de compilación (Seguro, para «Liberar al máximo»:
    /// la próxima compilación de tus imágenes empieza de cero) y las imágenes que no usa ningún contenedor (Revisar: se
    /// vuelven a descargar o a compilar). Los volúmenes (tus datos) y los contenedores nunca se tocan.
    private func docker(_ c: Contexto) -> [Elemento] {
        guard let docker = Self.programaDocker(c) else { return [] }
        let info = Shell.ejecutar(docker, ["info", "--format", "{{.ServerVersion}}"], limite: 10)
        guard info.estado == 0, !info.salida.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let recuperable = Self.recuperableDeDocker(Shell.ejecutar(docker, ["system", "df", "--format", "{{json .}}"], limite: 30).salida)
        let entorno = ["DOCKER_CLI_HINTS": "false"]
        let ruta = URL(fileURLWithPath: docker)
        let disco = "Docker guarda todo en su propio disco virtual: el espacio vuelve al Mac cuando Docker lo devuelve, normalmente en unos minutos."
        var r: [Elemento] = []
        if let cache = recuperable["Build Cache"], cache > 0 {
            r.append(Elemento(
                nombre: "Caché de compilación de Docker",
                detalle: "Lo que Docker guarda de compilaciones anteriores de imágenes (BuildKit) para no repetirlas.",
                consecuencia: "Lo hace Docker con su comando «docker builder prune -f»: borra la caché de compilación que no está usando ninguna compilación en marcha. La próxima vez que compiles una imagen empezará de cero. Tus imágenes, contenedores y volúmenes no se tocan. \(disco)",
                rutas: [ruta], tamanoFijo: cache, categoria: .desarrollo, riesgo: .seguro, seleccionado: true,
                accion: .comando(programa: docker, argumentos: ["builder", "prune", "-f"], entorno: entorno, limite: 600),
                motivos: [.bien("shippingbox.fill", "Comando oficial", "Lo decide Docker, que no borra lo que esté usando una compilación en marcha.")],
                dueno: "Docker", nivel: .maximo, costes: [.recompilacion(proyecto: "tus imágenes de Docker")]))
        }
        if let imagenes = recuperable["Images"], imagenes > 0 {
            r.append(Elemento(
                nombre: "Imágenes de Docker que no usa ningún contenedor",
                detalle: "Imágenes descargadas o compiladas que ningún contenedor (ni siquiera uno parado) usa.",
                consecuencia: "Lo hace Docker con su comando «docker image prune -a -f». Si vuelves a necesitar una, se descarga otra vez (o la vuelves a compilar, si la hiciste tú y no la subiste a ningún sitio). Los contenedores y los volúmenes no se tocan. \(disco)",
                rutas: [ruta], tamanoFijo: imagenes, categoria: .desarrollo, riesgo: .revisar,
                accion: .comando(programa: docker, argumentos: ["image", "prune", "-a", "-f"], entorno: entorno, limite: 600),
                motivos: [.info("arrow.down.circle.fill", "Se vuelven a descargar",
                                "Las que bajaste de un registro (Docker Hub…) se vuelven a descargar; las que compilaste tú y no subiste, hay que volver a compilarlas.")],
                dueno: "Docker", costes: [.descarga(bytes: imagenes)]))
        }
        return r
    }

    /// Carpetas donde se instalan comandos sueltos (no las de una herramienta concreta, como ~/.grok/bin, cuyos
    /// programas pueden ser parte de ella aunque el PATH no los use).
    private static let carpetasDeComandos = [".local/bin", "bin", ".cargo/bin", "go/bin", ".bun/bin", ".deno/bin"]

    /// Comandos que están dos veces en el PATH de la terminal (el codex de npm y el del instalador oficial…): al
    /// escribirlo, la terminal usa el primero que encuentra, así que el de detrás no se usa. Se ofrece para revisar lo que
    /// instaló el de detrás, si está en tu carpeta: el paquete de npm entero (con sus enlaces) o el programa suelto.
    /// Nunca se marca: algún script o programa puede llamarlo por su ruta completa.
    private func comandosTapados(_ c: Contexto) -> [Elemento] {
        let fm = FileManager.default
        let home = Rutas.real(Rutas.home) + "/"
        // El PATH sin carpetas repetidas, en orden y con su ruta real.
        var carpetas: [String] = []
        for d in c.apps.pathTerminal {
            let real = Rutas.real(URL(fileURLWithPath: d))
            if Rutas.esCarpeta(URL(fileURLWithPath: real)), !carpetas.contains(real) { carpetas.append(real) }
        }
        let deComandos = Set(Self.carpetasDeComandos.map { Rutas.real(Rutas.enHome($0)) })
        var usado: [String: (ruta: String, real: String)] = [:]   // comando → el que usa la terminal
        var ofrecidos = Set<String>()
        var r: [Elemento] = []
        for d in carpetas {
            let nombres = ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            for n in nombres {
                let ruta = d + "/" + n
                // Un comando: algo que se puede ejecutar y no es una carpeta (un enlace roto no cuenta).
                guard access(ruta, X_OK) == 0, !Rutas.esCarpeta(URL(fileURLWithPath: ruta)) else { continue }
                let real = Rutas.real(URL(fileURLWithPath: ruta))
                guard let primero = usado[n] else { usado[n] = (ruta, real); continue }
                // El de detrás: si lleva al mismo programa, no sobra nada. Y solo se ofrece lo que está en tu carpeta.
                guard primero.real != real, ruta.hasPrefix(home) else { continue }
                var quitar: [URL]
                let que: String
                var reinstalar = ""
                if let paquete = Self.paqueteDeNpm(real), paquete.hasPrefix(home), !primero.real.hasPrefix(paquete + "/") {
                    // El paquete y los enlaces de esta carpeta que llevan a él (si no, quedarían rotos).
                    let enlaces = nombres.map { d + "/" + $0 }.filter { Self.esEnlace(URL(fileURLWithPath: $0))
                        && Rutas.real(URL(fileURLWithPath: $0)).hasPrefix(paquete + "/") }
                    quitar = [URL(fileURLWithPath: paquete)] + enlaces.map { URL(fileURLWithPath: $0) }
                    let nombrePaquete = String(paquete[paquete.range(of: "/node_modules/", options: .backwards)!.upperBound...])
                    que = "el paquete de npm «\(nombrePaquete)»"
                    reinstalar = "; se vuelve a instalar con «npm install -g \(nombrePaquete)»"
                } else if deComandos.contains(d), !Self.esEnlace(URL(fileURLWithPath: ruta)) {
                    quitar = [URL(fileURLWithPath: ruta)]
                    que = "el programa \(Formato.rutaCorta(ruta))"
                } else {
                    continue
                }
                guard ofrecidos.insert(quitar[0].path).inserted else { continue }
                r.append(Elemento(
                    nombre: "\(n) que no se usa (\(Formato.rutaCorta(d)))",
                    detalle: "Hay más de un «\(n)» en el PATH de tu terminal. Al escribir \(n) se usa \(Formato.rutaCorta(primero.ruta)); este, \(Formato.rutaCorta(ruta)), queda detrás.",
                    consecuencia: "Se borra \(que). El comando \(n) sigue funcionando con el otro. Si algún script o programa lo llama por su ruta completa, dejará de funcionar\(reinstalar). Va a la Papelera: puedes devolverlo con «Deshacer».",
                    rutas: quitar, categoria: .desarrollo, riesgo: .revisar,
                    motivos: [.info("arrow.triangle.branch", "Tapado en el PATH",
                                    "No se usa al escribir «\(n)»: la terminal encuentra antes \(Formato.rutaCorta(primero.ruta))\(primero.real != primero.ruta ? " (\(Formato.rutaCorta(primero.real)))" : "").")],
                    enUso: .rutas(nombre: n, raiz: quitar[0].path), dueno: n))
            }
        }
        return r
    }

    /// El paquete global de npm al que pertenece un programa: «…/lib/node_modules/@openai/codex/bin/codex.js» →
    /// «…/lib/node_modules/@openai/codex».
    private static func paqueteDeNpm(_ ruta: String) -> String? {
        guard let r = ruta.range(of: "/lib/node_modules/") else { return nil }
        let partes = ruta[r.upperBound...].split(separator: "/")
        guard let primera = partes.first else { return nil }
        let paquete = primera.hasPrefix("@") && partes.count > 1 ? "\(primera)/\(partes[1])" : String(primera)
        return String(ruta[..<r.upperBound]) + paquete
    }

    // MARK: - Cachés de aplicaciones

    private func cachesApps(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        let caches = Rutas.enHome("Library/Caches")
        let omitir: Set<String> = ["CloudKit", "FamilyCircle", "GeoServices", "PassKit", "Animoji", "Google", "JetBrains"]

        for h in Rutas.hijos(caches) where Rutas.esCarpeta(h) {
            let n = h.lastPathComponent
            if let app = Self.cachesDeApple[n] {
                r.append(cacheDeApp(app: app, clave: n, rutas: [h]))
                continue
            }
            if n.hasPrefix("com.apple.") || n.hasPrefix(".") || Self.cachesDeDesarrolloEnLibrary.contains(n) || omitir.contains(n)
                || Self.propios.contains(n) { continue }
            // Las cachés de apps desinstaladas se ofrecen junto al resto de lo que dejó esa app.
            guard c.apps.estaInstalado(carpeta: n) else { continue }
            // Squirrel (apps Electron) guarda las actualizaciones en su propia carpeta «<id>.ShipIt».
            if n.hasSuffix(".ShipIt") {
                let id = String(n.dropLast(7))
                r += actualizacionesShipIt(en: h, app: c.apps.nombreApp(para: id) ?? nombreBonito(id), id: id, c)
                continue
            }
            let app = c.apps.nombreApp(para: n) ?? nombreBonito(n)
            // Sparkle guarda dentro de la caché la actualización ya descargada: eso no es caché, es un instalador.
            let sparkle = h.appendingPathComponent("org.sparkle-project.Sparkle")
            if Rutas.esCarpeta(sparkle) {
                if let actualizacion = actualizacionSparkle(en: sparkle, app: app, id: n, c) { r.append(actualizacion) }
                let resto = Rutas.hijos(h).filter { $0.path != sparkle.path }
                if !resto.isEmpty { r.append(cacheDeApp(app: app, clave: n, rutas: resto)) }
                continue
            }
            // ~/Library/Caches/AndroidStudio4.0 y similares: la estructura antigua, también con su historial local.
            if let ide = cachesDeIDE(h, app: app, clave: n) {
                r += ide
                continue
            }
            r.append(cacheDeApp(app: app, clave: n, rutas: [h]))
        }
        r += modelosIADeNavegadores(c)
        r += clienteTorDeBrave(c)
        // Google y JetBrains: una carpeta por programa y versión (las versiones viejas van en «desarrollo»).
        for vendedor in ["Google", "JetBrains"] {
            let hijos = Rutas.hijos(caches.appendingPathComponent(vendedor)).filter { Rutas.esCarpeta($0) }
            let actuales = Self.versionesActuales(hijos)
            for h in hijos {
                let n = h.lastPathComponent
                if Self.versionIDE(n) != nil && !actuales.contains(h) { continue }
                let esStudio = n.hasPrefix("AndroidStudio")
                let app = esStudio ? "Android Studio" : (c.apps.nombreApp(para: n) ?? n)
                let clave = esStudio ? "com.google.android.studio" : n
                if let ide = cachesDeIDE(h, app: app, clave: clave) {
                    r += ide
                    continue
                }
                r.append(cacheDeApp(app: app, clave: clave, rutas: [h]))
            }
        }

        // Cachés internas (Electron/Chromium) dentro de Application Support.
        let appSupport = Rutas.enHome("Library/Application Support").path + "/"
        var porApp: [String: [URL]] = [:]
        for (ruta, tipo) in c.indice.cachesInternas where tipo == .cache {
            guard let carpeta = ruta.dropFirst(appSupport.count).split(separator: "/").first.map(String.init) else { continue }
            porApp[carpeta, default: []].append(URL(fileURLWithPath: ruta))
        }
        for (carpeta, rutas) in porApp {
            guard !carpeta.hasPrefix("com.apple."), !Self.propios.contains(carpeta),
                  c.apps.estaInstalado(carpeta: carpeta) else { continue }
            let app = c.apps.nombreApp(para: carpeta) ?? carpeta
            let tipos = Array(Set(rutas.map(\.lastPathComponent))).sorted()
            r.append(Elemento(
                nombre: "Caché interna de \(app)",
                detalle: "Cachés que \(app) guarda junto a sus datos (\(Formato.listaCorta(tipos))).",
                consecuencia: "\(app) las vuelve a crear. Tus datos, sesiones y ajustes no se tocan.",
                rutas: rutas, categoria: .cachesApps, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("arrow.triangle.2.circlepath", "Solo cachés", "Solo se borran las carpetas de caché, no los datos de \(app).")],
                enUso: .app(nombre: app, claves: [carpeta, app]), dueno: app))
        }

        // Apps de la App Store guardan su caché y sus temporales dentro de su contenedor.
        if c.accesoTotal {
            for contenedor in Rutas.hijos(Rutas.enHome("Library/Containers")) {
                let id = contenedor.lastPathComponent
                let rutas = ["Data/Library/Caches", "Data/tmp"].map { contenedor.appendingPathComponent($0) }.filter(Rutas.existe)
                guard !id.hasPrefix("com.apple."), !rutas.isEmpty, c.apps.estaInstalado(carpeta: id) else { continue }
                let app = c.apps.nombreApp(para: id) ?? nombreBonito(id)
                r.append(cacheDeApp(app: app, clave: id, rutas: rutas))
            }
            // Contenedores compartidos entre una app y sus extensiones (WhatsApp, Telegram, Office…).
            for grupo in Rutas.hijos(Rutas.enHome("Library/Group Containers")) {
                let id = grupo.lastPathComponent
                let cache = grupo.appendingPathComponent("Library/Caches")
                guard !id.contains("com.apple."), Rutas.existe(cache), c.apps.estaInstalado(carpeta: id) else { continue }
                let clave = AppsInstaladas.equipo(de: id).map { _ in String(id.dropFirst(11)) } ?? id
                let app = c.apps.nombreApp(para: clave.replacingOccurrences(of: "group.", with: "")) ?? nombreBonito(clave)
                r.append(cacheDeApp(app: app, clave: clave, rutas: [cache]))
            }
            // Mail guarda una copia de cada adjunto que abres.
            let adjuntos = Rutas.enHome("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
            if Rutas.existe(adjuntos) {
                r.append(Elemento(
                    nombre: "Adjuntos de Mail ya abiertos",
                    detalle: "Copias de los adjuntos que abriste desde Mail.",
                    consecuencia: "Si el correo sigue en tu buzón, Mail vuelve a descargar el adjunto al abrirlo. Si borraste el correo o editaste el adjunto aquí, esta puede ser la única copia.",
                    rutas: [adjuntos], categoria: .cachesApps, riesgo: .revisar,
                    motivos: [.info("paperclip", "Copias de adjuntos", "Normalmente son copias de lo que ya está en tus correos, pero no puedo comprobarlo.")],
                    enUso: .app(nombre: "Mail", claves: ["com.apple.mail"]), dueno: "Mail"))
            }
        }

        // Vídeos de los fondos de pantalla en movimiento (Aerials) que macOS descargó.
        let aereos = Rutas.hijos(Rutas.enHome("Library/Application Support/com.apple.wallpaper/aerials/videos"))
        if !aereos.isEmpty {
            r.append(Elemento(
                nombre: "Vídeos de fondos de pantalla",
                detalle: "\(aereos.count) \(aereos.count == 1 ? "vídeo" : "vídeos") de fondos de pantalla y salvapantallas en movimiento que macOS descargó.",
                consecuencia: "macOS vuelve a descargar el que tengas puesto (mientras tanto puede verse en negro).",
                rutas: aereos, categoria: .cachesApps, riesgo: .revisar,
                motivos: [.info("photo.on.rectangle.angled", "Se vuelven a descargar", "macOS descarga de nuevo los que uses.")],
                dueno: "macOS"))
        }
        return r
    }

    /// Cachés de apps de Apple que se pueden borrar sin problemas (el resto de com.apple.* no se toca).
    private static let cachesDeApple: [String: String] = [
        "com.apple.helpd": "Ayuda de macOS", "com.apple.Music": "Música", "com.apple.iTunes": "iTunes",
        "com.apple.podcasts": "Podcasts", "com.apple.tipsd": "Consejos", "com.apple.Safari": "Safari",
        "com.apple.AppleMediaServices": "App Store", "com.apple.TV": "Apple TV", "com.apple.news": "News",
        "GeoServices": "Mapas",
    ]

    /// La app instalada con ese identificador (en Aplicaciones o abierta ahora), nunca una copia dentro de cachés.
    private func appInstalada(id: String) -> URL? {
        let buscado = id.lowercased()
        var candidatas: [URL] = []
        for carpeta in [URL(fileURLWithPath: "/Applications"), Rutas.enHome("Applications")] {
            for h in Rutas.hijos(carpeta) {
                if h.pathExtension == "app" { candidatas.append(h) }
                else if Rutas.esCarpeta(h) { candidatas += Rutas.hijos(h).filter { $0.pathExtension == "app" } }
            }
        }
        if let u = candidatas.first(where: { Bundle(url: $0)?.bundleIdentifier?.lowercased() == buscado }) { return u }
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.lowercased() == buscado }?.bundleURL
    }

    private static func version(de app: URL?) -> (larga: String, corta: String)? {
        guard let info = app.flatMap({ Bundle(url: $0)?.infoDictionary }), let larga = info["CFBundleVersion"] as? String else { return nil }
        return (larga, info["CFBundleShortVersionString"] as? String ?? larga)
    }

    /// ¿Está trabajando ahora mismo un actualizador de esta app (el instalador de Sparkle o el ShipIt de Squirrel), o uno
    /// que no dice qué app actualiza? Entonces no se toca nada de sus actualizaciones. Los que nombran otra app no cuentan:
    /// el ShipIt de Claude, que espera a que Claude se cierre, no esconde las actualizaciones viejas de las demás.
    private func actualizandose(id: String, _ c: Contexto) -> Bool {
        c.procesos.actualizadorEnMarcha(id: id, ruta: appInstalada(id: id)?.path ?? "") != nil
    }

    private func actualizacionSparkle(en sparkle: URL, app: String, id: String, _ c: Contexto) -> Elemento? {
        let descargas = ["PersistentDownloads", "Installation"].flatMap { Rutas.hijos(sparkle.appendingPathComponent($0)) }
        guard !descargas.isEmpty, !actualizandose(id: id, c) else { return nil }
        let actividad = Fechas.masRecienteDentro(sparkle)
        if let actividad, Date().timeIntervalSince(actividad) < 3600 { return nil }   // puede estar descargándose
        func buscarApp(_ u: URL, _ nivel: Int) -> URL? {
            if u.pathExtension == "app" { return u }
            guard nivel > 0 else { return nil }
            for h in Rutas.hijos(u) { if let a = buscarApp(h, nivel - 1) { return a } }
            return nil
        }
        let descargada = Self.version(de: descargas.lazy.compactMap { buscarApp($0, 3) }.first)
        let instalada = Self.version(de: appInstalada(id: id))
        let dias = actividad.map { Date().timeIntervalSince($0) / 86400 } ?? 0
        let riesgo: Riesgo
        let motivo: Motivo
        let consecuencia: String
        if let descargada, let instalada {
            if descargada.larga.compare(instalada.larga, options: .numeric) == .orderedDescending {
                riesgo = .revisar
                motivo = .aviso("arrow.down.app.fill", "Actualización pendiente",
                                "\(app) \(descargada.corta) ya está descargada y se instalará cuando cierres la app (ahora tienes la \(instalada.corta)).")
                consecuencia = "\(app) no se actualizará al cerrarse y volverá a descargar la actualización en las próximas horas."
            } else {
                riesgo = .seguro
                motivo = .bien("checkmark.circle.fill", "Ya instalada", "Ya tienes \(app) \(instalada.corta): esta descarga sobra.")
                consecuencia = "Nada: ya tienes esa versión o una más nueva."
            }
        } else {
            // Solo trozos de actualización (.delta, .zip…): si llevan días ahí, se quedaron abandonados.
            riesgo = dias > 7 ? .seguro : .revisar
            motivo = .info("arrow.down.app.fill", "Descarga de actualización", "Archivos de una actualización de \(app) descargados \(Formato.haceCuanto(actividad).lowercased()).")
            consecuencia = "Si estaba pendiente, \(app) volverá a descargar la actualización."
        }
        return Elemento(
            nombre: "Actualización descargada de \(app)",
            detalle: "Una versión de \(app) que se descargó para instalarse cuando cierres la app. No es caché: es un instalador.",
            consecuencia: consecuencia,
            rutas: descargas, ultimoUso: actividad, categoria: .cachesApps, riesgo: riesgo, seleccionado: riesgo == .seguro,
            motivos: [motivo], enUso: .app(nombre: app, claves: [id, app]), dueno: app)
    }

    /// Squirrel/ShipIt: cada «update.*» es una actualización descargada. La que menciona ShipItState.plist es la pendiente.
    private func actualizacionesShipIt(en carpeta: URL, app: String, id: String, _ c: Contexto) -> [Elemento] {
        let descargas = Rutas.hijos(carpeta).filter { $0.lastPathComponent.hasPrefix("update.") }
        guard !descargas.isEmpty, !actualizandose(id: id, c) else { return [] }
        let estado = NSDictionary(contentsOf: carpeta.appendingPathComponent("ShipItState.plist"))
        let pendiente = (estado?["updateBundleURL"] as? String).flatMap { URL(string: $0)?.path }
        let viejas = descargas.filter { d in pendiente.map { !$0.hasPrefix(d.path) } ?? true }
        var r: [Elemento] = []
        if !viejas.isEmpty {
            r.append(Elemento(
                nombre: "Actualizaciones viejas de \(app)",
                detalle: "Actualizaciones de \(app) que ya se instalaron o se descartaron.",
                consecuencia: "Nada: \(app) no las vuelve a usar.",
                rutas: viejas, categoria: .cachesApps, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("checkmark.circle.fill", "Ya aplicadas", "No son la actualización pendiente de \(app).")],
                enUso: .app(nombre: app, claves: [id, app]), dueno: app))
        }
        if let pendiente, let d = descargas.first(where: { pendiente.hasPrefix($0.path) }) {
            r.append(Elemento(
                nombre: "Actualización descargada de \(app)",
                detalle: "Una versión nueva de \(app) que espera a instalarse cuando cierres la app.",
                consecuencia: "\(app) no se actualizará al cerrarse y volverá a descargar la actualización.",
                rutas: [d], categoria: .cachesApps, riesgo: .revisar,
                motivos: [.aviso("arrow.down.app.fill", "Actualización pendiente", "Se instalará la próxima vez que cierres \(app).")],
                enUso: .app(nombre: app, claves: [id, app]), dueno: app))
        }
        return r
    }

    /// Los navegadores Chromium descargan Gemini Nano (2-4 GB) para sus funciones de IA, aunque no las uses.
    /// La carpeta está protegida por macOS: solo se ve con Acceso total al disco.
    private func modelosIADeNavegadores(_ c: Contexto) -> [Elemento] {
        guard c.accesoTotal else { return [] }
        let navegadores = [("Google/Chrome", "Google Chrome", "com.google.Chrome"), ("Google/Chrome Beta", "Chrome Beta", "com.google.Chrome.beta"),
                           ("Google/Chrome Canary", "Chrome Canary", "com.google.Chrome.canary"), ("Chromium", "Chromium", "org.chromium.Chromium"),
                           ("Microsoft Edge", "Microsoft Edge", "com.microsoft.edgemac"), ("BraveSoftware/Brave-Browser", "Brave Browser", "com.brave.Browser"),
                           ("Vivaldi", "Vivaldi", "com.vivaldi.Vivaldi"), ("com.operasoftware.Opera", "Opera", "com.operasoftware.Opera"),
                           ("Arc/User Data", "Arc", "company.thebrowser.Browser")]
        var r: [Elemento] = []
        for (rel, nombre, id) in navegadores {
            let modelo = Rutas.enHome("Library/Application Support/\(rel)/OptGuideOnDeviceModel")
            guard Rutas.esCarpeta(modelo) else { continue }
            let instalado = c.apps.bundleIDs.contains(id.lowercased())
            r.append(Elemento(
                nombre: "Modelo de IA de \(nombre) (Gemini Nano)",
                detalle: "Modelo de inteligencia artificial que \(nombre) descargó para funciones de IA en el propio Mac, aunque no las uses.",
                consecuencia: instalado
                    ? "\(nombre) lo vuelve a descargar solo si hay espacio libre. Mientras tanto dejan de funcionar sus funciones de IA integradas (como «Ayúdame a escribir»). Para que no vuelva, desactiva la IA en el dispositivo en los ajustes del navegador."
                    : "Nada: \(nombre) ya no está instalado.",
                rutas: [modelo], categoria: .cachesApps, riesgo: instalado ? .revisar : .seguro, seleccionado: !instalado,
                motivos: [instalado
                    ? .info("brain", "Modelo de IA", "Ocupa varios GB y solo lo usan las funciones de IA integradas del navegador.")
                    : .bien("questionmark.app.fill", "Navegador desinstalado", "\(nombre) ya no está en este Mac: el modelo no lo usa nadie.")],
                enUso: .app(nombre: nombre, claves: [id, nombre]), dueno: nombre))
        }
        return r
    }

    private static let patronTor = try! NSRegularExpression(pattern: #"^tor-\d+\.\d+\.\d+\.\d+-\w+(-\w+)?-brave-\d+$"#)

    /// Brave descarga el programa Tor la primera vez que abres una ventana privada con Tor y lo deja ahí.
    private func clienteTorDeBrave(_ c: Contexto) -> [Elemento] {
        guard c.accesoTotal, !c.procesos.lineas.contains(where: { $0.contains("-darwin-brave-") }) else { return [] }
        var r: [Elemento] = []
        for edicion in ["Brave-Browser", "Brave-Browser-Beta", "Brave-Browser-Nightly", "Brave-Browser-Dev"] {
            let raiz = Rutas.enHome("Library/Application Support/BraveSoftware/\(edicion)")
            // Los componentes de Brave son carpetas con un id de 32 letras de la «a» a la «p».
            for comp in Rutas.hijos(raiz) where comp.lastPathComponent.count == 32 && comp.lastPathComponent.allSatisfy({ ("a"..."p").contains($0) }) {
                let esTor = Rutas.hijos(comp).contains { v in
                    Rutas.hijos(v).contains { f in
                        let n = f.lastPathComponent
                        return Self.patronTor.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
                    }
                }
                guard esTor else { continue }
                let uso = Fechas.masRecienteDentro(raiz.appendingPathComponent("tor/data"))
                r.append(Elemento(
                    nombre: "Cliente Tor de Brave",
                    detalle: "El programa Tor que Brave descargó la primera vez que abriste una ventana privada con Tor. Brave lo deja guardado aunque no lo vuelvas a usar.",
                    consecuencia: "La próxima ventana privada con Tor tardará un poco más en abrirse porque Brave lo vuelve a descargar. Tus ajustes de Tor no se tocan.",
                    rutas: [comp], ultimoUso: uso, categoria: .cachesApps, riesgo: .revisar,
                    motivos: [.info("arrow.down.circle.fill", "Se vuelve a descargar",
                                    uso.map { "Lo usaste por última vez \(Formato.haceCuanto($0).lowercased())." } ?? "Brave lo descarga otra vez si abres una ventana con Tor.")],
                    enUso: .app(nombre: "Brave Browser", claves: ["com.brave.Browser", "Brave Browser"]), dueno: "Brave"))
            }
        }
        return r
    }

    private func cacheDeApp(app: String, clave: String, rutas: [URL]) -> Elemento {
        Elemento(
            nombre: "Caché de \(app)",
            detalle: "Archivos temporales de \(app).",
            consecuencia: "\(app) los vuelve a crear cuando los necesita (al principio puede ir un poco más lenta).",
            rutas: rutas, categoria: .cachesApps, riesgo: .seguro, seleccionado: true,
            motivos: [.bien("arrow.triangle.2.circlepath", "Se regenera", "Es una caché: \(app) la reconstruye sola.")],
            enUso: .app(nombre: app, claves: [clave, app]), dueno: app)
    }

    private static func versionesActuales(_ carpetas: [URL]) -> Set<URL> {
        var porProducto: [String: (URL, String)] = [:]
        for u in carpetas {
            guard let (p, v) = versionIDE(u.lastPathComponent) else { continue }
            if let actual = porProducto[p], actual.1.compare(v, options: .numeric) != .orderedAscending { continue }
            porProducto[p] = (u, v)
        }
        return Set(porProducto.values.map(\.0))
    }

    // MARK: - Temporales del sistema

    /// Nombres claros para las carpetas de /var/folders que no son de ninguna app.
    private static let nombresDelSistema: [String: String] = [
        "clang": "Clang (compilador de Xcode)", "com.apple.metal": "Metal (sombreadores de gráficos)",
        "com.apple.DeveloperTools": "Herramientas de Xcode",
    ]

    /// Cachés que se regeneran y cuyo programa se conoce: con ese programa sin funcionar se marcan antes que las demás
    /// (3 días sin cambios en C y 7 en T). Metal se queda en 3 días: la usa cualquier app que dibuje con la GPU.
    /// `quien` dice qué programa la usa («Sin <quien> en marcha») y `cual`, cuál tiene que no estar funcionando.
    private static let umbralesPorClave: [String: (dias: Double, uso: EnUso?, quien: String, cual: String)] = [
        "clang": (0.25, .programas(nombre: "Un compilador",
                                   ejecutables: ["clang", "clang++", "swift", "swift-frontend", "swift-driver", "swift-build",
                                                 "xcodebuild", "Xcode", "SourceKitService", "sourcekit-lsp"]),
                  "compilador", "ningún compilador (Clang, Swift, Xcode o SourceKit)"),
        "com.apple.metal": (3, nil, "", ""),
        "node-compile-cache": (1, .programas(nombre: "Node.js", ejecutables: ["node"]), "Node.js", "ningún programa de Node.js"),
    ]

    /// Carpetas de trabajo de herramientas conocidas en /tmp: se crean y se borran solas y nunca guardan resultados tuyos.
    private static let efimerosEnTmp = ["tmux-", "npm-", "yarn--", "pip-", "uv-", "node-compile-cache", "xcrun_db", "vscode-ipc"]

    private func sistema(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        for raiz in Rutas.temporalesDelSistema {
            let esCache = raiz.hasSuffix("/C")
            // Apps con temporales sueltos (ocultos, «.com.openai.codex.AbC123») en T.
            var conSueltos = Set<String>()
            for h in Rutas.hijos(URL(fileURLWithPath: raiz)) {
                let n = h.lastPathComponent
                if !esCache, let app = TemporalesSueltos.app(de: n) { conSueltos.insert(app) }
                if n.hasPrefix(".") || n == "TemporaryItems" || Self.propios.contains(n) { continue }
                if n.hasPrefix("com.apple.") && Self.nombresDelSistema[n] == nil { continue }
                // Lo que no llega al mínimo no se va a ofrecer (cientos de carpetitas): ni se evalúa.
                guard c.indice.bytes(de: h) >= minimo else { continue }
                // «com.brave.Browser.helper.GPU» es Brave; «org.llvm.clang.gustavo» es Clang.
                var clave = n.replacingOccurrences(of: #"\.(helper|ShipIt)(\..*)?$"#, with: "", options: [.regularExpression, .caseInsensitive])
                if clave.hasPrefix("org.llvm.clang") { clave = "clang" }
                let app = Self.nombresDelSistema[clave] ?? c.apps.nombreApp(para: clave) ?? nombreBonito(clave)
                // Lo que no se toca hace días ya no lo está usando nadie. Si se sabe qué programa la usa, basta con que
                // ese programa no esté funcionando y lleve unas horas quieta (Clang: 6 h; la caché de Node: 1 día).
                let umbral = Self.umbralesPorClave[clave]
                let diasMinimos = umbral?.dias ?? (esCache ? 3 : 7)
                let actividad = c.indice.masReciente(de: [h])
                let dias = actividad.map { Date().timeIntervalSince($0) / 86400 } ?? 999
                let viejo = dias >= diasMinimos
                // Las de programa conocido (Clang, Metal, la caché de Node) y las cachés (C) de una app instalada, en «Liberar
                // al máximo» con 2 h sin cambios: mientras la app esté abierta las sigue bloqueando (y «Cerrar y limpiar»
                // la ofrece); cerrada, se regeneran al volver a abrirla.
                let deApp = esCache && umbral == nil && c.apps.nombreApp(para: clave) != nil
                let enMaximo = !viejo && (umbral != nil || deApp) && dias * 24 >= 2
                let espera = diasMinimos < 1 ? "\(Int(diasMinimos * 24)) h" : diasMinimos == 1 ? "1 día" : "\(Int(diasMinimos)) días"
                var motivos: [Motivo] = [viejo
                    ? .bien("arrow.triangle.2.circlepath", esCache ? "Se regenera" : "Temporal",
                            "Nadie lo toca desde \(Formato.haceCuanto(actividad).lowercased()).")
                    : .info("clock.fill", "Usado hace poco",
                            "Se usó \(Formato.haceCuanto(actividad).lowercased()): mejor deja que \(app) termine con él. Lo marco cuando lleve \(espera) sin cambios"
                            + (enMaximo ? "; «Liberar al máximo» ya lo incluye, porque lleva más de 2 h sin cambios." : "."))]
                if let umbral, umbral.uso != nil {
                    motivos.append(.info("hammer.fill", "Sin \(umbral.quien) en marcha",
                        "Se marca cuando lleva \(espera) sin cambios y no está funcionando \(umbral.cual), que es lo que la usa. Si arranca uno mientras limpias, me la salto."))
                }
                r.append(Elemento(
                    nombre: "\(esCache ? "Caché" : "Temporales") de \(app)",
                    detalle: esCache ? "Caché que \(app) guarda en la carpeta privada de macOS para tu usuario."
                                     : "Archivos temporales que \(app) dejó en la carpeta privada de macOS para tu usuario.",
                    consecuencia: esCache ? "\(app) la vuelve a crear cuando la necesita." : "Nada: son temporales que \(app) ya no usa.",
                    rutas: [h], categoria: .sistema, riesgo: .seguro, seleccionado: viejo || enMaximo, motivos: motivos,
                    enUso: umbral?.uso ?? .app(nombre: app, claves: [clave, app]), dueno: app, nivel: enMaximo ? .maximo : .normal,
                    costes: clave == "clang" ? [.recompilacion(proyecto: "tus proyectos de Xcode, Swift o C")] : [],
                    cambioAnalizado: umbral != nil ? actividad : nil))
            }
            for app in conSueltos.sorted() { r += temporalesSueltos(de: app, en: raiz, c) }
        }

        // /tmp: lo que dejan programas y scripts (zips, repos clonados para una prueba…). Solo lo tuyo. Se marca con 24 h
        // sin cambios si nadie lo usa (ni un programa dentro, ni un socket o un .pid de un proceso vivo) y no guarda
        // resultados que no estén en ninguna otra parte (informes, tablas, capturas…): esos pueden ser lo único que
        // queda de un trabajo.
        var leidos: Int64 = 0
        for ruta in c.indice.tmp {
            let h = URL(fileURLWithPath: ruta)
            // Lo que no llega al mínimo no se va a ofrecer: no hace falta revisarlo (ni mirar quién lo usa).
            guard c.indice.bytes(de: h) >= minimo else { continue }
            let nombre = h.lastPathComponent
            let actividad = c.indice.masReciente(de: [h])
            let horas = actividad.map { Date().timeIntervalSince($0) / 3600 } ?? .infinity
            let efimero = Self.efimerosEnTmp.contains { nombre.hasPrefix($0) }
            let unicos = efimero ? Unicos() : resultadosUnicos(en: ruta, c, leidos: &leidos)
            var motivos: [Motivo] = []
            var consecuencia = "Se borra. Lo que se guarda en /tmp es temporal (macOS lo vacía al reiniciar): ningún programa debería necesitarlo para siempre."
            if !unicos.vacio {
                // Como mucho se nombran cinco: si hay más, «y otros».
                let lista = unicos.mas ? unicos.nombres.prefix(3).joined(separator: ", ") + " y otros" : Formato.listaCorta(unicos.nombres)
                motivos.append(.aviso("doc.text.magnifyingglass", "Resultados únicos", unicos.sinRevisar
                    ? "Tiene demasiados archivos para comprobar que sus resultados (informes, tablas, capturas…) estén también en otro sitio. Puede ser lo único que queda de un trabajo: revísalo antes de borrarlo."
                    : "Tiene resultados que no están en ningún otro sitio de tus carpetas: \(lista). Puede ser lo único que queda de un trabajo (un informe, unas pruebas): guárdalos antes si los necesitas."))
                consecuencia += unicos.sinRevisar ? "" : " Ojo: también se borran \(lista), que no están en ningún otro sitio."
            } else if !unicos.copias.isEmpty {
                let n = Set(unicos.copias.map(\.de)).count
                motivos.append(.bien("doc.on.doc", "Resultados con copia",
                    "\(n == 1 ? "Su resultado (informe, tabla, captura…) está" : "Sus \(n) resultados (informes, tablas, capturas…) están") también en tus carpetas, idénticos. Antes de borrarlo vuelvo a comprobar que esas copias sigan ahí y no las borre esta misma limpieza."))
            }
            if efimero {
                motivos.append(.bien("arrow.triangle.2.circlepath", "Temporal de una herramienta",
                                     "Es una carpeta de trabajo de una herramienta (npm, pip, tmux…) que se vuelve a crear sola."))
            }
            // Con 24 h sin cambios, en el modo normal; con 2 h, solo en «Liberar al máximo». Con resultados únicos, nunca.
            let enMaximo = horas >= 2 && horas < 24
            let cuando = Formato.haceCuanto(actividad).lowercased()
            motivos.append(horas >= 24
                ? .bien("clock.arrow.circlepath", "Temporal", "Nadie lo toca desde \(cuando) y ningún programa trabaja ahí dentro.")
                : !unicos.vacio
                    ? .info("clock.fill", "Usado hace poco", "Se usó \(cuando): puede que algún programa todavía lo esté usando.")
                    : .info("clock.fill", "Usado hace poco", "Se usó \(cuando): puede que algún programa todavía lo esté usando. Lo marco cuando lleve 24 h sin cambios"
                            + (enMaximo ? "; «Liberar al máximo» ya lo incluye, porque lleva más de 2 h sin cambios y nada lo usa." : ".")))
            if !unicos.vacio {
                motivos.append(.info("hand.raised.fill", "No lo marco",
                    "No lo marco aunque pasen días: \(unicos.sinRevisar ? "no pude comprobar que sus resultados estén en otro sitio" : "tiene resultados que no están en ningún otro sitio"). Si ya no los necesitas, márcalo tú (va a la Papelera)."))
            }
            r.append(Elemento(
                nombre: nombre,
                detalle: "\(Rutas.esCarpeta(h) ? "Carpeta" : "Archivo") en /tmp, la carpeta de temporales que comparten todos los programas.",
                consecuencia: consecuencia,
                rutas: [h], ultimoUso: actividad, categoria: .sistema, riesgo: unicos.vacio ? .seguro : .revisar,
                seleccionado: horas >= 2 && unicos.vacio, motivos: motivos,
                // Un programa que trabaja ahí, lo tiene abierto, escucha en un socket de dentro, guardó ahí su .pid o lo
                // recibió al arrancar lo está usando, aunque sea viejo. Si algo cambia después del análisis, no se toca.
                enUso: .carpetaTemporal(nombre: nombre, raiz: ruta), nivel: enMaximo ? .maximo : .normal, cambioAnalizado: actividad,
                copiasExigidas: unicos.vacio ? unicos.copias : []))
        }
        r += sesionesDeAgentes(c)
        return r
    }

    /// Las carpetas de trabajo de las sesiones de Claude Code (/tmp/claude-<uid>/<proyecto>/<sesión>) y lo que un agente
    /// dejó suelto en /tmp/claude-<uid> (casas de prueba…). Cuando la sesión terminó no las usa nadie, pero pueden tener
    /// resultados que quieras leer (informes, pruebas, notas del agente): solo se enseñan para revisar y nunca se marcan.
    /// No salen las que cambiaron en las últimas 24 h (la sesión puede seguir abierta) ni la que contiene la carpeta que se
    /// analiza; las que algo usa al limpiar (un programa dentro, un archivo abierto, un .pid vivo) se saltan.
    private func sesionesDeAgentes(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        for ruta in c.indice.sesionesDeAgentes {
            let u = URL(fileURLWithPath: ruta)
            guard c.indice.bytes(de: u) >= minimo else { continue }
            let actividad = c.indice.masReciente(de: [u])
            let horas = actividad.map { Date().timeIntervalSince($0) / 3600 } ?? .infinity
            guard horas >= 24 else { continue }
            let padre = Rutas.padre(ruta)
            let esSesion = Rutas.nombre(padre).hasPrefix("-")
            let proyecto = esSesion ? Self.proyectoDeSesion(Rutas.nombre(padre)) : nil
            let nombre = esSesion
                ? "Sesión de Claude Code\(proyecto.map { " en \(Rutas.nombre($0))" } ?? "") (\(Rutas.nombre(ruta).prefix(8)))"
                : "\(Rutas.nombre(ruta)) (de un agente, en /tmp)"
            let cuando = Formato.haceCuanto(actividad).lowercased()
            r.append(Elemento(
                nombre: nombre,
                detalle: esSesion
                    ? "Carpeta de trabajo temporal de una sesión de Claude Code\(proyecto.map { " en \(Formato.rutaCorta($0))" } ?? ""): lo que el agente guardó mientras trabajaba (pruebas, borradores, resultados)."
                    : "Carpeta que un agente (Claude Code) dejó en su carpeta de /tmp.",
                consecuencia: "Se borra esa carpeta temporal con lo que el agente dejó en ella; tu proyecto no se toca. Va a la Papelera: la puedes recuperar antes de vaciarla.",
                rutas: [u], ultimoUso: actividad, categoria: .sistema, riesgo: .revisar,
                motivos: [.info("moon.zzz.fill", "Inactiva desde \(cuando)",
                                "Nada cambió dentro desde \(cuando), así que la sesión ya no la usa. Pero puede tener resultados que quieras leer (informes, pruebas, notas del agente): revísala antes. No la marco nunca.")],
                enUso: .carpetaTemporal(nombre: nombre, raiz: ruta), dueno: "Claude Code"))
        }
        return r
    }

    /// El proyecto de una carpeta de sesiones de Claude Code. Su nombre es la ruta del proyecto con «-» en lugar de «/»
    /// («-Users-gustavo-Downloads-Mi-App» es ~/Downloads/Mi-App): se busca qué carpeta existe, probando en cada guion si
    /// separaba carpetas o era parte del nombre (dos guiones seguidos: una carpeta que empieza por guion). nil si no hay
    /// ninguna.
    static func proyectoDeSesion(_ carpeta: String) -> String? {
        let partes = carpeta.split(separator: "-", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard let primera = partes.first, !primera.isEmpty, partes.count <= 24 else { return nil }
        func buscar(_ i: Int, _ actual: String) -> String? {
            if i == partes.count { return Rutas.esCarpeta(URL(fileURLWithPath: actual)) ? actual : nil }
            // La parte siguiente, en una carpeta nueva (si la de ahora existe)…
            if Rutas.esCarpeta(URL(fileURLWithPath: actual)), let r = buscar(i + 1, actual + "/" + partes[i]) { return r }
            // …o en el mismo nombre, con su guion.
            return buscar(i + 1, actual + "-" + partes[i])
        }
        return buscar(1, "/" + primera)
    }

    /// Los temporales sueltos de una app en T («.com.openai.codex.AbC123»): uno por cada vez que la app necesitó un
    /// archivo para un momento. La app no los borra y nadie los vuelve a abrir. Se ofrecen juntos los que llevan 24 h
    /// sin cambios y nadie tiene abiertos; al limpiar se vuelven a listar (`.borrarSueltos`).
    private func temporalesSueltos(de id: String, en carpeta: String, _ c: Contexto) -> [Elemento] {
        let prefijo = "." + id + "."
        let l = TemporalesSueltos.listar(en: carpeta, prefijo: prefijo, minHoras: 24, abiertos: c.procesos.abiertos)
        // Los de 2 h a 24 h que nadie tiene abiertos: solo en «Liberar al máximo».
        let viejos = Set(l.viejos.map(\.ruta))
        let recientes = TemporalesSueltos.listar(en: carpeta, prefijo: prefijo, minHoras: Self.horasSueltosMaximo,
                                                 abiertos: c.procesos.abiertos).viejos.filter { !viejos.contains($0.ruta) }
        let app = c.apps.nombreApp(para: id) ?? nombreBonito(id)
        var r: [Elemento] = []
        if !l.viejos.isEmpty {
            let bytes = l.viejos.reduce(Int64(0)) { $0 + $1.bytes }
            var motivos: [Motivo] = [.bien("doc.badge.clock", "Olvidados",
                "\(app) los creó para un momento (con nombres al azar, «\(prefijo)XXXXXX») y nunca los borró: no los vuelve a abrir. Solo cuentan los que llevan 24 h o más sin cambios y que ningún programa tiene abiertos.")]
            let quedan = l.recientes + l.abiertosAhora
            if quedan > 0 {
                motivos.append(.info("clock.fill", "Los recientes se quedan",
                    "Hay otros \(Formato.numero(quedan)) más nuevos\(l.abiertosAhora > 0 ? " o abiertos ahora (\(l.abiertosAhora) abiertos)" : ""): no se tocan."))
            }
            r.append(Elemento(
                nombre: "Temporales sueltos de \(app)",
                detalle: "\(Formato.numero(l.viejos.count)) archivos temporales que \(app) dejó sueltos en tu carpeta de temporales de macOS.",
                consecuencia: "Se eliminan al instante, sin pasar por la Papelera (son miles de archivos pequeños), así que no se puede deshacer; \(app) no los necesita. Al limpiar los vuelvo a mirar uno por uno y me salto los que estén abiertos o hayan cambiado en las últimas 24 h.",
                rutas: [URL(fileURLWithPath: carpeta)], tamanoFijo: bytes, ultimoUso: l.viejos.map(\.modificado).max(),
                categoria: .sistema, riesgo: .seguro, seleccionado: true,
                accion: .borrarSueltos(carpeta: carpeta, prefijo: prefijo, minHoras: 24), motivos: motivos, dueno: app))
        }
        if !recientes.isEmpty {
            let horas = Int(Self.horasSueltosMaximo)
            r.append(Elemento(
                nombre: "Temporales sueltos recientes de \(app)",
                detalle: "\(Formato.numero(recientes.count)) archivos temporales que \(app) dejó sueltos en tu carpeta de temporales de macOS en las últimas 24 h (con \(horas) h o más sin cambios).",
                consecuencia: "Se eliminan al instante, sin pasar por la Papelera, así que no se puede deshacer. Son del mismo tipo que los de más de 24 h: \(app) los crea para un momento y no los vuelve a abrir. Al limpiar los vuelvo a mirar uno por uno y me salto los que estén abiertos o hayan cambiado en las últimas \(horas) h (los de más de 24 h que sigan ahí también se borran).",
                rutas: [URL(fileURLWithPath: carpeta)], tamanoFijo: recientes.reduce(Int64(0)) { $0 + $1.bytes },
                ultimoUso: recientes.map(\.modificado).max(), categoria: .sistema, riesgo: .seguro, seleccionado: true,
                accion: .borrarSueltos(carpeta: carpeta, prefijo: prefijo, minHoras: Self.horasSueltosMaximo),
                motivos: [.bien("doc.badge.clock", "Olvidados", "Llevan \(horas) h o más sin cambios y ningún programa los tiene abiertos."),
                          .info("bolt.fill", "Solo en «Liberar al máximo»",
                                "Por prudencia, en el modo normal espero 24 h. «Liberar al máximo» los incluye desde las \(horas) h.")],
                dueno: app, nivel: .maximo))
        }
        return r
    }

    /// Desde cuántas horas sin cambios «Liberar al máximo» incluye los temporales sueltos (en el modo normal, 24 h).
    static let horasSueltosMaximo: Double = 2

    /// Lo que `resultadosUnicos` encontró en algo de /tmp.
    private struct Unicos {
        /// Algunos de los archivos de resultados que no tienen copia en tus carpetas (como mucho cinco).
        var nombres: [String] = []
        /// Hay más de los que se nombran.
        var mas = false
        /// Había demasiados archivos para mirarlos todos: se trata como si tuviera resultados únicos.
        var sinRevisar = false
        /// Las copias de tus carpetas que hacen que sus resultados no sean únicos (una por archivo): al limpiar se vuelve a
        /// comprobar que siguen ahí (`Elemento.copiasExigidas`).
        var copias: [CopiaExigida] = []
        var vacio: Bool { nombres.isEmpty && !sinRevisar }
    }

    /// Dentro de /tmp, carpetas que no guardan resultados de nadie: dependencias descargadas, historial de git, cachés.
    private static let sinResultados: Set<String> = ["node_modules", ".git", "__pycache__", "site-packages", ".venv", "venv", "Pods",
                                                     ".gradle", "bower_components"]
    /// Archivos de configuración de proyectos y paquetes: no son el resultado de un trabajo.
    private static let noSonResultados: Set<String> = ["package.json", "package-lock.json", "tsconfig.json", "jsconfig.json",
                                                       "composer.json", "requirements.txt"]

    /// Los archivos de resultados (`Resultados.extensiones`: informes, tablas, capturas…) de algo de /tmp que no tienen
    /// copia idéntica en tus carpetas: con el mismo nombre y tamaño (según el índice) y el mismo contenido (SHA-256).
    /// Primero los que no tienen ningún candidato, que no hace falta leer. `leidos` limita lo que se lee para comparar
    /// entre todos: lo que ya no se pudo comparar cuenta como único. No cuenta como copia lo que está en una carpeta que
    /// piensas borrar («Eliminar», «Old», «tmp»… `nombreDeBorrar`) ni en la Papelera: esa copia también se puede ir.
    private func resultadosUnicos(en ruta: String, _ c: Contexto, leidos: inout Int64) -> Unicos {
        struct Archivo { let ruta: String; let nombre: String; let tamano: Int64; let clave: UInt64 }
        var archivos: [Archivo] = []
        var u = Unicos()
        guard let rutaC = strdup(ruta) else { return u }
        defer { free(rutaC) }
        var argumentos: [UnsafeMutablePointer<CChar>?] = [rutaC, nil]
        guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return u }
        var vistos = 0
        while let e = fts_read(fts) {
            vistos += 1
            if vistos > 50_000 { u.sinRevisar = true; break }
            let largo = Int(e.pointee.fts_namelen)
            let nombreC = e.pointee.fts_path + (Int(e.pointee.fts_pathlen) - largo)
            switch Int32(e.pointee.fts_info) {
            case FTS_D:
                let n = String(cString: nombreC)
                let ext = (n as NSString).pathExtension.lowercased()
                if e.pointee.fts_level > 0 && (Self.sinResultados.contains(n) || ["app", "framework", "bundle", "xcarchive"].contains(ext)) {
                    fts_set(fts, e, FTS_SKIP)
                }
            case FTS_F:
                let tamano = Int64(e.pointee.fts_statp.pointee.st_size)
                guard tamano > 0 else { continue }
                let n = String(cString: nombreC)
                guard Resultados.extensiones.contains((n as NSString).pathExtension.lowercased()),
                      !Self.noSonResultados.contains(n), !n.lowercased().hasPrefix("license") else { continue }
                archivos.append(Archivo(ruta: String(cString: e.pointee.fts_path), nombre: n, tamano: tamano,
                                        clave: Resultados.clave(nombreC, largo, tamano)))
            default:
                break
            }
        }
        fts_close(fts)
        if u.sinRevisar { return u }

        // Las copias que valen: las de tus carpetas que no vas a borrar (ni en una carpeta «Eliminar», «Old», «tmp»…, ni en
        // la Papelera).
        let home = Rutas.home.path
        func vale(_ otra: String) -> Bool {
            guard otra.hasPrefix(home + "/") else { return true }   // /Users/Shared
            let partes = otra.dropFirst(home.count + 1).split(separator: "/").dropLast()
            return partes.first != ".Trash" && !partes.contains { Self.nombreDeBorrar(String($0)) }
        }
        func posibles(_ a: Archivo) -> [String] { c.indice.posiblesCopias(clave: a.clave).filter(vale) }
        // Sin ningún archivo igual de nombre y tamaño en tus carpetas: único, sin leer nada.
        let sinCandidatos = archivos.filter { posibles($0).isEmpty }
        u.nombres = Array(sinCandidatos.prefix(5).map(\.nombre))
        u.mas = sinCandidatos.count > 5
        guard u.nombres.count < 5 else { return u }
        for a in archivos where !posibles(a).isEmpty {
            let candidatos = posibles(a).filter { otra in
                var st = stat()
                return lstat(otra, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && Int64(st.st_size) == a.tamano
            }
            var copia: CopiaExigida?
            if let rapida = Huella.parcial(URL(fileURLWithPath: a.ruta), tamano: a.tamano) {
                for otra in candidatos where Huella.parcial(URL(fileURLWithPath: otra), tamano: a.tamano) == rapida {
                    // Igual por el principio y el final: se compara entero, mientras no se pase de lo que se puede leer.
                    guard leidos + 2 * a.tamano <= 2_000_000_000 else { break }
                    leidos += 2 * a.tamano
                    if let h = Huella.sha256(URL(fileURLWithPath: a.ruta)), h == Huella.sha256(URL(fileURLWithPath: otra)) {
                        copia = CopiaExigida(ruta: otra, de: a.ruta, tamano: a.tamano, huella: rapida)
                        break
                    }
                }
            }
            if let copia {
                u.copias.append(copia)
            } else if u.nombres.count < 5 {
                u.nombres.append(a.nombre)
            } else {
                u.mas = true
                break
            }
        }
        return u
    }

    // MARK: - Apps que no usas

    private func apps(_ c: Contexto) -> [Elemento] {
        var candidatas: [URL] = []
        for carpeta in [URL(fileURLWithPath: "/Applications"), Rutas.enHome("Applications")] {
            for h in Rutas.hijos(carpeta) {
                if h.pathExtension == "app" { candidatas.append(h) }
                else if h.pathExtension.isEmpty && Rutas.esCarpeta(h) {
                    candidatas += Rutas.hijos(h).filter { $0.pathExtension == "app" }
                }
            }
        }
        // Sin Spotlight no hay registro de uso: mejor no decir que nada se usa.
        let usos = Dictionary(uniqueKeysWithValues: candidatas.map { ($0, Fechas.ultimoUsoSpotlight($0)) })
        guard usos.values.contains(where: { $0 != nil }) else { return [] }

        var r: [Elemento] = []
        for app in candidatas {
            guard let b = Bundle(url: app), let id = b.bundleIdentifier, !id.lowercased().hasPrefix("com.apple.") else { continue }
            let info = b.infoDictionary ?? [:]
            // Apps de la barra de menús y agentes: funcionan sin que las abras, así que macOS no registra su uso.
            if Self.verdadero(info["LSUIElement"]) || Self.verdadero(info["LSBackgroundOnly"]) { continue }
            let nombre = app.deletingPathExtension().lastPathComponent
            if c.procesos.appAbierta([id, nombre]) != nil { continue }
            // Spotlight pierde el último uso cuando la app se actualiza: lo que la app escribe al usarse
            // (sus ajustes) también cuenta. El contenedor de otra app solo se mira con Acceso total al disco.
            var ajustes = [Rutas.enHome("Library/Preferences/\(id).plist")]
            if c.accesoTotal { ajustes.append(Rutas.enHome("Library/Containers/\(id)/Data/Library/Preferences/\(id).plist")) }
            let usada = [usos[app] ?? nil, ajustes.compactMap(Fechas.modificacion).max()].compactMap { $0 }.max()
            let llego = Fechas.agregadoSpotlight(app) ?? (try? app.resourceValues(forKeys: [.creationDateKey]).creationDate)
            // El contenedor solo se puede mirar con Acceso total al disco.
            let nunca = Self.nuncaAbierta(usada: usada, contenedor: c.accesoTotal && Rutas.existe(Rutas.enHome("Library/Containers/\(id)")))
            guard let referencia = usada ?? llego, Date().timeIntervalSince(referencia) > Self.diasSinUso(nunca: nunca) * 86400 else { continue }
            let tamano = Tamanos.de(app)
            guard tamano >= 20_000_000 else { continue }

            let deLaTienda = Rutas.existe(app.appendingPathComponent("Contents/_MASReceipt"))
            let dueno = (try? FileManager.default.attributesOfItem(atPath: app.path)[.ownerAccountID] as? NSNumber)?.intValue
            var motivos: [Motivo] = [nunca
                ? .info("questionmark.app.fill", "Nunca la has abierto",
                        "macOS no tiene ningún registro de que la hayas abierto desde que llegó a este Mac (\(Formato.haceCuanto(llego).lowercased())), y no hay ajustes suyos. Si no la necesitas, ocupa espacio sin servirte.")
                : usada == nil
                ? .info("questionmark.app.fill", "Sin registro de uso",
                        "macOS no tiene registro de que la hayas abierto, y no guarda ajustes. Llegó a este Mac \(Formato.haceCuanto(llego).lowercased()).")
                : .bien("moon.zzz.fill", "Sin usar", "La última señal de uso es de \(Formato.haceCuanto(usada).lowercased()).")]
            if dueno == 0 {
                motivos.append(.info("lock.fill", "Pide tu contraseña",
                                     "La instaló un instalador del sistema: al moverla a la Papelera, macOS te pedirá tu contraseña."))
            }
            r.append(Elemento(
                nombre: nombre,
                detalle: "App en \(Formato.rutaCorta(app.deletingLastPathComponent()))\(deLaTienda ? ", de la App Store" : "").",
                consecuencia: (deLaTienda ? "Puedes volver a descargarla desde la App Store." : "Si la necesitas otra vez, tendrás que volver a instalarla.")
                    + " Sus ajustes y datos quedan en Library; en el próximo análisis aparecerán en «Restos de apps borradas».",
                rutas: [app], tamanosRutas: [tamano], ultimoUso: usada ?? llego, categoria: .apps, riesgo: .revisar,
                motivos: motivos, enUso: .app(nombre: nombre, claves: [id, nombre]), dueno: nombre))
        }
        return r
    }

    /// Una app que nunca se abrió: sin registro de uso, sin ajustes guardados y sin contenedor (macOS lo crea la primera
    /// vez que se abre una app de la tienda).
    static func nuncaAbierta(usada: Date?, contenedor: Bool) -> Bool { usada == nil && !contenedor }

    /// Cuántos días sin usarse (o desde que llegó, si nunca se abrió) hacen falta para mostrar una app: un mes si nunca
    /// se abrió, tres meses si no.
    static func diasSinUso(nunca: Bool) -> Double { nunca ? 30 : 90 }

    private static func verdadero(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s == "1" || s.lowercased() == "true" || s.lowercased() == "yes" }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    // MARK: - Restos de apps desinstaladas

    private struct Resto {
        let url: URL
        let nombre: String
        let lugar: String
    }

    private func restos(_ c: Contexto) -> [Elemento] {
        var candidatos: [Resto] = []
        var lugares: [(String, String)] = [
            ("Library/Application Support", "Datos"), ("Library/Caches", "Caché"), ("Library/Logs", "Registros"),
            ("Library/Saved Application State", "Estado de ventanas"), ("Library/HTTPStorages", "Datos web"),
            ("Library/WebKit", "Datos web"), ("Library/Application Scripts", "Scripts"),
        ]
        if c.accesoTotal {
            lugares += [("Library/Containers", "Contenedor"), ("Library/Group Containers", "Contenedor compartido")]
        } else {
            c.indice.probablesRestos = probablesRestos(c)
        }
        for (rel, lugar) in lugares {
            for h in Rutas.hijos(Rutas.enHome(rel)) {
                let n = h.lastPathComponent
                if n.hasPrefix(".") || Self.propios.contains(n) { continue }
                if rel == "Library/Caches" && Self.cachesDeDesarrolloEnLibrary.contains(n) { continue }
                let clave = n.replacingOccurrences(of: ".savedState", with: "")
                if c.apps.estaInstalado(carpeta: clave) { continue }
                candidatos.append(Resto(url: h, nombre: clave, lugar: lugar))
            }
        }
        for p in Rutas.hijos(Rutas.enHome("Library/Preferences")) where p.pathExtension == "plist" {
            let id = p.deletingPathExtension().lastPathComponent
            guard id.split(separator: ".").count >= 3, !Self.propios.contains(id),
                  !c.apps.estaInstalado(carpeta: p.lastPathComponent) else { continue }
            candidatos.append(Resto(url: p, nombre: id, lugar: "Preferencias"))
        }
        var reubicados: [URL] = []
        for h in Rutas.hijos(URL(fileURLWithPath: "/Users/Shared")) {
            let n = h.lastPathComponent
            if n.hasPrefix(".") || n == "SC Info" { continue }
            if n.hasPrefix("Previously Relocated Items") || n == "Relocated Items" { reubicados.append(h); continue }
            // /Users/Shared/Library no es una app «Library»: se revisa por dentro como cualquier Application Support.
            if n == "Library" {
                for d in Rutas.hijos(h.appendingPathComponent("Application Support")) where !d.lastPathComponent.hasPrefix(".") {
                    if c.apps.estaInstalado(carpeta: d.lastPathComponent) { continue }
                    candidatos.append(Resto(url: d, nombre: d.lastPathComponent, lugar: "Datos compartidos"))
                }
                continue
            }
            if c.apps.estaInstalado(carpeta: n) { continue }
            candidatos.append(Resto(url: h, nombre: n, lugar: "Carpeta compartida"))
        }
        // Agentes de inicio: los que abren un programa que ya no existe, o uno que está dentro de otro resto.
        var agentes = Set<String>()
        let rutasRestos = candidatos.map { $0.url.path }
        for p in Rutas.hijos(Rutas.enHome("Library/LaunchAgents")) where p.pathExtension == "plist" {
            guard let d = NSDictionary(contentsOf: p) else { continue }
            let programa = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
            guard let programa, programa.hasPrefix("/") else { continue }
            let huerfano = !Rutas.existe(programa)
            let dentroDeResto = rutasRestos.contains { programa.hasPrefix($0 + "/") }
            guard huerfano || dentroDeResto else { continue }
            let etiqueta = (d["Label"] as? String) ?? p.deletingPathExtension().lastPathComponent
            candidatos.append(Resto(url: p, nombre: etiqueta, lugar: "Agente de inicio"))
            agentes.insert(p.path)
        }

        var r: [Elemento] = []
        var sueltas: [URL] = []
        // Un contenedor que guarda datos de su app (chats, bases de datos, documentos) nunca va mezclado con otros restos:
        // va solo y con «Cuidado» (p. ej. WhatsApp Business guarda los chats en su contenedor compartido).
        var conDatos: [Resto] = []
        candidatos.removeAll { resto in
            guard ["Contenedor", "Contenedor compartido"].contains(resto.lugar), guardaDatos(resto.url, c) else { return false }
            conDatos.append(resto)
            return true
        }
        for resto in conDatos {
            let nombre = c.apps.nombreApp(para: resto.nombre) ?? nombreBonito(resto.nombre)
            r.append(Elemento(
                nombre: "Datos de \(nombre)",
                detalle: "\(resto.lugar) de una app que no encontré instalada, pero que todavía guarda datos propios (bases de datos, chats, documentos o sesiones).",
                consecuencia: "Si la app sigue en algún sitio o la vuelves a instalar, habrá perdido sus datos: chats, sesiones, documentos. Solo se podrían recuperar desde la Papelera.",
                rutas: [resto.url], categoria: .restos, riesgo: .cuidado,
                motivos: [.aviso("externaldrive.fill.badge.person.crop", "Contiene datos de la app",
                                 "No es solo caché: guarda bases de datos o documentos de la app. Bórralo solo si sabes que ya no la vas a usar."),
                          .info("magnifyingglass", "No está instalada", "No encontré \(nombre) en Aplicaciones ni entre los programas abiertos.")],
                enUso: .app(nombre: nombre, claves: [resto.nombre, nombre]), dueno: nombre))
        }

        for grupo in agrupar(candidatos) {
            if grupo.count == 1 && grupo[0].lugar == "Preferencias" { sueltas.append(grupo[0].url); continue }
            let nombre = nombreDeGrupo(grupo, c)
            let rutas = grupo.map(\.url)
            let lugaresGrupo = Array(Set(grupo.map { $0.lugar.lowercased() })).sorted()
            var motivos: [Motivo] = [
                .bien("magnifyingglass", "No está instalada",
                      "No encontré \(nombre) en Aplicaciones, ni en Homebrew, ni entre los programas abiertos."),
            ]
            if grupo.contains(where: { agentes.contains($0.url.path) }) {
                motivos.append(.bien("power", "Agente de inicio",
                                     "Incluye un agente que se ejecuta cada vez que enciendes el Mac. También lo desactivo al limpiar."))
            }
            if grupo.contains(where: { $0.lugar == "Carpeta compartida" && Rutas.hijos($0.url).contains { $0.pathExtension == "app" } }) {
                motivos.append(.info("app.dashed", "App escondida",
                                     "Dentro hay una app instalada fuera de Aplicaciones (los juegos suelen hacerlo). Si ya no la usas, sobra junto con sus datos."))
            }
            if let actividad = c.indice.masReciente(de: rutas) {
                let dias = Date().timeIntervalSince(actividad) / 86400
                if dias < 7 {
                    motivos.append(.aviso("clock.fill", "Actividad reciente",
                                          "Tuvo actividad \(Formato.haceCuanto(actividad).lowercased()): puede que algún programa todavía lo use."))
                } else if dias > 60 {
                    motivos.append(.bien("moon.zzz.fill", "Sin uso", "Nadie lo ha tocado desde \(Formato.haceCuanto(actividad).lowercased())."))
                }
            }
            // La carpeta compartida la usan emuladores, juegos e instrumentos de audio: lo que hay ahí puede no volver.
            let compartido = grupo.contains { $0.lugar == "Carpeta compartida" || $0.lugar == "Datos compartidos" }
            r.append(Elemento(
                nombre: nombre,
                detalle: grupo.count == 1
                    ? "\(grupo[0].lugar) de un programa que ya no está instalado."
                    : "Lo que dejó \(nombre) en \(grupo.count) lugares: \(Formato.lista(lugaresGrupo)).",
                consecuencia: compartido
                    ? "Si algún programa todavía usa la carpeta compartida (máquinas virtuales, progreso de juegos, librerías de sonidos), perderá esos datos y no se pueden volver a descargar."
                    : "No afecta a ninguna app instalada. Si algún día reinstalas \(nombre), empezará sin tu configuración anterior.",
                rutas: rutas, categoria: .restos, riesgo: compartido ? .cuidado : .revisar, motivos: motivos,
                enUso: .app(nombre: nombre, claves: grupo.map(\.nombre) + [nombre]), dueno: nombre))
        }
        if !sueltas.isEmpty {
            r.append(Elemento(
                nombre: "Preferencias de \(sueltas.count) apps desinstaladas",
                detalle: Formato.listaCorta(sueltas.map { $0.deletingPathExtension().lastPathComponent }, maximo: 5),
                consecuencia: "Nada: son ajustes de apps que ya no tienes.",
                rutas: sueltas, categoria: .restos, riesgo: .revisar,
                motivos: [.bien("magnifyingglass", "Apps no instaladas", "Ninguna de estas apps está instalada.")]))
        }
        for h in reubicados {
            r.append(Elemento(
                nombre: h.lastPathComponent,
                detalle: "Archivos que macOS apartó durante una actualización del sistema.",
                consecuencia: "Normalmente no hacen falta, pero revisa su contenido antes.",
                rutas: [h], categoria: .restos, riesgo: .revisar,
                motivos: [.info("arrow.up.bin.fill", "Actualización de macOS", "macOS los movió aquí porque no encajaban tras actualizar.")]))
        }
        return r
    }

    /// Sin Acceso total al disco no se puede mirar dentro de ~/Library/Containers ni de Group Containers, pero sí leer
    /// los nombres de sus carpetas: las de apps que no están instaladas (con la misma regla que «Restos de apps borradas»)
    /// se agrupan por app para decir cuáles hay. No se abre ninguna (macOS pediría permiso para ver datos de otras apps)
    /// ni se ofrece borrar nada: sin saber qué hay dentro ni cuánto ocupa, solo se informa.
    private func probablesRestos(_ c: Contexto) -> [ProbableResto] {
        var restos: [Resto] = []
        for (rel, lugar) in [("Library/Containers", "Contenedor"), ("Library/Group Containers", "Contenedor compartido")] {
            let carpeta = Rutas.enHome(rel).path
            for n in (try? FileManager.default.contentsOfDirectory(atPath: carpeta)) ?? [] {
                // Lo de Apple (y sus grupos, aunque lleven el código de otro equipo) es del sistema.
                let l = n.lowercased()
                guard !n.hasPrefix("."), !l.contains("apple"), !l.hasPrefix("group.is.workflow"), !Self.propios.contains(n),
                      !c.apps.estaInstalado(carpeta: n) else { continue }
                restos.append(Resto(url: URL(fileURLWithPath: carpeta + "/" + n), nombre: Self.sinPrefijos(n), lugar: lugar))
            }
        }
        return agrupar(restos).map { grupo in
            // El nombre de la app: el de la tercera parte del identificador («com.utmapp.UTM» → «UTM»).
            let corto = grupo.map(\.nombre).min { $0.count < $1.count } ?? ""
            let partes = corto.split(separator: ".")
            let parte = partes.count >= 3 ? String(partes[2]) : String(partes.last ?? Substring(corto))
            let nombre = c.apps.nombreApp(para: corto) ?? (parte.prefix(1).uppercased() + parte.dropFirst())
            return ProbableResto(nombre: nombre, carpetas: grupo.map { $0.url.lastPathComponent }.sorted())
        }
        .sorted { $0.carpetas.count != $1.carpetas.count ? $0.carpetas.count > $1.carpetas.count : $0.nombre < $1.nombre }
    }

    /// «WDNLXAD4W8.com.utmapp.UTM» y «group.com.utmapp.UTM» → «com.utmapp.UTM»: sin el código del equipo ni «group.».
    private static func sinPrefijos(_ n: String) -> String {
        var r = Substring(n)
        if AppsInstaladas.equipo(de: n) != nil { r = r.dropFirst(11) }
        if r.lowercased().hasPrefix("group.") { r = r.dropFirst(6) }
        return String(r)
    }

    /// ¿Guarda datos de verdad (bases de datos, chats, documentos), más allá de cachés?
    private func guardaDatos(_ url: URL, _ c: Contexto) -> Bool {
        if c.indice.contenido(de: [url]).bases > 0 { return true }
        let conDatos = ["Documents", "Data/Documents", "Message", "Media", "Library/Application Support", "Data/Library/Application Support"]
        return conDatos.contains { !Rutas.hijos(url.appendingPathComponent($0)).isEmpty }
    }

    /// Agrupa los restos que pertenecen a la misma app («Riot Client», «Riot Games», «com.riotgames…»).
    private func agrupar(_ restos: [Resto]) -> [[Resto]] {
        let genericos: Set<String> = ["google", "microsoft", "apple", "github", "adobe", "jetbrains", "mozilla",
                                      "electron", "openai", "amazon", "facebook", "meta"]
        var planas = Set<String>()
        for r in restos where r.nombre.split(separator: ".").count < 3 { planas.insert(clavePlana(r.nombre)) }
        let claves: [String] = restos.map { r in
            let partes = r.nombre.lowercased().split(separator: ".").map(String.init)
            guard partes.count >= 3 else { return clavePlana(r.nombre) }
            if let ultima = partes.last.map(AppsInstaladas.normalizar), planas.contains(ultima) { return ultima }
            let fabricante = AppsInstaladas.normalizar(partes[1])
            return genericos.contains(fabricante) ? fabricante + AppsInstaladas.normalizar(partes[2]) : fabricante
        }
        let unicas = Set(claves).sorted { $0.count < $1.count }
        var raiz: [String: String] = [:]
        for k in unicas {
            if let corta = unicas.first(where: { $0.count >= 4 && $0 != k && k.hasPrefix($0) }) {
                raiz[k] = raiz[corta] ?? corta
            } else {
                raiz[k] = k
            }
        }
        var grupos: [String: [Resto]] = [:]
        for (i, r) in restos.enumerated() { grupos[raiz[claves[i]] ?? claves[i], default: []].append(r) }
        return Array(grupos.values)
    }

    private func clavePlana(_ nombre: String) -> String {
        let palabras = nombre.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if let primera = palabras.first, primera.count >= 4 { return AppsInstaladas.normalizar(String(primera)) }
        return AppsInstaladas.normalizar(nombre)
    }

    private func nombreDeGrupo(_ grupo: [Resto], _ c: Contexto) -> String {
        let planos = grupo.filter { $0.nombre.split(separator: ".").count < 3 && $0.lugar != "Agente de inicio" }
        if let mayor = planos.max(by: { c.indice.bytes(de: $0.url) < c.indice.bytes(de: $1.url) }) { return mayor.nombre }
        let partes = grupo[0].nombre.split(separator: ".")
        if partes.count >= 3 { return String(partes[1]).capitalized }
        return grupo[0].nombre
    }

    // MARK: - Proyectos

    private func proyectos(_ c: Contexto) -> [Elemento] {
        var porProyecto: [String: [Artefacto]] = [:]
        for a in c.indice.artefactos { porProyecto[raizDeProyecto(a.ruta, c), default: []].append(a) }

        let conGit = porProyecto.keys.filter { c.indice.repos.contains($0) }
        let commits = Dictionary(uniqueKeysWithValues: zip(conGit, Self.enParalelo(conGit) { ultimoCommit($0) }))
        let versionadosEnGit = Dictionary(uniqueKeysWithValues: zip(conGit, Self.enParalelo(conGit) { raiz in
            Self.versionados(en: (porProyecto[raiz] ?? []).filter { $0.tipo != .venv }.map(\.ruta), repo: raiz)
        }))

        // Los emuladores de prueba que haya dentro se ofrecen aparte (en Emuladores): no van con el proyecto.
        let aislados = Self.emuladoresAislados(c)
        // Lo que se sabe de cada repositorio sin preguntar a git: otras copias del mismo origin y los puntos de
        // restauración de Codex. Solo se informa.
        let notas = notasDeRepositorios(c)

        var r: [Elemento] = []
        // Los repositorios cuyas notas ya van en algún elemento.
        var conNota = Set<String>()
        for (raiz, artefactos) in porProyecto {
            let nombre = Rutas.nombre(raiz)
            let regenerables = artefactos.filter { $0.tipo != .venv }
            let venvs = artefactos.filter { $0.tipo == .venv }
            let desde = r.count

            var actividad = c.indice.masRecientePropio(de: raiz)
            if let commit = commits[raiz] ?? nil {
                actividad = max(actividad ?? commit, commit)
            }
            let dias = actividad.map { Date().timeIntervalSince($0) / 86400 } ?? 999

            if !regenerables.isEmpty {
                // Los intermedios de compilación van aparte: son Seguro y se marcan solos si llevan 24 h quietos. El
                // elemento del proyecto se queda con lo demás (lo que entregas, los informes, las dependencias).
                var intermedios: [URL] = []
                var resto: [URL] = []
                var deResto: [Artefacto] = []
                // De lo que queda, las salidas de la compilación (lo que entregas, los informes…): ver `esSalida`.
                var salidas = Set<String>()
                for a in regenerables {
                    let suyos = Self.intermedios(de: a)
                    if suyos.isEmpty {
                        resto.append(URL(fileURLWithPath: a.ruta))
                        deResto.append(a)
                        if Self.esSalida(a) { salidas.insert(a.ruta) }
                        continue
                    }
                    intermedios += suyos
                    guard !(suyos.count == 1 && suyos[0].path == a.ruta) else { continue }
                    let quedan = Self.resto(de: a.ruta, sin: Set(suyos.map(\.path)))
                    if !quedan.isEmpty {
                        resto += quedan
                        deResto.append(a)
                        if Self.esSalida(a) { salidas.formUnion(quedan.map(\.path)) }
                    }
                }
                intermedios = Self.sin(aislados, en: intermedios)
                resto = Self.sin(aislados, en: resto)
                let todas = intermedios + resto
                // Si alguien guardó dentro de build/ cosas que la compilación no crea (copias de bases de datos,
                // trazas, emuladores de prueba, documentos, llaves), borrar la carpeta las pierde para siempre.
                // No cuentan las copias que hace la propia compilación (public/ → dist/, assets…): el original sigue en el proyecto.
                var vistos = Set<String>()
                let candidatos = Self.dentro(c.indice.noRegenerables + c.indice.sensibles.map(\.ruta), todas)
                    .filter { vistos.insert($0).inserted }
                let copias = Self.copiasDelProyecto(candidatos, raiz: raiz, artefactos: Set(artefactos.map(\.ruta)))
                c.memoria.copias.formUnion(copias)
                let perdidos = candidatos.filter { !copias.contains($0) }
                // Lo que está guardado en git no lo crea la compilación: lo guardaste tú (el instalador que entregas,
                // un dist/ que publicas…). Git lo puede devolver, salvo los cambios que no estén en un commit.
                let enGit = (versionadosEnGit[raiz] ?? []).filter { !vistos.contains($0) }

                // De mayor a menor: así se ven primero en el detalle.
                intermedios = deMayorAMenor(intermedios, c)
                resto = deMayorAMenor(resto, c)
                if !intermedios.isEmpty {
                    r.append(intermediosDeCompilacion(nombre, raiz: raiz, intermedios, perdidos: Self.dentro(perdidos, intermedios),
                                                      enGit: Self.dentro(enGit, intermedios), c))
                }
                if !resto.isEmpty {
                    let inactivo = dias > 30
                    // Mientras trabajas en el proyecto, sus salidas (lo que entregas, los informes y los resultados de
                    // pruebas) van aparte y no se marcan nunca, ni con «Liberar al máximo». El elemento del proyecto se
                    // queda con lo que se regenera solo: dependencias y cachés.
                    let esDeSalida = { (u: URL) in salidas.contains(u.path) || Totales.dentroDe(u.path, salidas) }
                    let deSalida = inactivo ? [] : resto.filter(esDeSalida)
                    let seRegenera = inactivo ? resto : resto.filter { !esDeSalida($0) }
                    func suyos(_ rutas: [URL]) -> [Artefacto] {
                        deResto.filter { a in rutas.contains { $0.path == a.ruta || $0.path.hasPrefix(a.ruta + "/") } }
                    }
                    if !seRegenera.isEmpty {
                        r.append(restoDelProyecto(nombre, raiz: raiz, seRegenera, suyos(seRegenera), actividad: actividad,
                                                  inactivo: inactivo, conSalidas: seRegenera.contains(where: esDeSalida),
                                                  perdidos: Self.dentro(perdidos, seRegenera), enGit: Self.dentro(enGit, seRegenera), c))
                    }
                    if !deSalida.isEmpty {
                        r.append(salidasDelProyecto(nombre, raiz: raiz, deSalida, actividad: actividad,
                                                    perdidos: Self.dentro(perdidos, deSalida), enGit: Self.dentro(enGit, deSalida), c))
                    }
                }
            }
            for v in venvs {
                r.append(Elemento(
                    nombre: "\(nombre) › \(Rutas.nombre(v.ruta))",
                    detalle: "Entorno virtual de Python con los paquetes del proyecto.",
                    consecuencia: "Tendrás que volver a crearlo e instalar los paquetes (pip install -r requirements.txt).",
                    rutas: [URL(fileURLWithPath: v.ruta)], ultimoUso: actividad, categoria: .proyectos, riesgo: .revisar,
                    motivos: [.info("shippingbox.fill", "Se puede recrear", "Se reconstruye, pero tendrás que reinstalar los paquetes.")],
                    dueno: nombre))
            }
            if let suyas = notas[raiz], desde < r.count {
                for i in desde..<r.count { r[i].motivos += suyas }
                // Solo cuenta si alguno se va a ver (lo pequeño no se ofrece).
                if r[desde...].contains(where: { $0.tamanosRutas.reduce(0, +) >= minimo }) { conNota.insert(raiz) }
            }
        }
        let compactar = historialesSinCompactar(c, notas: notas)
        for el in compactar { if case .compactarGit(let repo) = el.accion { conNota.insert(repo) } }
        r += compactar
        // Los puntos de restauración de Codex de un repositorio sin nada más que ofrecer (ni compilaciones ni historial
        // suelto) no se verían en ningún sitio: van como nota en «Compilaciones», con lo que ocupa su historial.
        for repo in notas.keys.sorted() where !conNota.contains(repo) {
            let n = Self.checkpointsDeCodex(repo)
            let git = tamanos([URL(fileURLWithPath: repo + "/.git")], c)[0]
            guard n > 0, git >= 50_000_000 else { continue }
            let nombre = Rutas.nombre(repo)
            c.indice.notas.append(NotaGrande(
                categoria: .proyectos, titulo: "Puntos de restauración de Codex en \(nombre)",
                texto: "Codex guarda \(n == 1 ? "un punto de restauración" : "\(n) puntos de restauración") en el git de \(Formato.rutaCorta(repo)) (refs/codex/…) para poder deshacer sus cambios, y mantienen vivo historial que tus ramas no usan: el .git ocupa \(Formato.bytes(git))\(Self.tieneRamas(repo) ? "" : " y, como tus ramas no tienen ningún commit, casi todo es de ellos"). No lo ofrezco para borrar: quitarlos es para siempre y ya no podrías deshacer esos turnos. Si no los necesitas, quítalos desde Codex o con git (git update-ref -d de cada refs/codex/… y luego git gc); tu código y tus commits no se tocan.",
                ruta: repo + "/.git", bytes: git))
        }
        return r
    }

    /// Lo que queda de un proyecto después de sus intermedios: dependencias y cachés (node_modules, Pods, lo de .gradle…)
    /// y, si el proyecto está inactivo (30 días sin cambiar el código), también sus salidas (`conSalidas`). Un proyecto en
    /// uso no se marca en el modo normal; en «Liberar al máximo» sí, si lleva 2 h sin compilar y sus dependencias tienen
    /// archivo de bloqueo. Uno inactivo se marca en el modo normal con 24 h sin compilar; con 2 h, solo en el máximo.
    private func restoDelProyecto(_ nombre: String, raiz: String, _ resto: [URL], _ deResto: [Artefacto], actividad: Date?,
                                  inactivo: Bool, conSalidas: Bool, perdidos: [String], enGit: [String], _ c: Contexto) -> Elemento {
        var motivos: [Motivo] = [.bien("arrow.triangle.2.circlepath", "Se regenera",
                                       "Tu código no se toca: solo se borran carpetas que se vuelven a generar.")]
        if let actividad {
            motivos.append(inactivo
                ? .bien("moon.zzz.fill", "Proyecto inactivo", "No cambias el código desde \(Formato.haceCuanto(actividad).lowercased()).")
                : .info("pencil", "Proyecto activo", "Cambiaste el código \(Formato.haceCuanto(actividad).lowercased())."))
        }
        // Lo último que cambió en estas carpetas (una compilación, un «npm install»): con el código viejo, un
        // proyecto recién compilado se está usando igual.
        let compilado = ultimoCambio(resto, c)
        let horasCompilado = compilado.map { Date().timeIntervalSince($0) / 3600 } ?? .infinity
        if horasCompilado < 1 {
            motivos.append(.aviso("hammer.fill", "Compilado hace poco",
                                  "Se compiló hace menos de una hora: quizá lo tengas abierto en el editor."))
        }
        var consecuencia = consecuenciaProyecto(deResto)
        if conSalidas {
            consecuencia += " También se borra lo que entregas (APK, AAB, dist…) y los informes y resultados de pruebas: se vuelven a crear al compilar o al pasar las pruebas."
        }
        avisosDeContenido(perdidos: perdidos, enGit: enGit, motivos: &motivos, consecuencia: &consecuencia)
        let relativas = resto.filter { $0.lastPathComponent != ".DS_Store" }
            .map { String($0.path.dropFirst(raiz.count + 1)) }.sorted()
        // Las dependencias sin archivo de bloqueo (package-lock.json, Podfile.lock…) podrían reinstalarse con otras versiones.
        let dependencias = deResto.filter { [.node, .pods, .terraform].contains($0.tipo) }
        let sinBloqueo = dependencias.filter { !Self.tieneBloqueo($0, raiz: raiz) }
        let enMaximo = horasCompilado >= 2 && (inactivo || sinBloqueo.isEmpty)
        if perdidos.isEmpty && enGit.isEmpty {
            if !inactivo && !sinBloqueo.isEmpty {
                motivos.append(.info("lock.open", "Sin archivo de bloqueo",
                    "\(Formato.listaCorta(sinBloqueo.map { String($0.ruta.dropFirst(raiz.count + 1)) })) no \(sinBloqueo.count == 1 ? "tiene" : "tienen") archivo de bloqueo (package-lock.json, yarn.lock, Podfile.lock…): al reinstalar podrían salir otras versiones, así que no lo marco ni con «Liberar al máximo»."))
            } else if horasCompilado < 2 {
                if horasCompilado >= 1 {
                    motivos.append(.info("clock.fill", "Compilado hoy",
                        "Lleva menos de 2 h sin compilar: no lo marco ni con «Liberar al máximo»."))
                }
            } else if !inactivo {
                motivos.append(.info("bolt.fill", "Solo en «Liberar al máximo»",
                    "Como estás trabajando en el proyecto, no lo marco solo. «Liberar al máximo» lo incluye porque lleva más de 2 h sin compilar: luego tendrás que volver a instalar las dependencias o compilar."))
            } else if horasCompilado < 24 {
                motivos.append(.info("bolt.fill", "Solo en «Liberar al máximo»",
                    "No cambias el código hace tiempo, pero se compiló o se instalaron sus dependencias \(Formato.haceCuanto(compilado).lowercased()): lo marco solo cuando pasen 24 h. «Liberar al máximo» ya lo incluye, porque lleva más de 2 h sin compilar."))
            }
        }
        let bytesDependencias = dependencias.reduce(Int64(0)) { $0 + c.indice.bytes(de: URL(fileURLWithPath: $1.ruta)) }
        return Elemento(
            nombre: nombre,
            detalle: "\(tipoDeProyecto(raiz)) · \(Formato.listaCorta(relativas, maximo: 4))",
            consecuencia: consecuencia,
            rutas: resto, tamanosRutas: tamanos(resto, c), ultimoUso: actividad, categoria: .proyectos,
            riesgo: !perdidos.isEmpty ? .cuidado : (enGit.isEmpty ? .seguro : .revisar),
            seleccionado: enMaximo && perdidos.isEmpty && enGit.isEmpty, motivos: motivos,
            // Un programa que trabaja en el proyecto (un servidor, una compilación, el editor de JetBrains con
            // el proyecto abierto) lo está usando, aunque no tenga nada abierto dentro de estas carpetas.
            enUso: .proyecto(nombre: nombre, raiz: raiz), dueno: nombre,
            nivel: inactivo && horasCompilado >= 24 ? .normal : .maximo,
            costes: [.recompilacion(proyecto: nombre)] + (dependencias.isEmpty ? [] : [.descarga(bytes: bytesDependencias)])
                + (conSalidas ? [.borraSalidas(proyecto: nombre)] : []),
            // Si algo cambia dentro después del análisis (una compilación, un «npm install»), no se toca.
            cambioAnalizado: compilado)
    }

    /// Las salidas de la compilación de un proyecto en el que trabajas (cambiaste el código en los últimos 30 días): lo que
    /// entregas (APK, AAB, dist…, los programas compilados) y los informes y resultados de pruebas. Se vuelven a crear al
    /// compilar o al pasar las pruebas, pero no son una caché: se enseñan y no se marcan nunca, ni con «Liberar al máximo».
    /// Cuando el proyecto lleve 30 días sin cambios, van con el resto del proyecto (`restoDelProyecto`).
    private func salidasDelProyecto(_ nombre: String, raiz: String, _ rutas: [URL], actividad: Date?, perdidos: [String],
                                    enGit: [String], _ c: Contexto) -> Elemento {
        var motivos: [Motivo] = []
        if let actividad {
            motivos.append(.info("pencil", "Proyecto activo", "Cambiaste el código \(Formato.haceCuanto(actividad).lowercased())."))
        }
        let compilado = ultimoCambio(rutas, c)
        if let compilado, Date().timeIntervalSince(compilado) < 3600 {
            motivos.append(.aviso("hammer.fill", "Compilado hace poco",
                                  "Se compiló hace menos de una hora: quizá lo tengas abierto en el editor."))
        }
        var consecuencia = "Tu código no se toca. Se borra lo que entregas (APK, AAB, dist…) y los informes y resultados de pruebas: se vuelven a crear al compilar o al pasar las pruebas, pero los informes de pruebas pasadas no vuelven."
        avisosDeContenido(perdidos: perdidos, enGit: enGit, motivos: &motivos, consecuencia: &consecuencia)
        // La razón de no marcarlo va al final (es la que se enseña en «Se queda fuera por ahora»).
        motivos.append(.info("shippingbox.fill", "Lo que entregas e informes",
            "Son las salidas de la compilación (APK, AAB, dist…) y los informes y resultados de pruebas. Como estás trabajando en el proyecto, no las marco, ni con «Liberar al máximo»: bórralas tú si ya no las necesitas."))
        let relativas = rutas.filter { $0.lastPathComponent != ".DS_Store" }
            .map { String($0.path.dropFirst(raiz.count + 1)) }.sorted()
        return Elemento(
            nombre: "Salidas de compilación de \(nombre)",
            detalle: "\(tipoDeProyecto(raiz)) · \(Formato.listaCorta(relativas, maximo: 4))",
            consecuencia: consecuencia,
            rutas: rutas, tamanosRutas: tamanos(rutas, c), ultimoUso: actividad, categoria: .proyectos,
            riesgo: !perdidos.isEmpty ? .cuidado : (enGit.isEmpty ? .seguro : .revisar),
            seleccionado: false, motivos: motivos, enUso: .proyecto(nombre: nombre, raiz: raiz), dueno: nombre,
            nivel: .nunca, costes: [.recompilacion(proyecto: nombre), .borraSalidas(proyecto: nombre)],
            cambioAnalizado: compilado)
    }

    /// Las salidas de una compilación: lo que entregas (APK, AAB, dist…, los programas compilados de target/ y bin/) y los
    /// informes, la cobertura y los resultados de pruebas. Lo demás que queda de un proyecto (dependencias como
    /// node_modules y Pods, y cachés como .gradle, .expo o .nx) se regenera solo.
    private static func esSalida(_ a: Artefacto) -> Bool {
        let nombre = Rutas.nombre(a.ruta)
        switch a.tipo {
        // Las dependencias de Elixir (deps) y de Elm (elm-stuff) y la caché de Zig van como .compilacion.
        case .compilacion: return !["deps", "elm-stuff", "zig-cache", ".zig-cache"].contains(nombre)
        case .cargo, .pruebas: return true
        case .dotnet: return nombre == "bin"
        case .web: return [".output", "storybook-static", ".vercel"].contains(nombre)
        default: return false
        }
    }

    /// Las rutas sin las que hay que quitar (los emuladores de prueba, que se ofrecen aparte): una ruta que contiene
    /// alguna se sustituye por lo demás que tiene dentro.
    private static func sin(_ quitar: [String], en urls: [URL]) -> [URL] {
        guard !quitar.isEmpty else { return urls }
        return urls.flatMap { u -> [URL] in
            let p = u.path
            if quitar.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return [] }
            let dentro = Set(quitar.filter { $0.hasPrefix(p + "/") })
            return dentro.isEmpty ? [u] : resto(de: p, sin: dentro)
        }
    }

    /// Notas informativas por repositorio (su carpeta): que hay otra copia del mismo origin y que Codex guarda en él
    /// puntos de restauración. Se leen los archivos de .git, sin ejecutar git. Nada de esto se ofrece para borrar.
    private func notasDeRepositorios(_ c: Contexto) -> [String: [Motivo]] {
        // Solo repositorios con su propia carpeta .git (los worktrees y submódulos comparten la de otro), y no los de
        // las carpetas de trabajo de los agentes (pruebas que se crean y se tiran).
        let repos = c.indice.repos.filter { Rutas.esCarpeta(URL(fileURLWithPath: $0 + "/.git")) && !Self.enSesion($0, c) }.sorted()
        var notas: [String: [Motivo]] = [:]

        var porOrigen: [String: [String]] = [:]
        for repo in repos {
            if let origen = Self.origen(de: repo) { porOrigen[origen, default: []].append(repo) }
        }
        for (origen, mismos) in porOrigen where mismos.count > 1 {
            for repo in mismos {
                let otras = mismos.filter { $0 != repo }.map { Formato.rutaCorta($0) }
                notas[repo, default: []].append(.info("square.on.square", "Otra copia del repositorio",
                    "\(otras.count == 1 ? "En \(otras[0]) hay otra copia" : "En \(Formato.listaCorta(otras)) hay otras copias") del mismo repositorio (\(origen)). Si una sobra, lo que liberas es la carpeta entera; antes comprueba con «git status» y «git log» que no tenga cambios sin subir."))
            }
        }

        for repo in repos {
            let n = Self.checkpointsDeCodex(repo)
            guard n > 0 else { continue }
            let git = tamanos([URL(fileURLWithPath: repo + "/.git")], c)[0]
            let sinCommits = !Self.tieneRamas(repo)
            notas[repo, default: []].append(.info("arrow.uturn.backward.circle", "Puntos de restauración de Codex",
                "Codex guarda \(n == 1 ? "un punto de restauración" : "\(n) puntos de restauración") en el git de este proyecto (refs/codex/…) para poder deshacer sus cambios. Mantienen vivo historial que tus ramas no usan: el .git ocupa \(Formato.bytes(git))\(sinCommits ? " y, como tus ramas no tienen ningún commit, casi todo es de ellos" : ""). No los toco: si ya no los necesitas, se quitan desde Codex o con git, pero entonces ya no podrás deshacer esos turnos."))
        }
        return notas
    }

    /// ¿Está dentro de la carpeta de trabajo de una sesión de un agente (`Rutas.sesionesDeAgentes`)?
    private static func enSesion(_ ruta: String, _ c: Contexto) -> Bool {
        c.indice.sesionesDeAgentes.contains { ruta == $0 || ruta.hasPrefix($0 + "/") }
    }

    /// La URL del remoto «origin» de un repositorio, leída de .git/config y normalizada para comparar
    /// («git@github.com:a/b.git» y «https://github.com/a/b» son el mismo: «github.com/a/b»).
    private static func origen(de repo: String) -> String? {
        guard let config = try? String(contentsOfFile: repo + "/.git/config", encoding: .utf8) else { return nil }
        var enOrigin = false
        for linea in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if linea.hasPrefix("[") { enOrigin = linea.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"; continue }
            guard enOrigin, linea.hasPrefix("url") else { continue }
            let partes = linea.split(separator: "=", maxSplits: 1)
            guard partes.count == 2 else { continue }
            var url = partes[1].trimmingCharacters(in: .whitespaces).lowercased()
            for prefijo in ["https://", "http://", "ssh://", "git://", "git+ssh://"] where url.hasPrefix(prefijo) { url = String(url.dropFirst(prefijo.count)) }
            if let arroba = url.firstIndex(of: "@"), url[..<arroba].allSatisfy({ $0 != "/" }) { url = String(url[url.index(after: arroba)...]) }
            // «github.com:a/b» (scp) → «github.com/a/b»; un puerto («host:22/a») se queda.
            if let dos = url.firstIndex(of: ":"), !url[url.index(after: dos)...].prefix(while: { $0 != "/" }).allSatisfy(\.isNumber) {
                url.replaceSubrange(dos...dos, with: "/")
            }
            while url.hasSuffix("/") { url.removeLast() }
            if url.hasSuffix(".git") { url.removeLast(4) }
            return url.isEmpty ? nil : url
        }
        return nil
    }

    /// Cuántos puntos de restauración de Codex (refs/codex/…) tiene un repositorio: sueltos en .git/refs/codex o en
    /// .git/packed-refs.
    private static func checkpointsDeCodex(_ repo: String) -> Int {
        var n = 0
        if let e = FileManager.default.enumerator(atPath: repo + "/.git/refs/codex") {
            for case let rel as String in e where !Rutas.esCarpeta(URL(fileURLWithPath: repo + "/.git/refs/codex/" + rel)) { n += 1 }
        }
        if let empaquetadas = try? String(contentsOfFile: repo + "/.git/packed-refs", encoding: .utf8) {
            n += empaquetadas.split(separator: "\n").filter { $0.contains(" refs/codex/") }.count
        }
        return n
    }

    /// ¿Tiene alguna rama con commits? (.git/refs/heads o packed-refs.)
    private static func tieneRamas(_ repo: String) -> Bool {
        if let e = FileManager.default.enumerator(atPath: repo + "/.git/refs/heads") {
            for case let rel as String in e where !Rutas.esCarpeta(URL(fileURLWithPath: repo + "/.git/refs/heads/" + rel)) { return true }
        }
        let empaquetadas = (try? String(contentsOfFile: repo + "/.git/packed-refs", encoding: .utf8)) ?? ""
        return empaquetadas.split(separator: "\n").contains { $0.contains(" refs/heads/") }
    }

    /// Repositorios git con el historial sin empaquetar. Git suele empaquetarlo solo, pero con pocos archivos grandes
    /// (imágenes, modelos 3D…) nunca llega al mínimo y se queda así para siempre. Se ofrece desde 50 MB sueltos y queda
    /// para «Liberar al máximo» (en el modo normal no se marca: cuánto libera depende de lo que haya dentro y gasta un
    /// rato de procesador), solo si:
    /// - su historial no comparte espacio con otra copia (clones de APFS o enlaces duros, de una copia hecha con el Finder
    ///   o un «git clone» local): git escribiría un paquete nuevo, lo compartido no se liberaría y el disco perdería espacio;
    /// - se espera que libere algo (`HistorialGit.Objetos.estimado`, sin contar la basura de git, «size-garbage», que
    ///   git gc no borra sin podar).
    /// Si no hay sitio para escribir el paquete nuevo, se avisa (y Limpiador no empieza). Si git falla, Limpiador borra el
    /// paquete a medias que deja.
    private func historialesSinCompactar(_ c: Contexto, notas: [String: [Motivo]]) -> [Elemento] {
        var r: [Elemento] = []
        // Los worktrees y submódulos (con un archivo .git) comparten el historial de otro repositorio: se cuenta solo ese.
        // Los de las carpetas de trabajo de los agentes, tampoco: se pueden estar usando y solo se ofrecen para revisar.
        let repos = c.indice.repos.filter { Rutas.esCarpeta(URL(fileURLWithPath: $0 + "/.git")) && !Self.enSesion($0, c) }.sorted()
        let cuentas = Self.enParalelo(repos) { HistorialGit.cuenta($0) }
        let candidatos = zip(repos, cuentas).filter { ($0.1["size"] ?? 0) * 1024 >= 50_000_000 }
        let objetos = Self.enParalelo(candidatos.map(\.0)) { HistorialGit.analizar(repo: $0) }
        let libre = InfoDisco.libreAhora()
        for ((repo, datos), o) in zip(candidatos, objetos) {
            let sueltos = (datos["size"] ?? 0) * 1024
            // Que no comparta su historial con otra copia: lo suyo tiene que ser casi todo lo que ocupa.
            guard let o, o.privado * 10 >= o.asignado * 9 else { continue }
            let estimado = o.estimado
            guard estimado >= minimo else { continue }
            let nombre = Rutas.nombre(repo)
            var motivos: [Motivo] = [.bien("archivebox.fill", "Solo se comprime",
                                           "Tu código, tus commits, tus ramas y el reflog se quedan igual: solo cambia cómo los guarda git.")]
            // Git escribe el paquete nuevo entero antes de borrar lo suelto.
            let necesario = sueltos + (datos["size-pack"] ?? 0) * 1024 + 1_000_000_000
            if libre < necesario {
                motivos.append(.aviso("externaldrive.badge.exclamationmark", "Falta espacio",
                    "Para compactarlo, git necesita unos \(Formato.bytes(necesario)) libres (escribe el historial empaquetado antes de borrar el suelto) y ahora hay \(Formato.bytes(libre)). Si sigue así al limpiar, no lo empezaré."))
            }
            if o.binario > o.texto {
                motivos.append(.info("photo.on.rectangle", "Ya viene comprimido",
                    "Casi todo lo suelto (\(Formato.bytes(o.binario))) son archivos que ya vienen comprimidos (fotos, vídeos, instaladores…): empaquetarlos casi no ahorra, salvo entre versiones parecidas de un mismo archivo."))
            }
            r.append(Elemento(
                nombre: "Compactar el historial de \(nombre)",
                detalle: "El historial de git de \(nombre) tiene \(Formato.bytes(sueltos)) en \(Formato.numero(Int(datos["count"] ?? 0))) objetos sin empaquetar.",
                consecuencia: "Git empaqueta el historial (es «git gc», pero sin podar nada): no se borra ninguna rama, ningún commit "
                    + "ni el historial de cambios (reflog). Calculo que libera unos \(Formato.bytes(estimado)): lo que más gana son los "
                    + "archivos de texto con varias versiones; las fotos, los vídeos y los instaladores ya vienen comprimidos. Gasta "
                    + "un rato de procesador (lo detengo a los 30 minutos) y necesita sitio para escribir el paquete nuevo antes de borrar lo suelto.",
                rutas: [URL(fileURLWithPath: repo + "/.git")], tamanoFijo: estimado, categoria: .proyectos, riesgo: .seguro,
                seleccionado: true, accion: .compactarGit(repo: repo),
                motivos: motivos + (notas[repo] ?? []), dueno: nombre, nivel: .maximo, costes: [.tiempoCPU]))
        }
        return r
    }

    /// La carpeta del proyecto: el repositorio git que contiene el artefacto o, si no hay, la raíz de Gradle.
    private func raizDeProyecto(_ artefacto: String, _ c: Contexto) -> String {
        let home = Rutas.home.path
        var actual = Rutas.padre(artefacto)
        var candidata = actual
        while actual.count > home.count, Rutas.padre(actual) != home {
            if c.indice.repos.contains(actual) { return actual }
            if Rutas.existe(actual + "/settings.gradle") || Rutas.existe(actual + "/settings.gradle.kts") { candidata = actual }
            actual = Rutas.padre(actual)
        }
        // ~/MiProyecto: el bucle se para justo antes de mirarlo.
        if Rutas.padre(actual) == home, c.indice.repos.contains(actual) { return actual }
        return candidata
    }

    /// Dentro del build/ de un módulo de Gradle, lo que la compilación vuelve a crear desde el código. No están las
    /// salidas (outputs: APK, AAB), los informes (reports), los resultados de pruebas ni la cobertura.
    private static let intermediosGradle: Set<String> = ["intermediates", "tmp", "kotlin", "kspCaches", "generated", "classes",
                                                         "kotlinToolingMetadata", ".transforms"]
    /// Carpetas de compilación que son intermedias enteras: cachés de las webs, SwiftPM, el DerivedData de un proyecto,
    /// Flutter y las carpetas de Kotlin y del NDK en la raíz de Gradle.
    private static let intermediosEnteros: Set<String> = [".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular",
                                                          ".vite", ".build", "DerivedData", ".dart_tool", ".kotlin", ".cxx"]
    /// Dentro de build/, carpetas que nunca son la de un módulo, aunque alguien guarde ahí un «intermediates».
    private static let salidasDeCompilacion: Set<String> = ["outputs", "reports", "test-results", "kover", "jacoco", "lint",
                                                            "distributions", "libs"]

    /// Lo intermedio de una carpeta de compilación: la carpeta entera, algunas carpetas de dentro o nada.
    private static func intermedios(de a: Artefacto) -> [URL] {
        let nombre = Rutas.nombre(a.ruta)
        let carpeta = URL(fileURLWithPath: a.ruta)
        if intermediosEnteros.contains(nombre) { return [carpeta] }
        let padre = Rutas.padre(a.ruta)
        func hay(_ n: String) -> Bool { Rutas.existe(padre + "/" + n) }
        func subcarpetas(_ u: URL, _ nombres: Set<String>) -> [URL] {
            Rutas.hijos(u).filter { nombres.contains($0.lastPathComponent) && Rutas.esCarpeta($0) }
        }
        switch (a.tipo, nombre) {
        case (.compilacion, "build"):
            let gradle = hay("build.gradle") || hay("build.gradle.kts") || hay("settings.gradle") || hay("settings.gradle.kts")
            guard gradle || hay("pubspec.yaml") else { return [] }
            var r: [URL] = []
            for h in Rutas.hijos(carpeta) where Rutas.esCarpeta(h) {
                if gradle && intermediosGradle.contains(h.lastPathComponent) {
                    r.append(h)
                } else if !salidasDeCompilacion.contains(h.lastPathComponent) && Rutas.esCarpeta(h.appendingPathComponent("intermediates")) {
                    // build/<módulo>/intermediates: un módulo que compila dentro del build/ raíz (Flutter y sus plugins,
                    // o un buildDir propio). Su outputs/ se queda.
                    r += subcarpetas(h, intermediosGradle)
                }
            }
            return r
        case (.gradle, ".gradle"):
            // .gradle/8.13 (historial de ejecución, huellas) y buildOutputCleanup; la configuración del proyecto se queda.
            return Rutas.hijos(carpeta).filter { u in
                Rutas.esCarpeta(u) && (u.lastPathComponent.first?.isNumber == true || u.lastPathComponent == "buildOutputCleanup")
            }
        case (.cargo, "target") where hay("Cargo.toml"):
            // target/debug/{build,deps,incremental,.fingerprint}: los programas compilados (target/debug/<programa>) se quedan.
            return Rutas.hijos(carpeta).filter { Rutas.esCarpeta($0) }
                .flatMap { subcarpetas($0, ["build", "deps", "incremental", ".fingerprint"]) }
        default:
            return []
        }
    }

    /// Las dependencias de un proyecto tienen archivo de bloqueo (las versiones exactas que se instalaron) en su carpeta
    /// o, para node_modules, en alguna de las de encima hasta la raíz del proyecto (los «workspaces» lo guardan en la raíz):
    /// sin él, reinstalarlas podría traer otras versiones.
    private static func tieneBloqueo(_ a: Artefacto, raiz: String) -> Bool {
        let bloqueos: [String]
        switch a.tipo {
        case .node: bloqueos = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]
        case .pods: bloqueos = ["Podfile.lock"]
        case .terraform: bloqueos = [".terraform.lock.hcl"]
        default: return true
        }
        var carpeta = Rutas.padre(a.ruta)
        while true {
            if bloqueos.contains(where: { Rutas.existe(carpeta + "/" + $0) }) { return true }
            guard a.tipo == .node, carpeta.count > raiz.count, carpeta.hasPrefix(raiz) else { return false }
            carpeta = Rutas.padre(carpeta)
        }
    }

    /// Lo que queda de una carpeta sin las rutas `quitar` (que están dentro): sus hijos que no son ni contienen
    /// ninguna, bajando por los que sí las contienen.
    private static func resto(de carpeta: String, sin quitar: Set<String>) -> [URL] {
        var r: [URL] = []
        for h in Rutas.hijos(URL(fileURLWithPath: carpeta)) where !quitar.contains(h.path) {
            if quitar.contains(where: { $0.hasPrefix(h.path + "/") }) {
                r += resto(de: h.path, sin: quitar)
            } else {
                r.append(h)
            }
        }
        return r
    }

    /// Las rutas de `lista` que son una de esas o están dentro de alguna.
    private static func dentro(_ lista: [String], _ urls: [URL]) -> [String] {
        let bases = urls.map(\.path)
        return lista.filter { p in bases.contains { p == $0 || p.hasPrefix($0 + "/") } }
    }

    /// «Intermedios de compilación de <proyecto>»: Seguro, y marcado si nada cambió dentro en 24 h y no hay dentro nada
    /// que la compilación no cree ni nada guardado en git. Si alguien trabaja en el proyecto (un programa dentro, un
    /// archivo abierto o el proyecto abierto en Android Studio), el Evaluador lo desmarca (`.proyecto`).
    private func intermediosDeCompilacion(_ nombre: String, raiz: String, _ rutas: [URL], perdidos: [String], enGit: [String],
                                          _ c: Contexto) -> Elemento {
        let cambio = ultimoCambio(rutas, c)
        let horas = cambio.map { Date().timeIntervalSince($0) / 3600 } ?? .infinity
        let cuando = Formato.haceCuanto(cambio).lowercased()
        // SwiftPM y Xcode guardan ahí también las dependencias descargadas. SwiftPM crea .build/checkouts aunque el paquete
        // no tenga ninguna: solo cuenta si hay algo dentro.
        func conAlgo(_ u: URL) -> Bool { Rutas.hijos(u).contains { !$0.lastPathComponent.hasPrefix(".") } }
        let descargas = rutas.contains { u in
            conAlgo(u.appendingPathComponent("checkouts")) || conAlgo(u.appendingPathComponent("artifacts"))
                || conAlgo(u.appendingPathComponent("SourcePackages/checkouts")) || conAlgo(u.appendingPathComponent("SourcePackages/artifacts"))
        }
        var motivos: [Motivo] = [.bien("arrow.triangle.2.circlepath", "Se regenera",
            "Son archivos intermedios que la compilación vuelve a crear desde tu código: clases compiladas, recursos procesados y cachés. Lo que entregas (APK, AAB, dist…) y los informes no están aquí.")]
        if horas < 1 {
            motivos.append(.aviso("hammer.fill", "Compilado hace poco", "Se compiló hace menos de una hora: quizá lo tengas abierto en el editor."))
        } else if horas < 24 && !descargas {
            motivos.append(.info("clock.fill", "Compilado hoy",
                "Lo último cambió \(cuando): lo marco solo cuando pasen 24 h sin compilar, para no estorbarte si sigues trabajando en él"
                + (horas >= 2 ? ". «Liberar al máximo» ya lo incluye, porque lleva más de 2 h sin compilar." : ".")))
        } else if horas < 2 {
            motivos.append(.info("clock.fill", "Compilado hoy", "Lo último cambió \(cuando): no lo marco ni con «Liberar al máximo» hasta que pasen 2 h sin compilar."))
        } else if cambio != nil {
            motivos.append(.bien("moon.zzz.fill", "Sin compilar desde \(cuando)", "Nada cambió dentro desde \(cuando): no se está compilando."))
        }
        var consecuencia = "Tu código, lo que entregas (APK, AAB, dist…) y los informes no se tocan; la próxima compilación se hace desde cero (más lenta)."
        if descargas {
            consecuencia += " Swift vuelve a descargar las dependencias del paquete (necesita internet)."
            motivos.append(.info("arrow.down.circle.fill", "Se vuelve a descargar",
                "Dentro están también las dependencias que descargó Swift: volver a compilar necesita internet, así que no lo marco solo, solo con «Liberar al máximo»."))
        }
        if rutas.contains(where: { $0.lastPathComponent == ".dart_tool" }) {
            consecuencia += " Flutter vuelve a preparar los paquetes al compilar («flutter pub get»)."
        }
        if rutas.contains(where: { [".next", ".nuxt", ".svelte-kit", ".angular"].contains($0.lastPathComponent) }) {
            consecuencia += " Si sirves la web desde esta carpeta, compílala otra vez («npm run build») antes de arrancarla."
        }
        avisosDeContenido(perdidos: perdidos, enGit: enGit, motivos: &motivos, consecuencia: &consecuencia)
        let relativas = rutas.map { String($0.path.dropFirst(raiz.count + 1)) }.sorted()
        return Elemento(
            nombre: "Intermedios de compilación de \(nombre)",
            detalle: "\(tipoDeProyecto(raiz)) · \(Formato.listaCorta(relativas, maximo: 4))",
            consecuencia: consecuencia,
            rutas: rutas, tamanosRutas: tamanos(rutas, c), ultimoUso: cambio, categoria: .proyectos,
            riesgo: !perdidos.isEmpty ? .cuidado : (enGit.isEmpty ? .seguro : .revisar),
            // Con 24 h sin compilar, en el modo normal; con 2 h, solo en «Liberar al máximo». Si volver a compilar necesita
            // internet (dependencias de Swift dentro), solo en «Liberar al máximo».
            seleccionado: horas >= 2 && perdidos.isEmpty && enGit.isEmpty,
            motivos: motivos, enUso: .proyecto(nombre: nombre, raiz: raiz), dueno: nombre,
            nivel: (horas >= 2 && horas < 24) || descargas ? .maximo : .normal,
            costes: [.recompilacion(proyecto: nombre)] + (descargas ? [.descarga(bytes: 0)] : []),
            cambioAnalizado: cambio)
    }

    /// Avisa de lo que hay dentro de unas carpetas de compilación y no se regenera (`perdidos`) o está guardado en git.
    private func avisosDeContenido(perdidos: [String], enGit: [String], motivos: inout [Motivo], consecuencia: inout String) {
        if !perdidos.isEmpty {
            let uno = perdidos.count == 1
            let nombres = Formato.listaCorta(perdidos.map { Rutas.nombre($0) })
            let donde = Set(perdidos.map { Formato.rutaCorta(Rutas.padre($0)) }).sorted()
            motivos.insert(.peligro("exclamationmark.triangle.fill", "No todo se regenera",
                "Dentro hay \(perdidos.count) \(uno ? "archivo" : "archivos") que la compilación no crea (bases de datos, modelos, trazas, emuladores de prueba, documentos, llaves o material que guardaste en build/reports): \(nombres). \(uno ? "Está" : "Están") en \(Formato.listaCorta(donde)). \(uno ? "Sácalo" : "Sácalos") de ahí antes de limpiar."), at: 0)
            consecuencia += " Ojo: también se \(uno ? "borra" : "borran") \(nombres), que no se \(uno ? "puede" : "pueden") volver a generar."
        }
        if !enGit.isEmpty {
            let uno = enGit.count == 1
            motivos.insert(.aviso("arrow.triangle.branch", "Guardado en git",
                "Dentro hay \(enGit.count) \(uno ? "archivo guardado" : "archivos guardados") en git: \(Formato.listaCorta(enGit.map { Rutas.nombre($0) })). Si lo borras, git \(uno ? "lo dará" : "los dará") por \(uno ? "eliminado" : "eliminados"): se \(uno ? "recupera" : "recuperan") con «git restore», pero pierdes los cambios que no estén en un commit."),
                           at: perdidos.isEmpty ? 0 : 1)
            consecuencia += " Además se \(uno ? "borra un archivo guardado" : "borran \(enGit.count) archivos guardados") en git (se \(uno ? "recupera" : "recuperan") con «git restore»)."
        }
    }

    /// Hace `trabajo` con cada elemento a la vez (para no esperar a git uno por uno).
    private static func enParalelo<T, R>(_ lista: [T], _ trabajo: (T) -> R) -> [R] {
        var resultados = [R?](repeating: nil, count: lista.count)
        let candado = NSLock()
        DispatchQueue.concurrentPerform(iterations: lista.count) { i in
            let v = trabajo(lista[i])
            candado.lock()
            resultados[i] = v
            candado.unlock()
        }
        return resultados.map { $0! }
    }

    /// Los archivos guardados en git que hay dentro de esas carpetas (rutas completas).
    private static func versionados(en carpetas: [String], repo: String) -> [String] {
        let relativas = carpetas.filter { $0.hasPrefix(repo + "/") }.map { String($0.dropFirst(repo.count + 1)) }
        guard !relativas.isEmpty else { return [] }
        // dist/.gitignore o .gitkeep solo sirven para que la carpeta exista en el repositorio.
        let relleno: Set<String> = [".gitignore", ".gitkeep", ".keep", ".gitattributes", ".npmignore"]
        return Shell.ejecutar("/usr/bin/git", ["-C", repo, "ls-files", "-z", "--"] + relativas, limite: 20).salida
            .split(separator: "\0").map { repo + "/" + $0 }.filter { !relleno.contains(Rutas.nombre($0)) }
    }

    /// De los archivos de dentro de las carpetas de compilación, los que son copia de uno del proyecto (mismo nombre y
    /// tamaño fuera de esas carpetas): Vite copia public/ en dist/, Flutter y Android copian sus assets, Next.js su .env…
    private static func copiasDelProyecto(_ candidatos: [String], raiz: String, artefactos: Set<String>) -> Set<String> {
        guard !candidatos.isEmpty else { return [] }
        func tamano(_ ruta: String) -> Int64? {
            var st = stat()
            return lstat(ruta, &st) == 0 ? Int64(st.st_size) : nil
        }
        let buscados = Set(candidatos.map { Rutas.nombre($0) })
        var encontrados: [String: Set<Int64>] = [:]
        autoreleasepool {
            guard let recorrido = FileManager.default.enumerator(at: URL(fileURLWithPath: raiz), includingPropertiesForKeys: nil,
                                                                options: [.skipsPackageDescendants]) else { return }
            var vistos = 0
            for case let u as URL in recorrido {
                vistos += 1
                // En un proyecto enorme, lo que no se llegó a comparar sigue contando como no regenerable.
                if vistos > 100_000 { break }
                let n = u.lastPathComponent
                if n == ".git" || n == "node_modules" || artefactos.contains(u.path) { recorrido.skipDescendants(); continue }
                if buscados.contains(n), let t = tamano(u.path) { encontrados[n, default: []].insert(t) }
            }
        }
        return Set(candidatos.filter { c in tamano(c).map { encontrados[Rutas.nombre(c)]?.contains($0) == true } ?? false })
    }

    private func ultimoCommit(_ repo: String) -> Date? {
        let s = Shell.ejecutar("/usr/bin/git", ["-C", repo, "log", "-1", "--format=%ct"], limite: 5).salida
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(s).map { Date(timeIntervalSince1970: $0) }
    }

    private func tipoDeProyecto(_ raiz: String) -> String {
        func hay(_ a: String) -> Bool { Rutas.existe(raiz + "/" + a) }
        func hayExtension(_ ext: String) -> Bool {
            ((try? FileManager.default.contentsOfDirectory(atPath: raiz)) ?? []).contains { $0.hasSuffix("." + ext) }
        }
        if hay("Assets") && hay("ProjectSettings") { return "Unity" }
        if hayExtension("sln") || hayExtension("csproj") { return ".NET" }
        if hayExtension("tf") { return "Terraform" }
        if hay("pubspec.yaml") { return "Flutter" }
        if hay("settings.gradle") || hay("settings.gradle.kts") || hay("build.gradle") || hay("build.gradle.kts") { return "Android" }
        if hay("app.json") && hay("package.json") { return "React Native / Expo" }
        if hay("Podfile") || hay("Package.swift") { return "iOS / Swift" }
        if hay("package.json") { return "Node.js" }
        if hay("Cargo.toml") { return "Rust" }
        if hay("pyproject.toml") || hay("requirements.txt") { return "Python" }
        return "Proyecto"
    }

    private func consecuenciaProyecto(_ a: [Artefacto]) -> String {
        var partes: [String] = []
        if a.contains(where: { $0.tipo == .node }) { partes.append("tendrás que ejecutar «npm install» antes de volver a usarlo") }
        if a.contains(where: { [.compilacion, .gradle, .cxx, .kotlin, .dotnet].contains($0.tipo) }) {
            partes.append("la próxima compilación tardará más porque se hace desde cero")
        }
        if a.contains(where: { $0.tipo == .pods }) { partes.append("tendrás que ejecutar «pod install»") }
        if a.contains(where: { $0.tipo == .unity }) { partes.append("Unity volverá a importar los recursos al abrir el proyecto (puede tardar)") }
        if a.contains(where: { $0.tipo == .terraform }) { partes.append("tendrás que ejecutar «terraform init»") }
        if partes.isEmpty { partes.append("se vuelve a generar la próxima vez que lo compiles") }
        return "Tu código no se toca; " + Formato.lista(partes) + "."
    }

    // MARK: - Carpetas ocultas de herramientas

    private static let ocultasConocidas: Set<String> = [
        ".Trash", ".ssh", ".gnupg", ".config", ".local", ".cache", ".npm", ".gradle", ".android", ".m2",
        ".cargo", ".rustup", ".nvm", ".vscode", ".zsh_sessions", ".docker", ".kube", ".aws", ".azure",
        ".oh-my-zsh", ".claude", ".git", ".cups", ".bun", ".pyenv", ".rbenv", ".sdkman", ".swiftpm",
        ".expo", ".cocoapods", ".yarn", ".pub-cache", ".nuget", ".ollama", ".CFUserTextEncoding", ".DS_Store",
        ".node-gyp", ".electron-gyp", ".cmake-js",
    ]

    private enum ClaseSubcarpeta { case temporal, registros, reinstalable, personal }

    /// Carpetas y archivos que delatan datos guardados (sesiones, historial, bases de datos) dentro de una carpeta
    /// que por su nombre parece temporal. Devuelve una descripción breve de lo que encontró, o nil si no hay nada.
    /// Si no puede revisarla entera también devuelve algo: no saber no es lo mismo que «no hay nada».
    private static func datosDentro(_ carpeta: URL, esRegistro: Bool, _ c: Contexto) -> String? {
        // El índice cuenta las bases de datos a cualquier profundidad.
        let bases = c.indice.contenido(de: [carpeta]).bases
        if bases > 0 { return bases == 1 ? "una base de datos" : "\(bases) bases de datos" }
        // Nombres exactos: «computer-history» puede ser el nombre de un plugin, no un historial.
        let nombresDeDatos: Set<String> = ["sessions", "history", "conversations", "chats", "threads", "memories", "memory",
                                           "projects", "workspaces", "archived_sessions", "backups", "backup",
                                           "chat_history", "chat-history", "histories", "checkpoints"]
        // En una carpeta de registros, los .jsonl son registros; en una temporal suelen ser conversaciones.
        let extensionesDeDatos: Set<String> = esRegistro ? ["sqlite", "sqlite3", "db", "realm"]
                                                         : ["sqlite", "sqlite3", "db", "realm", "jsonl"]
        // checkpoint-tesis.json (Gemini CLI), session-….json… (en .md suelen ser documentación de plugins)
        let prefijosDeDatos = ["checkpoint", "session", "chat", "conversation"]
        // Las URL del recorrido se liberan al terminar, no al final de todo el análisis.
        return autoreleasepool { () -> String? in
            guard let recorrido = FileManager.default.enumerator(at: carpeta, includingPropertiesForKeys: [.isDirectoryKey],
                                                                options: [.skipsPackageDescendants]) else { return nil }
            var vistos = 0
            for case let u as URL in recorrido {
                vistos += 1
                if vistos > 20_000 { return "más de 20.000 archivos que no revisé uno a uno" }
                let nombre = u.lastPathComponent.lowercased()
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if nombresDeDatos.contains(nombre) { return "la carpeta «\(u.lastPathComponent)»" }
                } else {
                    let ext = u.pathExtension.lowercased()
                    let base = (nombre as NSString).deletingPathExtension
                    if extensionesDeDatos.contains(ext)
                        || (["json", "jsonl"].contains(ext) && prefijosDeDatos.contains { base.hasPrefix($0) })
                        || (ext.isEmpty && nombre.hasSuffix("history")) {   // shell_history, .history…
                        return "«\(u.lastPathComponent)»"
                    }
                }
            }
            return nil
        }
    }

    /// Los archivos de configuración de la raíz de la carpeta de una herramienta (config.toml, settings.json…), si son
    /// pequeños (256 KB o menos): nombre y texto.
    private static func configuracion(de carpeta: URL) -> [(nombre: String, texto: String)] {
        ["config.toml", "config.json", "settings.json", "config.yaml", "config.yml"].compactMap { nombre in
            let ruta = carpeta.appendingPathComponent(nombre).path
            var st = stat()
            guard lstat(ruta, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 262_144,
                  let texto = try? String(contentsOfFile: ruta, encoding: .utf8) else { return nil }
            return (nombre, texto)
        }
    }

    /// El archivo de configuración que nombra la subcarpeta `sub` de la carpeta `carpeta` (relativa a tu carpeta personal,
    /// como «.codex» o «.local/share/x»): con su ruta completa, con «~/» o «$HOME/» (todas acaban en «.codex/.tmp»), o
    /// relativa («./.tmp», «".tmp/…"»). nil si ninguno la nombra.
    private static func nombra(_ configuracion: [(nombre: String, texto: String)], carpeta: String, sub: String) -> String? {
        // Que siga otra letra quiere decir que es otro nombre («.tmp» no es «.tmpx»); antes de «.codex» tiene que haber «/».
        func parteDeNombre(_ c: Character) -> Bool { c.isLetter || c.isNumber || "-_.".contains(c) }
        func aparece(_ aguja: String, en texto: String, antes: ((Character) -> Bool)? = nil) -> Bool {
            var desde = texto.startIndex
            while let r = texto.range(of: aguja, range: desde..<texto.endIndex) {
                desde = r.upperBound
                if let antes, r.lowerBound > texto.startIndex, !antes(texto[texto.index(before: r.lowerBound)]) { continue }
                if r.upperBound == texto.endIndex || !parteDeNombre(texto[r.upperBound]) { return true }
            }
            return false
        }
        for (nombre, texto) in configuracion {
            if aparece(carpeta + "/" + sub, en: texto, antes: { $0 == "/" }) { return nombre }
            // Relativa a la carpeta de la herramienta: «./.tmp» (no «../.tmp»), o entre comillas seguida de «/». Un nombre
            // sin punto delante («cache») entre comillas sin más suele ser una clave («"cache": true»), no una ruta.
            if aparece("./" + sub, en: texto, antes: { $0 != "." }) { return nombre }
            for comilla in ["\"", "'"] {
                if texto.contains(comilla + sub + "/") { return nombre }
                if sub.hasPrefix(".") && texto.contains(comilla + sub + comilla) { return nombre }
            }
        }
        return nil
    }

    private func clasificarSubcarpeta(_ nombre: String) -> ClaseSubcarpeta? {
        let n = nombre.lowercased()
        if ["cache", "caches", ".cache", "tmp", ".tmp", "temp", "crashpad", "crash-reports", "crashes"].contains(n) { return .temporal }
        // Primero las bases de datos: «logs_2.sqlite» es una base de datos, no una carpeta de registros.
        if ["sessions", "history", "conversations", "chats", "threads", "memories", "memory", "projects",
            "workspaces", "archived_sessions"].contains(n) || n.contains("history")
            || [".sqlite", ".sqlite3", ".db", ".realm"].contains(where: { n.hasSuffix($0) }) {
            return .personal
        }
        // «logs», «log», «logs-2024»… pero no «login» ni «logo».
        if n == "logs" || n == "log" || n.hasPrefix("logs-") || n.hasPrefix("logs_") || n.hasSuffix(".log") { return .registros }
        if ["node_modules", "packages", "runtimes", "versions", "bin", "lib", "plugins", "extensions", "downloads",
            "models", "vendor", "tools", "sdk", "toolchains"].contains(n) {
            return .reinstalable
        }
        return nil
    }

    private func herramientas(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        // Las carpetas ocultas de tu carpeta personal y las de ~/.local/share (donde guardan sus datos muchas herramientas de terminal).
        var carpetas: [(url: URL, nombre: String, herramienta: String)] = Rutas.hijos(Rutas.home)
            .filter { $0.lastPathComponent.hasPrefix(".") && Rutas.esCarpeta($0) && !Self.ocultasConocidas.contains($0.lastPathComponent) }
            .map { ($0, $0.lastPathComponent, String($0.lastPathComponent.dropFirst())) }
        let conVersiones: Set<String> = ["fnm", "uv", "cursor-agent"]   // sus versiones antiguas ya van en «Cachés de desarrollo»
        carpetas += Rutas.hijos(Rutas.enHome(".local/share"))
            .filter { Rutas.esCarpeta($0) && !$0.lastPathComponent.hasPrefix(".") && !conVersiones.contains($0.lastPathComponent) }
            .map { ($0, ".local/share/" + $0.lastPathComponent, $0.lastPathComponent) }
        for (h, n, herramienta) in carpetas {
            if Rutas.existe(h.appendingPathComponent("pyvenv.cfg")) {
                r.append(Elemento(
                    nombre: n,
                    detalle: "Entorno virtual de Python con paquetes instalados.",
                    consecuencia: "Los programas que lo usen dejarán de funcionar hasta que lo vuelvas a crear e instales sus paquetes.",
                    rutas: [h], categoria: .herramientas, riesgo: .revisar,
                    motivos: [.info("shippingbox.fill", "Se puede recrear", "Es un entorno de Python: se reconstruye con python -m venv y pip install.")],
                    dueno: "Python"))
                continue
            }
            let comando = c.apps.comandoPara(carpetaOculta: "." + herramienta)
            let traeSuPrograma = Rutas.esCarpeta(h.appendingPathComponent("bin"))
            let instalado = comando != nil || traeSuPrograma || c.apps.estaInstalado(carpeta: herramienta)
            let ultimo = c.indice.masReciente(de: [h])
            let dias = ultimo.map { Date().timeIntervalSince($0) / 86400 } ?? 9999
            let uso = EnUso.proceso(nombre: herramienta, patron: "/\(n.lowercased())/")

            var motivos: [Motivo] = []
            let riesgo: Riesgo
            if instalado {
                let como = comando.map { " (comando «\($0)»)" } ?? (traeSuPrograma ? " (trae su propio programa)" : "")
                motivos.append(.aviso("wrench.and.screwdriver.fill", "Herramienta instalada",
                    "Es la carpeta de una herramienta que sigue instalada\(como). Si la borras, perderás su configuración e historial."))
                riesgo = .cuidado
            } else if dias < 30 {
                motivos.append(.aviso("clock.fill", "Uso reciente",
                    "Se usó \(Formato.haceCuanto(ultimo).lowercased()): probablemente la herramienta sigue en uso aunque no encontré su comando."))
                riesgo = .cuidado
            } else {
                motivos.append(.bien("questionmark.folder.fill", "Posible resto",
                    "Lleva \(Formato.haceCuanto(ultimo).lowercased().replacingOccurrences(of: "hace ", with: "")) sin usarse y no encontré el programa que la creó."))
                riesgo = .revisar
            }
            r.append(Elemento(
                nombre: n,
                detalle: instalado ? "Configuración, historial y datos de \(herramienta)." : "Carpeta que dejó alguna herramienta.",
                consecuencia: instalado ? "Perderás la configuración, sesiones e historial de \(herramienta)."
                                        : "Si la herramienta se vuelve a usar, empezará de cero.",
                rutas: [h], categoria: .herramientas, riesgo: riesgo, motivos: motivos, enUso: uso, dueno: herramienta))

            // Por dentro: separar lo temporal de lo personal.
            guard (c.indice.info(h.path)?.bytes ?? 0) >= 50_000_000 else { continue }
            // Lo que nombra su configuración no es un temporal aunque se llame así (Codex saca de ~/.codex/.tmp el catálogo
            // de plugins que trae).
            let configuracion = Self.configuracion(de: h)
            var subs: [(URL, Int64)] = c.indice.hijosOrdenados(de: h.path).map { (URL(fileURLWithPath: $0.ruta), $0.bytes) }
            subs += c.indice.grandes.filter { $0.carpeta == h.path }.map { ($0.url, $0.bytes) }
            for (sub, bytes) in subs where bytes >= 20_000_000 && !Self.esCompaneroDeBase(sub.path) {
                guard let clase = clasificarSubcarpeta(sub.lastPathComponent) else { continue }
                let s = sub.lastPathComponent
                // Cada subcarpeta mira lo suyo: que la herramienta esté funcionando desde otra subcarpeta (un plugin,
                // un ayudante del navegador) no significa que esté usando sus temporales.
                let uso = EnUso.rutas(nombre: herramienta, raiz: sub.path)
                switch clase {
                case .temporal, .registros:
                    let esRegistro = clase == .registros
                    if let archivo = Self.nombra(configuracion, carpeta: n, sub: s) {
                        r.append(Elemento(
                            nombre: "\(n) › \(s)",
                            detalle: "Se llama «\(s)», pero la configuración de \(herramienta) (\(archivo)) la usa.",
                            consecuencia: "\(herramienta) puede dejar de encontrar lo que saca de aquí (plugins, catálogos, modelos…) hasta que lo vuelva a crear o lo reinstales.",
                            rutas: [sub], categoria: .herramientas, riesgo: .revisar,
                            motivos: [.aviso("gearshape.fill", "La usa su configuración",
                                             "Tu configuración de \(herramienta) apunta a esta carpeta (\(archivo)): saca algo de aquí, así que no es solo un temporal. Revísala antes de borrarla.")],
                            enUso: uso, dueno: herramienta))
                        continue
                    }
                    // El nombre no basta: algunas herramientas guardan sesiones o bases de datos dentro de «tmp» o «cache».
                    if let dato = Self.datosDentro(sub, esRegistro: esRegistro, c) {
                        r.append(Elemento(
                            nombre: "\(n) › \(s)",
                            detalle: "Se llama «\(s)», pero dentro hay datos de \(herramienta).",
                            consecuencia: "Puedes perder datos de \(herramienta) (\(dato)), no solo archivos temporales.",
                            rutas: [sub], categoria: .herramientas, riesgo: .revisar,
                            motivos: [.aviso("exclamationmark.magnifyingglass", "Revisa el contenido",
                                             "Dentro hay \(dato): puede ser historial o datos de \(herramienta), aunque la carpeta se llame «\(s)».")],
                            enUso: uso, dueno: herramienta))
                        continue
                    }
                    r.append(Elemento(
                        nombre: "\(n) › \(s)",
                        detalle: esRegistro ? "Registros de \(herramienta)." : "Archivos temporales de \(herramienta).",
                        consecuencia: esRegistro ? "Nada: solo se pierden registros antiguos." : "\(herramienta) los vuelve a crear.",
                        rutas: [sub], categoria: .herramientas, riesgo: .seguro, seleccionado: true,
                        motivos: [.bien("arrow.triangle.2.circlepath", esRegistro ? "Solo registros" : "Temporal",
                                        "No encontré sesiones, historial ni bases de datos dentro.")],
                        enUso: uso, dueno: herramienta))
                case .reinstalable:
                    // Si un comando de la terminal abre un programa de aquí dentro, no es un componente suelto: es el programa.
                    if let comando = c.apps.comandoDentro(de: sub.path) {
                        r.append(Elemento(
                            nombre: "\(n) › \(s)",
                            detalle: "Aquí está instalado el programa «\(comando)» que usas desde la terminal.",
                            consecuencia: "El comando \(comando) dejará de funcionar hasta que lo reinstales con su instalador. Tu configuración e historial no se tocan.",
                            rutas: [sub], categoria: .herramientas, riesgo: .cuidado,
                            motivos: [.aviso("terminal.fill", "Contiene el programa «\(comando)»",
                                             "El comando «\(comando)» de tu terminal abre un programa que está en esta carpeta.")],
                            enUso: uso, dueno: herramienta))
                    } else {
                        r.append(Elemento(
                            nombre: "\(n) › \(s)",
                            detalle: "Componentes descargados por \(herramienta).",
                            consecuencia: "\(herramienta) puede dejar de funcionar hasta que los vuelvas a instalar o descargar.",
                            rutas: [sub], categoria: .herramientas, riesgo: .revisar,
                            motivos: [.info("arrow.down.circle.fill", "Se reinstala", "Se pueden volver a descargar.")],
                            enUso: uso, dueno: herramienta))
                    }
                case .personal:
                    // Una base de datos SQLite va con sus archivos -wal y -shm: si se borra sola, queda corrupta.
                    r.append(Elemento(
                        nombre: "\(n) › \(s)",
                        detalle: "Historial o datos guardados de \(herramienta).",
                        consecuencia: "Perderás el historial (sesiones, conversaciones o proyectos) de \(herramienta).",
                        rutas: Self.conCompaneros(sub), categoria: .herramientas, riesgo: .cuidado,
                        motivos: [.aviso("clock.arrow.circlepath", "Tu historial", "Son sesiones, conversaciones o datos que creaste con \(herramienta).")],
                        enUso: uso, dueno: herramienta))
                }
            }
        }
        r += conversacionesAntiguas(c)
        return r
    }

    /// Codex guarda cada conversación en ~/.codex/sessions/AAAA/MM/DD y no borra nunca las viejas.
    /// (Claude Code borra solo las de más de 30 días.)
    private func conversacionesAntiguas(_ c: Contexto) -> [Elemento] {
        let limite = Date().addingTimeInterval(-30 * 86400)
        var viejas: [URL] = []
        for anio in Rutas.hijos(Rutas.enHome(".codex/sessions")) where Rutas.esCarpeta(anio) {
            for mes in Rutas.hijos(anio) where Rutas.esCarpeta(mes) {
                for dia in Rutas.hijos(mes) where Rutas.esCarpeta(dia) {
                    // Por la fecha de la carpeta y por lo último que cambió dentro (una conversación retomada se actualiza).
                    guard let a = Int(anio.lastPathComponent), let m = Int(mes.lastPathComponent), let d = Int(dia.lastPathComponent),
                          let fecha = DateComponents(calendar: .current, year: a, month: m, day: d).date, fecha < limite,
                          (Fechas.masRecienteDentro(dia) ?? fecha) < limite else { continue }
                    viejas.append(dia)
                }
            }
        }
        viejas += Rutas.hijos(Rutas.enHome(".codex/archived_sessions")).filter { (Fechas.modificacion($0) ?? Date()) < limite }
        guard !viejas.isEmpty else { return [] }
        return [Elemento(
            nombre: "Conversaciones de Codex de hace más de un mes",
            detalle: "Las conversaciones que guardó Codex hace más de 30 días (\(viejas.count) \(viejas.count == 1 ? "carpeta" : "carpetas") por día).",
            consecuencia: "Ya no podrás retomarlas con «codex resume» ni volver a leerlas. Las del último mes se quedan.",
            rutas: viejas, categoria: .herramientas, riesgo: .revisar,
            motivos: [.info("bubble.left.and.bubble.right.fill", "Historial antiguo",
                            "Codex no las borra nunca: se acumulan con cada conversación. Claude Code, por ejemplo, borra solo las de más de un mes.")],
            dueno: "Codex")]
    }

    // MARK: - Instaladores

    private func instaladores(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        let montadas = imagenesMontadas()
        // «AvisoYape-1.7.apk» es más nueva que «AvisoYape-1.2.apk»: se agrupan por nombre sin versión.
        var masNueva: [String: (ruta: String, version: String)] = [:]
        for a in c.indice.instaladores {
            guard let (base, version) = Self.nombreYVersion(a.url) else { continue }
            let clave = a.carpeta + "|" + base
            if let actual = masNueva[clave], actual.version.compare(version, options: .numeric) != .orderedAscending { continue }
            masNueva[clave] = (a.ruta, version)
        }
        for a in c.indice.instaladores {
            let url = a.url
            let ext = url.pathExtension.lowercased()
            let fecha = Fechas.ultimoUsoArchivo(url) ?? a.fecha
            let dias = Date().timeIntervalSince(fecha) / 86400
            var motivos: [Motivo] = []
            var riesgo = Riesgo.revisar
            var seleccionado = false
            let detalle: String
            if ext == "apk" || ext == "xapk" || ext == "ipa" {
                detalle = ext == "ipa" ? "Instalador de una app de iPhone." : "Instalador de una app de Android."
                motivos.append(.info("iphone", "App para el teléfono", "Sirve para instalar la app en un teléfono, emulador o simulador."))
            } else {
                detalle = "Instalador."
                let programa = nombreDelPrograma(url.deletingPathExtension().lastPathComponent)
                if let programa, let app = c.apps.nombreApp(para: programa) {
                    // Solo sobra si lo descargaste para instalarlo y no es una versión más nueva que la que tienes.
                    let instalada = versionInstalada(de: app)
                    let suya = Self.nombreYVersion(url)?.1
                    if let suya, let instalada, suya.compare(instalada, options: .numeric) == .orderedDescending {
                        motivos.append(.info("arrow.up.circle.fill", "Versión más nueva",
                                             "Es la versión \(suya) y tienes instalada la \(instalada): quizá todavía no la instalaste."))
                    } else {
                        motivos.append(.bien("checkmark.circle.fill", "Ya está instalada",
                                             "Ya tienes \(app)\(instalada.map { " \($0)" } ?? "") instalada: este instalador ya no hace falta."))
                        let descargado = a.ruta.hasPrefix(Rutas.enHome("Downloads").path + "/") || a.carpeta == Rutas.enHome("Desktop").path
                        riesgo = descargado ? .seguro : .revisar
                        seleccionado = descargado && dias > 3
                    }
                } else {
                    motivos.append(.info("questionmark.app.fill", "No lo veo instalado",
                                         "No encontré \(programa?.capitalized ?? "el programa") instalado. Si todavía no lo instalaste, guárdalo."))
                }
            }
            // El instalador que generas para distribuir tu propia app no es basura aunque la tengas instalada.
            if let repo = repoQueContiene(a.ruta, c) {
                motivos.insert(.peligro("shippingbox.and.arrow.backward.fill", "Parte de tu proyecto",
                    "Está dentro del proyecto \(Rutas.nombre(repo)) (git): seguramente es el instalador que generaste para distribuir tu app."), at: 0)
                riesgo = .cuidado
                seleccionado = false
            } else if Self.tieneSumasDeVerificacion(a.carpeta) || Self.esCarpetaDeEntrega(a.carpeta) {
                motivos.insert(.aviso("checkmark.seal.fill", "Entrega o respaldo",
                    "Está en \(Formato.rutaCorta(a.carpeta)), que parece una carpeta de entregas o respaldos."), at: 0)
                riesgo = max(riesgo, .revisar)
                seleccionado = false
            }
            if let (base, _) = Self.nombreYVersion(url), let nueva = masNueva[a.carpeta + "|" + base], nueva.ruta != a.ruta {
                motivos.append(.bien("arrow.up.circle.fill", "Hay una versión más nueva",
                                     "Al lado tienes \(Rutas.nombre(nueva.ruta)), que es más reciente."))
            }
            var montada: String? = nil
            if let m = montadas[a.ruta] {
                montada = m.dispositivo
                motivos.append(.info("externaldrive.fill", "Montado", "Está abierto como disco «\(m.volumen)». Lo expulsaré antes de borrarlo."))
            }
            r.append(Elemento(
                nombre: url.lastPathComponent,
                detalle: "\(detalle) En \(Formato.rutaCorta(url.deletingLastPathComponent())).",
                consecuencia: "Si necesitas volver a instalarlo, tendrás que descargarlo otra vez.",
                rutas: [url], ultimoUso: fecha, categoria: .instaladores, riesgo: riesgo, seleccionado: seleccionado,
                motivos: motivos, imagenMontada: montada))
        }
        // Copias sueltas de apps que ya están en Aplicaciones. Solo sobran si son la misma versión, de la misma compilación y
        // del mismo desarrollador: una versión anterior que guardaste para volver atrás (o una nueva sin instalar) no se
        // vuelve a descargar igual.
        for ruta in c.indice.apps {
            let url = URL(fileURLWithPath: ruta)
            guard let id = Bundle(url: url)?.bundleIdentifier?.lowercased(), c.apps.idsEnAplicaciones.contains(id) else { continue }
            let nombre = url.deletingPathExtension().lastPathComponent
            let suya = IdentidadDeApp(ruta)
            let instaladas = (c.apps.rutasEnAplicaciones[id] ?? []).map(IdentidadDeApp.init)
            if instaladas.contains(suya) {
                r.append(Elemento(
                    nombre: "Copia de \(nombre)",
                    detalle: "Una copia de \(nombre) en \(Formato.rutaCorta(url.deletingLastPathComponent())).",
                    consecuencia: "Nada: seguirás usando la que está en Aplicaciones, que es la misma versión. Va a la Papelera: puedes devolverla con «Deshacer».",
                    rutas: [url], categoria: .instaladores, riesgo: .seguro, seleccionado: true,
                    motivos: [.bien("checkmark.circle.fill", "Ya está en Aplicaciones",
                                    "Tienes \(nombre) \(suya.texto(compilacion: false)) instalada en Aplicaciones, la misma versión y compilación: esta copia sobra.")],
                    enUso: .app(nombre: nombre, claves: [id]), dueno: nombre))
                continue
            }
            // Otra versión (o la misma de otro desarrollador): se enseña, pero no se marca nunca.
            let instalada = instaladas.first
            let mismaVersion = instalada.map { $0.version == suya.version } ?? false
            let motivo: Motivo
            if let instalada, instalada.version == suya.version && instalada.compilacion == suya.compilacion {
                motivo = .aviso("signature", "La firmó otro desarrollador",
                                "Es la misma versión (\(suya.texto(compilacion: true))) que la de Aplicaciones, pero no la firmó el mismo desarrollador (\(suya.equipo ?? "sin firma de desarrollador"); la instalada, \(instalada.equipo ?? "sin firma de desarrollador")): no es una copia que sobre. Revísala antes de borrarla.")
            } else {
                motivo = .aviso("arrow.triangle.2.circlepath", "Es otra versión",
                                "Es otra versión (\(suya.texto(compilacion: mismaVersion)); la instalada es \(instalada?.texto(compilacion: mismaVersion) ?? "otra")): puede que la guardaras para volver atrás o que todavía no la hayas instalado. Si la borras, no se vuelve a descargar igual.")
            }
            r.append(Elemento(
                nombre: "\(nombre) (otra versión)",
                detalle: "Otra versión de \(nombre) en \(Formato.rutaCorta(url.deletingLastPathComponent())); en Aplicaciones tienes la \(instalada?.texto(compilacion: mismaVersion) ?? "otra").",
                consecuencia: "Pierdes esta versión: si la necesitas para volver atrás, tendrás que buscarla otra vez. Va a la Papelera: puedes devolverla con «Deshacer».",
                rutas: [url], categoria: .instaladores, riesgo: .revisar,
                motivos: [motivo], enUso: .app(nombre: nombre, claves: [id]), dueno: nombre))
        }
        r += copiasDeCompilaciones(c, yaOfrecidas: Set(r.flatMap { $0.rutas.map(\.path) }))
        // Actualizaciones de iPhone y iPad que el Finder descargó para instalar o restaurar.
        for tipo in ["iPhone", "iPad", "iPod"] {
            for f in Rutas.hijos(Rutas.enHome("Library/iTunes/\(tipo) Software Updates")) where f.pathExtension.lowercased() == "ipsw" {
                r.append(Elemento(
                    nombre: f.lastPathComponent,
                    detalle: "Sistema iOS para \(tipo) que el Finder descargó para actualizarlo o restaurarlo.",
                    consecuencia: "Si vuelves a actualizar o restaurar un \(tipo) desde el Mac, el Finder lo descarga otra vez.",
                    rutas: [f], ultimoUso: Fechas.modificacion(f), categoria: .instaladores, riesgo: .seguro, seleccionado: true,
                    motivos: [.bien("arrow.down.circle.fill", "Se vuelve a descargar", "Apple lo descarga de nuevo si hace falta.")],
                    dueno: "Finder"))
            }
        }
        // Instaladores de macOS («Instalar macOS Sequoia») que se quedaron en Aplicaciones.
        for app in Rutas.hijos(URL(fileURLWithPath: "/Applications")) where app.pathExtension == "app" {
            guard let id = Bundle(url: app)?.bundleIdentifier, id.hasPrefix("com.apple.InstallAssistant") else { continue }
            let nombre = app.deletingPathExtension().lastPathComponent
            r.append(Elemento(
                nombre: nombre,
                detalle: "El instalador completo de una versión de macOS.",
                consecuencia: "Si quieres instalar esa versión otra vez o crear un USB de arranque, tendrás que descargarla de nuevo; las versiones antiguas o beta puede que ya no se ofrezcan.",
                rutas: [app], tamanosRutas: [Tamanos.de(app)], ultimoUso: Fechas.ultimoUsoSpotlight(app),
                categoria: .instaladores, riesgo: .revisar,
                motivos: [.info("arrow.down.circle.fill", "Instalador de macOS",
                                "No hace falta para usar tu Mac, pero sirve para reinstalar o crear un USB de arranque. Si es una versión antigua o beta, guárdalo si lo necesitas.")],
                enUso: .app(nombre: nombre, claves: [id]), dueno: "macOS"))
        }
        return r
    }

    /// Apps del Escritorio o de Descargas que son la misma compilación que una .app de dist/, out/ o build/ de un
    /// proyecto (la sacaste de ahí para probarla): mismo identificador, mismo ejecutable y mismo app.asar (SHA-256).
    /// Se ofrecen para revisar: si sobra, sigues teniendo la del proyecto, y esa se vuelve a compilar.
    private func copiasDeCompilaciones(_ c: Contexto, yaOfrecidas: Set<String>) -> [Elemento] {
        let lugares = ["Desktop", "Downloads"].map { Rutas.enHome($0).path + "/" }
        let sueltas = c.indice.apps.filter { a in lugares.contains { a.hasPrefix($0) } && !yaOfrecidas.contains(a) }
        guard !sueltas.isEmpty else { return [] }
        // Las .app que compilan tus proyectos, por su identificador.
        var compiladas: [String: [String]] = [:]
        for a in c.indice.artefactos where ["dist", "out", "build"].contains(Rutas.nombre(a.ruta)) {
            for app in Self.appsDentro(a.ruta, niveles: 3) {
                if let id = Bundle(path: app)?.bundleIdentifier?.lowercased() { compiladas[id, default: []].append(app) }
            }
        }
        var r: [Elemento] = []
        for ruta in sueltas {
            guard let id = Bundle(path: ruta)?.bundleIdentifier?.lowercased(), let candidatas = compiladas[id],
                  let igual = candidatas.first(where: { Self.mismaCompilacion(ruta, $0) }) else { continue }
            let url = URL(fileURLWithPath: ruta)
            let nombre = url.deletingPathExtension().lastPathComponent
            let proyecto = Rutas.nombre(Rutas.padre(c.indice.artefactos.first { igual.hasPrefix($0.ruta + "/") }?.ruta ?? igual))
            let conAsar = Rutas.existe(ruta + "/Contents/Resources/app.asar")
            r.append(Elemento(
                nombre: "\(nombre) (copia de una compilación)",
                detalle: "\(nombre).app en \(Formato.rutaCorta(url.deletingLastPathComponent())) es la misma compilación que hay en \(Formato.rutaCorta(Rutas.padre(igual))).",
                consecuencia: "Se borra esta copia. Sigues teniendo la de \(proyecto), y si borras las dos, la vuelves a compilar. Va a la Papelera: puedes devolverla con «Deshacer».",
                rutas: [url], ultimoUso: Fechas.ultimoUsoSpotlight(url), categoria: .instaladores, riesgo: .revisar,
                motivos: [.info("square.on.square", "Igual que la de \(proyecto)",
                                "Tiene el mismo identificador, el mismo ejecutable\(conAsar ? " y el mismo app.asar" : "") que \(Formato.rutaCorta(igual)): es la misma compilación, copiada aquí.")],
                enUso: .app(nombre: nombre, claves: [id]), dueno: proyecto))
        }
        return r
    }

    /// Las .app que hay dentro de una carpeta, bajando como mucho `niveles` (sin entrar en las propias apps).
    private static func appsDentro(_ carpeta: String, niveles: Int) -> [String] {
        guard niveles > 0 else { return [] }
        var r: [String] = []
        for h in Rutas.hijos(URL(fileURLWithPath: carpeta)) where Rutas.esCarpeta(h) && !Self.esEnlace(h) {
            if h.pathExtension == "app" { r.append(h.path) } else { r += appsDentro(h.path, niveles: niveles - 1) }
        }
        return r
    }

    /// Dos .app son la misma compilación: el mismo ejecutable principal y, si es de Electron, el mismo app.asar.
    private static func mismaCompilacion(_ a: String, _ b: String) -> Bool {
        guard let ejecutable = Bundle(path: a)?.executableURL?.lastPathComponent,
              ejecutable == Bundle(path: b)?.executableURL?.lastPathComponent else { return false }
        for rel in ["Contents/MacOS/" + ejecutable, "Contents/Resources/app.asar"] {
            let (x, y) = (a + "/" + rel, b + "/" + rel)
            switch (Rutas.existe(x), Rutas.existe(y)) {
            case (false, false): continue
            case (true, true):
                guard let hx = Huella.sha256(URL(fileURLWithPath: x)), hx == Huella.sha256(URL(fileURLWithPath: y)) else { return false }
            default: return false
            }
        }
        return true
    }

    /// Carpetas donde se guardan los instaladores que generas para entregar o publicar.
    private static func esCarpetaDeEntrega(_ carpeta: String) -> Bool {
        let n = Rutas.nombre(carpeta).lowercased()
        return ["instaladores", "installers", "release", "releases", "entrega", "entregas", "distribucion", "distribución",
                "publicar", "publicacion", "deliverables"].contains { n == $0 || n.hasPrefix($0 + "_") || n.hasPrefix($0 + "-") }
    }

    /// Versión de una app instalada (CFBundleShortVersionString), buscándola por su nombre visible.
    private func versionInstalada(de app: String) -> String? {
        let buscado = AppsInstaladas.normalizar(app)
        for carpeta in [URL(fileURLWithPath: "/Applications"), Rutas.enHome("Applications")] {
            for u in Rutas.hijos(carpeta) where u.pathExtension == "app"
            && AppsInstaladas.normalizar(u.deletingPathExtension().lastPathComponent) == buscado {
                return Bundle(url: u)?.infoDictionary?["CFBundleShortVersionString"] as? String
            }
        }
        return nil
    }

    /// «AvisoYape-1.7.apk» → («avisoyape», «1.7»)
    private static func nombreYVersion(_ url: URL) -> (String, String)? {
        let n = url.deletingPathExtension().lastPathComponent
        guard let r = n.range(of: #"[-_ ]v?(\d+(\.\d+)+)"#, options: .regularExpression) else { return nil }
        let version = n[r].trimmingCharacters(in: CharacterSet(charactersIn: "-_ v"))
        let base = AppsInstaladas.normalizar(String(n[..<r.lowerBound])) + "." + url.pathExtension.lowercased()
        return (base, version)
    }

    /// «Cline_0.0.36_universal» → «cline»
    private func nombreDelPrograma(_ archivo: String) -> String? {
        let ruido: Set<String> = ["universal", "arm", "aarch", "x", "amd", "intel", "mac", "macos", "osx", "darwin",
                                  "setup", "installer", "install", "latest", "stable", "beta", "release", "build",
                                  "apple", "silicon", "dmg", "pkg", "v", "for", "de", "para"]
        let palabras = archivo.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
            .filter { !ruido.contains($0) && $0.count >= 2 }
        return palabras.first
    }

    private func imagenesMontadas() -> [String: (dispositivo: String, volumen: String)] {
        let salida = Shell.ejecutar("/usr/bin/hdiutil", ["info", "-plist"], limite: 15).salida
        guard let datos = salida.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: datos, format: nil) as? [String: Any],
              let imagenes = plist["images"] as? [[String: Any]] else { return [:] }
        var r: [String: (String, String)] = [:]
        for img in imagenes {
            guard let ruta = img["image-path"] as? String,
                  let entidades = img["system-entities"] as? [[String: Any]] else { continue }
            let disco = entidades.compactMap { $0["dev-entry"] as? String }.min(by: { $0.count < $1.count })
            let punto = entidades.compactMap { $0["mount-point"] as? String }.first
            if let disco { r[ruta] = (disco, punto.map { Rutas.nombre($0) } ?? disco) }
        }
        return r
    }

    // MARK: - Registros

    private func registros(_ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        for h in Rutas.hijos(Rutas.enHome("Library/Logs")) {
            let n = h.lastPathComponent
            if n.hasPrefix(".") || Self.propios.contains(n) || !c.apps.estaInstalado(carpeta: n) { continue }
            let app: String? = n == "DiagnosticReports" ? nil : (c.apps.nombreApp(para: n) ?? nombreBonito(n))
            r.append(Elemento(
                nombre: app.map { "Registros de \($0)" } ?? "Reportes de fallos",
                detalle: app.map { "Archivos de registro de \($0)." } ?? "Informes que macOS guarda cuando una app se cierra de golpe.",
                consecuencia: "Nada importante: solo se pierden registros y errores antiguos.",
                rutas: [h], categoria: .registros, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("doc.text.magnifyingglass", "Solo registros", "Sirven para diagnosticar errores; se crean nuevos cuando hace falta.")],
                enUso: app.map { .app(nombre: $0, claves: [n, $0]) }, dueno: app))
        }
        // Registros que las apps guardan dentro de sus datos (…/Application Support/App/logs).
        let appSupport = Rutas.enHome("Library/Application Support").path + "/"
        var porApp: [String: [URL]] = [:]
        for (ruta, tipo) in c.indice.cachesInternas where tipo == .registros {
            guard let carpeta = ruta.dropFirst(appSupport.count).split(separator: "/").first.map(String.init) else { continue }
            porApp[carpeta, default: []].append(URL(fileURLWithPath: ruta))
        }
        for (carpeta, rutas) in porApp {
            guard !carpeta.hasPrefix("com.apple."), !Self.propios.contains(carpeta), c.apps.estaInstalado(carpeta: carpeta) else { continue }
            let app = c.apps.nombreApp(para: carpeta) ?? carpeta
            r.append(Elemento(
                nombre: "Registros internos de \(app)",
                detalle: "Registros y reportes de fallos que \(app) guarda junto a sus datos.",
                consecuencia: "Nada importante: solo se pierden registros antiguos.",
                rutas: rutas, categoria: .registros, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("doc.text.magnifyingglass", "Solo registros", "No contienen tus datos.")],
                enUso: .app(nombre: app, claves: [carpeta, app]), dueno: app))
        }

        // Volcados de memoria de Java. Los que crea la JVM sola al quedarse sin memoria (java_pid123.hprof) sobran;
        // los que tienen otro nombre o están en tus carpetas pueden ser capturas guardadas a propósito para analizarlas.
        let personales = ["Documents", "Desktop", "Downloads"].map { Rutas.enHome($0).path + "/" }
        func automatico(_ a: ArchivoIndexado) -> Bool {
            let n = a.nombre.lowercased()
            return (n.hasPrefix("java_pid") || n.hasPrefix("java_error")) && !personales.contains(where: { a.ruta.hasPrefix($0) })
                && repoQueContiene(a.ruta, c) == nil && Date().timeIntervalSince(a.fecha) > 7 * 86400
        }
        let automaticos = c.indice.volcados.filter(automatico)
        let guardados = c.indice.volcados.filter { !automatico($0) }
        if !automaticos.isEmpty {
            r.append(Elemento(
                nombre: "Volcados de memoria de Java (\(automaticos.count))",
                detalle: "Archivos .hprof que Java creó solo al quedarse sin memoria (Android Studio, Gradle…).",
                consecuencia: "Nada: solo sirven para analizar ese fallo concreto.",
                rutas: automaticos.map(\.url), ultimoUso: automaticos.map(\.fecha).max(), categoria: .registros, riesgo: .seguro,
                seleccionado: true,
                motivos: [.bien("memorychip", "Solo diagnóstico", "Los crea Java solo cuando un programa falla por falta de memoria.")]))
        }
        if !guardados.isEmpty {
            r.append(Elemento(
                nombre: "Capturas de memoria de Java (\(guardados.count))",
                detalle: "Archivos .hprof: \(Formato.listaCorta(guardados.map { Formato.rutaCorta($0.ruta) })).",
                consecuencia: "Si los guardaste para analizar un problema, perderás esa captura.",
                rutas: guardados.map(\.url), ultimoUso: guardados.map(\.fecha).max(), categoria: .registros, riesgo: .revisar,
                motivos: [.info("memorychip", "Puede ser a propósito", "Por su nombre o su carpeta, parece una captura que alguien guardó para analizarla.")]))
        }

        // Registros enormes fuera de Library. Muchos .log son datos de verdad (segmentos de Kafka, el registro de
        // una base de datos, el de un entrenamiento): solo se marcan solos los que son claramente de una herramienta.
        for a in c.indice.registrosGrandes {
            let viejo = Date().timeIntervalSince(a.fecha) / 86400 >= 7
            let n = a.nombre.lowercased()
            let carpeta = Rutas.nombre(a.carpeta).lowercased()
            let deHerramienta = ["logs", "log"].contains(carpeta) || n.hasSuffix("-debug.log") || n.hasSuffix(".debug.log")
            let repo = repoQueContiene(a.ruta, c)
            var motivos: [Motivo] = []
            let riesgo: Riesgo
            if let repo {
                motivos.append(.peligro("chevron.left.forwardslash.chevron.right", "Parte de tu proyecto",
                                        "Está dentro del proyecto \(Rutas.nombre(repo)): puede ser un dato del proyecto, no un registro."))
                riesgo = .cuidado
            } else if deHerramienta {
                motivos.append(viejo
                    ? .bien("doc.text.magnifyingglass", "Solo registros", "Está en una carpeta de registros y nadie escribe en él desde \(Formato.haceCuanto(a.fecha).lowercased()).")
                    : .info("clock.fill", "Se sigue escribiendo", "Cambió \(Formato.haceCuanto(a.fecha).lowercased()): si un programa lo tiene abierto, ciérralo antes."))
                riesgo = .seguro
            } else {
                motivos.append(.info("doc.text.magnifyingglass", "Revisa qué es",
                                     "Termina en .log, pero no está en una carpeta de registros: puede ser el resultado de algo (un entrenamiento, una exportación)."))
                riesgo = .revisar
            }
            r.append(Elemento(
                nombre: a.nombre,
                detalle: "Registro de \(Formato.bytes(a.bytes)) en \(Formato.rutaCorta(a.carpeta)).",
                consecuencia: riesgo == .seguro ? "Nada importante: solo se pierden mensajes antiguos."
                                                : "Puede contener datos: revisa qué es antes de borrarlo.",
                rutas: [a.url], ultimoUso: a.fecha, categoria: .registros, riesgo: riesgo,
                seleccionado: riesgo == .seguro && viejo, motivos: motivos))
        }
        return r
    }

    // MARK: - Papelera

    private func papelera() -> [Elemento] {
        let trash = Rutas.enHome(".Trash")
        guard let contenido = try? FileManager.default.contentsOfDirectory(atPath: trash.path), !contenido.isEmpty else { return [] }
        // El índice no recorre la Papelera: se mide aparte.
        return [Elemento(
            nombre: "Contenido de la Papelera (\(contenido.count) \(contenido.count == 1 ? "elemento" : "elementos"))",
            detalle: "Lo que ya enviaste a la Papelera.",
            consecuencia: "Se borra para siempre: ya no podrás recuperarlo.",
            rutas: [trash], tamanoFijo: Limpiador.tamanoPapelera(), categoria: .papelera, riesgo: .revisar, accion: .vaciarPapelera,
            motivos: [.info("trash.fill", "Ya descartado", "Son cosas que tú mismo enviaste a la Papelera.")])]
    }

    // MARK: - Duplicados

    /// Archivos idénticos byte a byte (mismo tamaño, misma huella del principio y del final y mismo SHA-256). De tus
    /// carpetas se ofrece borrar la copia que sobra, como siempre; y de tus carpetas, las ocultas y Library, unir cada
    /// grupo en una sola copia en el disco sin borrar ninguna (`unirCopias`), salvo lo que otra categoría ya ofrece borrar
    /// como Seguro (`seguras`: cachés, transformaciones de Gradle…), que se libera entero al borrarlo.
    private func duplicados(_ c: Contexto, seguras: [String]) -> [Elemento] {
        let descargas = Rutas.enHome("Downloads").path + "/"
        // Borrar la copia que sobra solo se ofrece en tus carpetas (en las ocultas y en Library son archivos de apps y
        // herramientas que los buscan justo ahí), y no con los instaladores, que tienen su propia categoría.
        func paraBorrar(_ a: ArchivoIndexado) -> Bool {
            a.tamano >= minimo && a.zona == .personal && !Self.extensionesDeInstaladores.contains((a.ruta as NSString).pathExtension.lowercased())
        }
        let seBorran = Set(seguras)
        var basesDeDatos: [String: Bool] = [:]
        func paraUnir(_ a: ArchivoIndexado) -> Bool {
            Self.sePuedeUnir(a.ruta) && !seBorran.contains(a.ruta) && !Totales.dentroDe(a.ruta, seBorran)
                && !Self.dentroDeUnaBaseDeDatos(a.ruta, &basesDeDatos)
        }
        // Los de menos de 1 MB solo sirven para unir, y una unión solo se ofrece si ahorra 1 MB o más: si no hay bastantes
        // archivos de ese tamaño para llegar, ni se miran (ni su ruta ni su huella).
        let porTamano = Dictionary(grouping: c.indice.duplicables, by: \.tamano).mapValues(\.count)
        let candidatos = c.indice.duplicables.filter { a in
            guard a.tamano >= minimo || Int64((porTamano[a.tamano] ?? 0) - 1) * a.tamano >= minimo else { return false }
            return paraBorrar(a) || paraUnir(a)
        }
        var r: [Elemento] = []
        for iguales in Self.gruposIdenticos(candidatos) {
            let borrables = iguales.filter(paraBorrar)
            if borrables.count > 1 { r += copiasQueSobran(borrables, descargas: descargas, c) }
            let unibles = iguales.filter(paraUnir)
            if unibles.count > 1, let el = unirCopias(unibles, c) { r.append(el) }
        }
        return r
    }

    /// Grupos de archivos con el mismo contenido: mismo tamaño, misma huella del principio y del final y mismo SHA-256.
    /// Dos nombres del mismo archivo (enlaces duros) cuentan una vez. Las huellas se calculan en paralelo.
    private static func gruposIdenticos(_ archivos: [ArchivoIndexado]) -> [[ArchivoIndexado]] {
        var porTamano: [Int64: [ArchivoIndexado]] = [:]
        for a in archivos { porTamano[a.tamano, default: []].append(a) }
        var mismoTamano: [ArchivoIndexado] = []
        for (_, grupo) in porTamano where grupo.count > 1 {
            // Dos nombres para el mismo archivo (enlaces) no son duplicados.
            var vistos = Set<String>()
            let unicos = grupo.filter { vistos.insert("\($0.dispositivo):\($0.inodo)").inserted }
            if unicos.count > 1 { mismoTamano += unicos }
        }
        let parciales = enParalelo(mismoTamano) { Huella.parcial($0.url, tamano: $0.tamano) }
        var porParcial: [String: [ArchivoIndexado]] = [:]
        for (a, h) in zip(mismoTamano, parciales) {
            if let h { porParcial["\(a.tamano):\(h)", default: []].append(a) }
        }
        let dudosos = porParcial.values.filter { $0.count > 1 }.flatMap { $0 }
        let completas = enParalelo(dudosos) { Huella.sha256($0.url) }
        var porHash: [String: [ArchivoIndexado]] = [:]
        for (a, h) in zip(dudosos, completas) {
            if let h { porHash["\(a.tamano):\(h)", default: []].append(a) }
        }
        return porHash.values.filter { $0.count > 1 }
    }

    /// Borrar las copias que sobran de un grupo de archivos idénticos de tus carpetas: se conserva la que vive en tu
    /// proyecto o está ordenada (`puntaje`), y cada una de las demás sale en Revisar (o Cuidado, si un proyecto o un
    /// programa la busca justo ahí).
    private func copiasQueSobran(_ iguales: [ArchivoIndexado], descargas: String, _ c: Contexto) -> [Elemento] {
        var r: [Elemento] = []
        // Los clones de APFS comparten el espacio: borrar uno no libera nada.
        var porContenido: [Int64: String] = [:]
        let reales = iguales.filter { a in
            let v = try? a.url.resourceValues(forKeys: [.fileContentIdentifierKey])
            guard let id = (v?.allValues[.fileContentIdentifierKey] as? NSNumber)?.int64Value else { return true }
            if let otro = porContenido[id] {
                c.memoria.clones[a.ruta] = otro
                c.memoria.clones[otro] = a.ruta
                return false
            }
            porContenido[id] = a.ruta
            return true
        }
        guard reales.count > 1 else { return r }
        let ordenadas = reales.sorted {
            let (a, b) = (puntaje($0, c), puntaje($1, c))
            return a != b ? a > b : $0.modificado < $1.modificado
        }
        let original = ordenadas[0]
        for copia in ordenadas.dropFirst() {
            var motivos: [Motivo] = [
                .bien("doc.on.doc.fill", "Hay otra copia",
                      "Se conserva la copia de \(Formato.rutaCorta(original.carpeta)), idéntica byte a byte."),
            ]
            var riesgo = Riesgo.revisar
            if reales.count > 2 {
                motivos.append(.info("square.stack.fill", "\(reales.count) copias", "Hay \(reales.count) copias idénticas de este archivo."))
            }
            if copia.ruta.contains("/Music/Music/") || copia.ruta.contains("/iTunes/") {
                motivos.append(.aviso("music.note", "Biblioteca de Música",
                                      "Está dentro de la biblioteca de la app Música: si lo borras aquí, la canción quedará rota en la app. Mejor bórrala desde Música."))
            }
            // Que sea idéntico no quiere decir que sobre: un proyecto o un programa lo buscan justo ahí.
            if let repo = repoQueContiene(copia.ruta, c) {
                motivos.insert(.peligro("chevron.left.forwardslash.chevron.right", "Parte de un proyecto",
                    "Está dentro del proyecto \(Rutas.nombre(repo)): su código puede cargar este archivo justo desde aquí, y sin él el proyecto se rompe."), at: 0)
                riesgo = .cuidado
            }
            if Self.esParteDeUnPrograma(copia.ruta) {
                motivos.insert(.peligro("gearshape.fill", "Parte de un programa",
                    "Es un archivo de un programa (librería o ejecutable): el programa lo busca en esta carpeta y sin él deja de funcionar."), at: 0)
                riesgo = .cuidado
            }
            if Self.tieneSumasDeVerificacion(copia.carpeta) {
                motivos.insert(.peligro("checkmark.seal.fill", "Respaldo o entrega",
                    "Su carpeta tiene una lista de sumas de verificación (SHA256SUMS): forma parte de un respaldo o de una entrega y debe quedarse completa."), at: 0)
                riesgo = .cuidado
            }
            r.append(Elemento(
                nombre: copia.nombre,
                detalle: "Copia idéntica de \(Formato.rutaCorta(original.ruta)).",
                consecuencia: "Se borra solo esta copia; la de \(Formato.rutaCorta(original.carpeta)) se conserva.",
                rutas: [copia.url], ultimoUso: copia.fecha, categoria: .duplicados, riesgo: riesgo,
                seleccionado: riesgo == .revisar && copia.ruta.hasPrefix(descargas) && !original.ruta.hasPrefix(descargas),
                motivos: motivos))
        }
        return r
    }

    /// Instaladores: tienen su propia categoría, así que aquí no se ofrece borrarlos.
    private static let extensionesDeInstaladores: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "apk", "xapk", "ipa", "aab"]

    /// Lo que no se une nunca: bases de datos y sus diarios, discos de máquinas virtuales y de emuladores (se escriben por
    /// bloques y suelen estar abiertos), registros que crecen, candados y sockets.
    private static let extensionesSinUnir: Set<String> = [
        "sqlite", "sqlite3", "sqlitedb", "db", "db3", "realm", "ldb", "mdb", "wal", "shm", "journal",
        "qcow2", "qcow", "vmdk", "vdi", "vhd", "vhdx", "hdd", "raw", "img", "sparseimage", "sparsebundle",
        "log", "lock", "pid", "sock",
    ]
    /// Carpetas cuyos archivos no se unen: las bibliotecas de Música, Fotos, Final Cut, Logic y GarageBand (las gestionan
    /// sus apps), emuladores y máquinas virtuales, cachés (se borran o se reescriben), compilaciones y dependencias (se
    /// regeneran), el historial de git, la Papelera y las carpetas de esta app (también las temporales de una compresión,
    /// «.limpiador-<UUID>», que quedan en la carpeta que se comprimía si se corta).
    private static let carpetasSinUnir = [
        "/Music/Music/", "/iTunes/", ".photoslibrary/", ".musiclibrary/", ".tvlibrary/", ".imovielibrary/", ".fcpbundle/",
        ".logicx/", ".band/", ".avd/", ".utm/", ".vmwarevm/", ".pvm/", "/Library/Caches/", "/.cache/", "/node_modules/",
        "/build/", "/.git/", "/.Trash/", "/Library/Application Support/LimpiadorMac/", "/" + Compresor.prefijoTemporal,
    ]

    /// Por su ruta, se puede cambiar por un clon de otra copia: está en tu carpeta, fuera de iCloud, el correo, los
    /// mensajes, las fotos y los datos de las apps aisladas (`Seguridad.sePuedeModificar`), y no es nada de lo de arriba.
    private static func sePuedeUnir(_ ruta: String) -> Bool {
        let ext = (ruta as NSString).pathExtension.lowercased()
        guard !extensionesSinUnir.contains(ext), !["-wal", "-shm", "-journal"].contains(where: { ruta.hasSuffix($0) }),
              !carpetasSinUnir.contains(where: { ruta.contains($0) }) else { return false }
        return Seguridad.sePuedeModificar(URL(fileURLWithPath: ruta))
    }

    /// Lo que delata la carpeta de datos de un servidor de bases de datos (PostgreSQL, MySQL/MariaDB, MongoDB): sus
    /// archivos no llevan extensión («base/1/2691») y los gestiona el servidor.
    private static let marcasDeBaseDeDatos = ["PG_VERSION", "ibdata1", "WiredTiger"]

    /// Está dentro de la carpeta de datos de un servidor de bases de datos (alguna carpeta de encima, hasta tu carpeta
    /// personal, tiene una de `marcasDeBaseDeDatos`). Esos archivos no se unen aunque sean idénticos: los gestiona el
    /// servidor, y no hace falta tocarlos. `vistas` guarda lo ya mirado, carpeta por carpeta.
    private static func dentroDeUnaBaseDeDatos(_ ruta: String, _ vistas: inout [String: Bool]) -> Bool {
        let casa = Rutas.home.path
        var carpeta = Rutas.padre(ruta)
        var recorridas: [String] = []
        var es = false
        while carpeta.count > casa.count && carpeta.hasPrefix(casa) {
            if let ya = vistas[carpeta] { es = ya; break }
            recorridas.append(carpeta)
            if marcasDeBaseDeDatos.contains(where: { Rutas.existe(carpeta + "/" + $0) }) { es = true; break }
            carpeta = Rutas.padre(carpeta)
        }
        for c in recorridas { vistas[c] = es }
        return es
    }

    /// Tiene «resource fork» (datos aparte, de los archivos clásicos de Mac): la huella solo mira el contenido normal,
    /// así que dos archivos «idénticos» podrían no serlo del todo. No se unen.
    private static func tieneRecursos(_ ruta: String) -> Bool {
        getxattr(ruta, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    /// Unir un grupo de copias idénticas en una sola copia en el disco, sin borrar ninguna (ver `Clonador`). Es Seguro
    /// (no se pierde nada) y está preparado para «Liberar al máximo» (nivel .maximo): en el modo normal no se marca. Solo
    /// entran los archivos que se pueden cambiar sin perder nada: regulares, tuyos, con un solo nombre (sin enlaces
    /// duros), sin banderas especiales ni datos en la nube (dataless), legibles, en una carpeta en la que se puede
    /// escribir, que nadie tiene abiertos, sin cambios desde hace 1 día o más y en el mismo disco. Lo que ya comparte sus
    /// bloques (clones) cuenta una vez.
    private func unirCopias(_ iguales: [ArchivoIndexado], _ c: Contexto) -> Elemento? {
        struct Miembro {
            let a: ArchivoIndexado
            let e: Compresor.EstadoArchivo
            let info: Privado.Info
            var comprimido: Bool { e.banderas & UInt32(UF_COMPRESSED) != 0 }
            /// Los clones exactos comparten el mismo id de datos; los demás, uno propio.
            var datos: String { info.clon != 0 ? "c\(info.clon)" : "i\(e.inodo)" }
        }
        let haceUnDia = Int(Date().timeIntervalSince1970) - 86_400
        let validos: [Miembro] = iguales.compactMap { a in
            guard let e = Compresor.EstadoArchivo(ruta: a.ruta), e.esRegular, e.dueno == getuid(), e.enlaces == 1,
                  e.banderas & Clonador.banderasProhibidas == 0, e.tamano == a.tamano, e.modificado.s <= haceUnDia,
                  e.modo & S_IRUSR != 0, access(Rutas.padre(a.ruta), W_OK) == 0, !Self.tieneRecursos(a.ruta),
                  c.procesos.abiertos.hayAbierto(dentroDe: a.ruta) == nil,
                  let info = Privado.consultar(a.ruta) else { return nil }
            return Miembro(a: a, e: e, info: info)
        }
        guard let disco = validos.first?.e.dispositivo else { return nil }
        let miembros = validos.filter { $0.e.dispositivo == disco }
        guard miembros.count > 1 else { return nil }
        // La que se conservaría al borrar (tu proyecto, Música, Documentos…) va primero.
        let antes = { (x: Miembro, y: Miembro) -> Bool in
            let (a, b) = (self.puntaje(x.a, c), self.puntaje(y.a, c))
            if a != b { return a > b }
            return x.a.modificado != y.a.modificado ? x.a.modificado < y.a.modificado : x.a.ruta < y.a.ruta
        }
        let porDatos = Dictionary(grouping: miembros, by: \.datos).mapValues { $0.sorted(by: antes) }
        // La fuente: una que ya esté comprimida (las demás heredan la compresión al clonarla) o, si no, la del grupo de
        // clones más grande (lo que ya está unido).
        let fuente = miembros.filter(\.comprimido).min { $0.e.ocupa < $1.e.ocupa }
            ?? porDatos.values.max { $0.count != $1.count ? $0.count < $1.count : antes($1[0], $0[0]) }![0]
        let yaUnidas = (porDatos[fuente.datos]?.count ?? 1) - 1
        var copias: [(m: Miembro, ahorro: Int64)] = []
        var compartidas = 0
        for (clave, grupo) in porDatos where clave != fuente.datos {
            if grupo.count == 1 && (grupo[0].comprimido || grupo[0].info.copias <= 1) {
                let m = grupo[0]
                copias.append((m, m.comprimido ? m.e.ocupa : min(m.info.privado, m.e.ocupa)))
            } else if !grupo[0].comprimido && Int(grupo[0].info.copias) == grupo.count {
                // Clones entre sí y todos aquí: al cambiarlos todos, su contenido se libera una vez.
                for (i, m) in grupo.enumerated() { copias.append((m, i == 0 ? m.e.ocupa : 0)) }
            } else {
                // Comparten sus bloques con archivos de fuera que se quedan: cambiarlas no liberaría nada.
                compartidas += grupo.count
            }
        }
        let ahorro = copias.reduce(Int64(0)) { $0 + $1.ahorro }
        guard ahorro > 0 else { return nil }
        copias.sort { antes($0.m, $1.m) }
        let todos = [fuente] + copias.map(\.m)
        let total = todos.count + yaUnidas
        let carpetas = Array(Set(todos.map { Formato.rutaCorta($0.a.carpeta) })).sorted()
        var motivos: [Motivo] = [
            .bien("square.on.square", "Sin borrar nada",
                  "Las \(total) copias siguen en su sitio, con su nombre, sus permisos y sus fechas; solo dejan de ocupar el disco por separado (un clon de APFS, lo mismo que hace «Duplicar» en el Finder)."),
            .info("checkmark.seal.fill", "Idénticas",
                  "Comparé su contenido completo (SHA-256). Antes de cambiar cada copia la vuelvo a comparar byte a byte, y si algo cambió desde ahora, no la toco."),
        ]
        if yaUnidas > 0 {
            motivos.append(.info("square.on.square.dashed", "Ya compartían",
                "\(yaUnidas == 1 ? "Otra copia ya era un clon" : "\(yaUnidas) copias ya eran clones") de \(Formato.rutaCorta(fuente.a.ruta)): no ocupan más y no cuentan."))
        }
        if compartidas > 0 {
            motivos.append(.info("hand.raised.fill", "Se quedan como están",
                "\(compartidas == 1 ? "Una copia comparte" : "\(compartidas) copias comparten") ya su espacio con otros archivos (clones de APFS): cambiarlas no liberaría nada."))
        }
        if fuente.comprimido {
            motivos.append(.info("rectangle.compress.vertical", "Comprimida",
                "\(Formato.rutaCorta(fuente.a.ruta)) ya está comprimida: las demás copias heredan su compresión al unirlas."))
        }
        func archivo(_ m: Miembro) -> Clonacion.Archivo {
            Clonacion.Archivo(ruta: m.a.ruta, tamano: m.e.tamano, modificado: m.e.modificado)
        }
        return Elemento(
            nombre: "Unir copias idénticas de \(fuente.a.nombre) (\(total) copias)",
            detalle: "\(total) archivos idénticos de \(Formato.bytes(fuente.a.tamano)) cada uno, en \(Formato.listaCorta(carpetas)).",
            consecuencia: "No se borra nada ni cambia ninguna ruta: cada copia sigue en su sitio, pero el disco guarda el contenido una sola vez y ahorras unos \(Formato.bytes(ahorro)). Si después cambias una, macOS copia solo lo que cambia y las demás se quedan como estaban, así que no hace falta deshacerlo. Comparar las copias tarda un poco, y si haces copias de seguridad con Time Machine, se vuelven a copiar una vez.",
            rutas: todos.map(\.a.url), tamanoFijo: ahorro, ultimoUso: todos.map(\.a.fecha).max(),
            categoria: .duplicados, riesgo: .seguro, seleccionado: true,
            accion: .clonar(Clonacion(original: archivo(fuente), copias: copias.map { archivo($0.m) })),
            motivos: motivos, nivel: .maximo, costes: [.tiempoCPU],
            prevision: PrevisionCompresion(copias.map { .init(ruta: $0.m.a.ruta, ahorro: $0.ahorro) },
                                           ocupan: copias.reduce(Int64(0)) { $0 + $1.m.e.ocupa }, requiere: fuente.a.ruta))
    }

    /// Carpetas donde se guardan versiones viejas o copias de seguridad: la copia de ahí es la que sobra.
    private static let carpetasDeCopias = ["/revisions/", "/revision/", "/backup", "/backups/", "/respaldo", "/old/", "/archive/",
                                           "/archivo/", "/copia", "/copies/", "/versions/", "/history/", "/historial/"]

    /// Qué copia conviene conservar: la que vive en tu proyecto o está ordenada (Música, Documentos…),
    /// y no la de una carpeta de revisiones o copias.
    private func puntaje(_ a: ArchivoIndexado, _ c: Contexto) -> Int {
        let home = Rutas.home.path
        var s = 0
        for (carpeta, valor) in [("/Music/", 3), ("/Pictures/", 3), ("/Movies/", 3), ("/Documents/", 2), ("/Desktop/", 1), ("/Downloads/", -3)]
        where a.ruta.hasPrefix(home + carpeta) { s += valor }
        let n = a.nombre.lowercased()
        if n.contains(" copy") || n.contains(" copia") || n.range(of: #"\(\d+\)"#, options: .regularExpression) != nil { s -= 2 }
        let ruta = a.ruta.lowercased()
        let enCopias = Self.carpetasDeCopias.contains { ruta.contains($0) }
        if enCopias { s -= 4 }
        if repoQueContiene(a.ruta, c) != nil && !enCopias { s += 4 }
        return s
    }

    /// El repositorio git que contiene una ruta (sin contar las de dentro de .git).
    private func repoQueContiene(_ ruta: String, _ c: Contexto) -> String? {
        var actual = Rutas.padre(ruta)
        let home = Rutas.home.path
        while actual.count > home.count {
            if c.indice.repos.contains(actual) { return actual }
            actual = Rutas.padre(actual)
        }
        return nil
    }

    /// Librerías y ejecutables, o archivos dentro de la carpeta de un programa (runtime, bin, lib…).
    private static func esParteDeUnPrograma(_ ruta: String) -> Bool {
        let ext = (ruta as NSString).pathExtension.lowercased()
        if ["dll", "dylib", "so", "exe", "jar", "node", "pyd", "bundle", "framework"].contains(ext) { return true }
        let r = ruta.lowercased()
        return ["/runtime/", "/bin/", "/lib/", "/libs/", "/frameworks/", "/plugins/", "/resources/app/"].contains { r.contains($0) }
    }

    /// Respaldos y entregas verificadas: tienen al lado su lista de sumas (SHA256SUMS, *.sha256…).
    private static func tieneSumasDeVerificacion(_ carpeta: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: carpeta)) ?? []).contains { n in
            let l = n.lowercased()
            return l.hasPrefix("sha256sums") || l.hasPrefix("sha1sums") || l.hasPrefix("md5sums") || l.hasPrefix("checksums")
                || l.hasSuffix(".sha256") || l.hasSuffix(".sha512") || l.hasSuffix(".md5")
        }
    }

    // MARK: - Archivos olvidados

    private static let prefijosCaptura = ["captura de pantalla", "screenshot", "grabación de pantalla", "screen recording",
                                          "captura de tela", "gravação de tela", "simulator screenshot", "simulator screen recording"]
    private static let paquetesPersonales: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
                                                          "fcpbundle", "logicx", "band", "aplibrary", "photoboothlibrary", "utm", "pvm"]
    /// Bibliotecas de las apps de Apple: aunque no cambien en años, la app las usa.
    private static let bibliotecasDeApple = ["Music/Music", "Music/iTunes", "Movies/TV", "Pictures/Photo Booth Library"]

    private func olvidados(_ c: Contexto, ofrecidas: [String]) -> [Elemento] {
        var tomadas = Set(ofrecidas)
        func cubierta(_ ruta: String) -> Bool { tomadas.contains(ruta) || Totales.dentroDe(ruta, tomadas) }
        func dias(_ f: Date?) -> Double { f.map { Date().timeIntervalSince($0) / 86400 } ?? 0 }
        var r: [Elemento] = []
        func agregar(_ el: Elemento) {
            tomadas.formUnion(el.rutas.map(\.path))
            r.append(el)
        }

        // 1. Descargas que se quedaron a medias.
        for ruta in c.indice.parciales where !cubierta(ruta) {
            let url = URL(fileURLWithPath: ruta)
            let fecha = c.indice.masReciente(de: [url])
            guard dias(fecha) >= 1 else { continue }   // puede que se siga descargando
            agregar(Elemento(
                nombre: url.lastPathComponent,
                detalle: "Descarga que se quedó a medias en \(Formato.rutaCorta(url.deletingLastPathComponent())).",
                consecuencia: "Nada: el archivo está incompleto y no se puede abrir. Si lo necesitas, descárgalo otra vez.",
                rutas: [url], ultimoUso: fecha, categoria: .olvidados, riesgo: .seguro, seleccionado: true,
                motivos: [.bien("arrow.down.circle.dotted", "Incompleta",
                                "La descarga se cortó \(Formato.haceCuanto(fecha).lowercased()) y nunca terminó.")]))
        }

        // 2. Capturas y grabaciones de pantalla de hace más de un mes.
        var lugares = [Rutas.enHome("Desktop")]
        if let lugar = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let u = URL(fileURLWithPath: (lugar as NSString).expandingTildeInPath)
            if u.standardizedFileURL != lugares[0].standardizedFileURL { lugares.append(u) }
        }
        var fotos: [URL] = []
        for lugar in lugares {
            for f in Rutas.hijos(lugar) where !Rutas.esCarpeta(f) && !cubierta(f.path) {
                let n = f.lastPathComponent.lowercased()
                guard Self.prefijosCaptura.contains(where: { n.hasPrefix($0) }) else { continue }
                let usada = Fechas.ultimoUsoArchivo(f)
                guard dias(usada) >= 30 else { continue }
                if ["mov", "mp4"].contains(f.pathExtension.lowercased()) {
                    agregar(Elemento(
                        nombre: f.lastPathComponent,
                        detalle: "Grabación de pantalla en \(Formato.rutaCorta(lugar)).",
                        consecuencia: "Se borra el vídeo. Si lo grabaste para algo que aún necesitas, guárdalo antes.",
                        rutas: [f], ultimoUso: usada, categoria: .olvidados, riesgo: .revisar,
                        motivos: [.info("record.circle", "Grabación antigua", "No la abres desde \(Formato.haceCuanto(usada).lowercased()).")]))
                } else {
                    fotos.append(f)
                }
            }
        }
        if !fotos.isEmpty {
            let fechas = fotos.compactMap(Fechas.modificacion)
            agregar(Elemento(
                nombre: "\(fotos.count) \(fotos.count == 1 ? "captura" : "capturas") de pantalla antiguas",
                detalle: "Capturas de pantalla de hace más de un mes en \(Formato.lista(lugares.map { Formato.rutaCorta($0) })).",
                consecuencia: "Se borran todas. Revisa antes que no haya alguna que quieras guardar.",
                rutas: fotos, ultimoUso: fechas.max(), categoria: .olvidados, riesgo: .revisar,
                motivos: [.info("camera.viewfinder", "Capturas sueltas",
                                "Suelen hacerse para algo puntual. La más antigua es de \(Formato.haceCuanto(fechas.min()).lowercased()).")]))
        }

        // 3. Lo que está en Descargas y no abres hace más de tres meses.
        for h in Rutas.hijos(Rutas.enHome("Downloads")) where !h.lastPathComponent.hasPrefix(".") && !cubierta(h.path) {
            let usado = [Fechas.ultimoUsoSpotlight(h), c.indice.masReciente(de: [h])].compactMap { $0 }.max()
            guard dias(usado) >= 90 else { continue }
            agregar(Elemento(
                nombre: h.lastPathComponent,
                detalle: "\(Rutas.esCarpeta(h) ? "Carpeta" : "Archivo") en Descargas.",
                consecuencia: "Si te hace falta, tendrás que descargarlo otra vez (o recuperarlo de la Papelera antes de vaciarla).",
                rutas: [h], ultimoUso: usado, categoria: .olvidados, riesgo: .revisar,
                motivos: [.info("moon.zzz.fill", "Sin abrir", "No lo abres ni lo cambias desde \(Formato.haceCuanto(usado).lowercased()).")]))
        }

        // 4. Carpetas grandes que tú mismo llamaste «Eliminar», «Borrar», «Old», «Viejo», «tmp»… (también dentro de
        //    proyectos) en las que nada cambió en 3 días: el nombre dice que pensabas borrarlas o que eran de paso, pero son
        //    tus archivos. (Los tmp de las compilaciones ya los ofrece «Compilaciones».)
        let home = Rutas.home.path
        let artefactos = Set(c.indice.artefactos.map(\.ruta))
        let paraBorrar = c.indice.carpetas.filter { ruta, info in
            info.bytes >= 100_000_000 && ruta.hasPrefix(home + "/") && Self.nombreDeBorrar(Rutas.nombre(ruta))
        }
        for (ruta, info) in paraBorrar.sorted(by: { $0.key.count < $1.key.count }) where !cubierta(ruta) {
            // Solo en tus carpetas: ni en Library ni en las ocultas, ni dentro de compilaciones o dependencias descargadas.
            let partes = ruta.dropFirst(home.count + 1).split(separator: "/")
            guard partes.first != "Library", !partes.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" || $0 == "Pods" }),
                  !artefactos.contains(ruta), !Totales.dentroDe(ruta, artefactos) else { continue }
            let cambio = info.masReciente > 0 ? Date(timeIntervalSince1970: TimeInterval(info.masReciente)) : nil
            guard dias(cambio) >= 3 else { continue }
            let nombre = Rutas.nombre(ruta)
            let temporal = Self.palabraDeBorrar(nombre).map(Self.palabrasDeTemporal.contains) ?? false
            agregar(Elemento(
                nombre: nombre,
                detalle: "Carpeta en \(Formato.rutaCorta(Rutas.padre(ruta))) a la que llamaste «\(nombre)».",
                consecuencia: "Se borra la carpeta con todo lo que tiene. Va a la Papelera: puedes recuperarla antes de vaciarla.",
                rutas: [URL(fileURLWithPath: ruta)], ultimoUso: cambio, categoria: .olvidados, riesgo: .revisar,
                motivos: [temporal
                    ? .info("trash.circle", "Su nombre dice «temporal»",
                            "La llamaste «\(nombre)»: parece una carpeta de paso (pruebas, archivos a medias). Nada cambió dentro desde \(Formato.haceCuanto(cambio).lowercased()). Son tus archivos: mira lo que tiene antes de decidir.")
                    : .info("trash.circle", "Su nombre dice «borrar»",
                            "La llamaste «\(nombre)», así que quizá ya pensabas borrarla. Nada cambió dentro desde \(Formato.haceCuanto(cambio).lowercased()). Son tus archivos: mira lo que tiene antes de decidir.")],
                enUso: .rutas(nombre: nombre, raiz: ruta)))
        }

        // 5. Carpetas grandes en las que nada ha cambiado en más de un año.
        let estandar = Set(["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home + "/" + $0 })
        tomadas.formUnion(Self.bibliotecasDeApple.map { home + "/" + $0 })
        var pendientes = Rutas.hijos(Rutas.home)
            .filter { !$0.lastPathComponent.hasPrefix(".") && !["Library", "Applications", "Public"].contains($0.lastPathComponent) }
            .map(\.path)
        while let ruta = pendientes.popLast() {
            guard let info = c.indice.info(ruta), info.bytes >= 500_000_000, !cubierta(ruta) else { continue }
            // Dentro de un proyecto git, una carpeta quieta (texturas, recursos) sigue siendo parte del proyecto.
            if repoQueContiene(ruta, c) != nil { continue }
            let ext = (ruta as NSString).pathExtension.lowercased()
            if Self.paquetesPersonales.contains(ext) { continue }
            let cambio = info.masReciente > 0 ? Date(timeIntervalSince1970: TimeInterval(info.masReciente)) : nil
            if !estandar.contains(ruta), dias(cambio) >= 365 {
                agregar(Elemento(
                    nombre: Rutas.nombre(ruta),
                    detalle: "Carpeta en \(Formato.rutaCorta(Rutas.padre(ruta))) en la que nada ha cambiado en más de un año.",
                    consecuencia: "Se borra la carpeta con todo lo que tiene. Si quieres conservarla, muévela a un disco externo o a la nube.",
                    rutas: [URL(fileURLWithPath: ruta)], ultimoUso: cambio, categoria: .olvidados, riesgo: .revisar,
                    motivos: [.info("moon.zzz.fill", "Olvidada",
                                    "El último cambio dentro fue \(Formato.haceCuanto(cambio).lowercased()). Son tus archivos: decide tú.")]))
                continue
            }
            // Si la carpeta sigue viva, se busca más adentro (hasta cinco niveles).
            if ruta.split(separator: "/").count - home.split(separator: "/").count < 5 {
                pendientes += c.indice.hijosOrdenados(de: ruta).map(\.ruta)
            }
        }
        return r
    }

    /// Palabras con las que se nombra una carpeta que se piensa borrar o que solo es de paso (temporal).
    private static let palabrasDeBorrar: Set<String> = ["eliminar", "borrar", "delete", "old", "viejo", "vieja", "viejos", "viejas", "basura"]
    private static let palabrasDeTemporal: Set<String> = ["tmp", "temp", "temporal", "temporales"]

    /// «Eliminar», «Para borrar», «old-builds», «Proyecto viejo», «tmp»: como mucho tres palabras, y la primera o la última
    /// es una de `palabrasDeBorrar` o de `palabrasDeTemporal` (sin mayúsculas ni tildes).
    private static func nombreDeBorrar(_ nombre: String) -> Bool { palabraDeBorrar(nombre) != nil }

    /// La palabra de `palabrasDeBorrar` o `palabrasDeTemporal` con la que empieza o acaba el nombre, si la hay.
    private static func palabraDeBorrar(_ nombre: String) -> String? {
        let palabras = nombre.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !palabras.isEmpty, palabras.count <= 3 else { return nil }
        return [palabras[0], palabras[palabras.count - 1]].first { palabrasDeBorrar.contains($0) || palabrasDeTemporal.contains($0) }
    }

    /// Días sin abrir un archivo de iCloud Drive para ofrecer quitar su copia local.
    static let diasICloud: Double = 90

    /// Archivos de iCloud Drive que ya están en la nube, sin cambios pendientes y que nadie abre desde hace 3 meses
    /// (`Nube`): «Quitar la descarga local» libera lo que ocupan en el Mac sin borrarlos (siguen en iCloud y en su
    /// carpeta, y se vuelven a descargar al abrirlos). Seguro, solo para «Liberar al máximo» (cuesta volver a descargarlos).
    private func copiasDeICloud(_ c: Contexto) -> [Elemento] {
        // Las demás nubes (OneDrive, Google Drive, Dropbox…) se gestionan con su propia app: solo se dice cuáles hay (el
        // nombre del proveedor, sin la cuenta que lleva su carpeta).
        c.indice.otrasNubes = Array(Set(Rutas.hijos(Rutas.enHome("Library/CloudStorage")).compactMap { u -> String? in
            let n = u.lastPathComponent
            guard !n.hasPrefix("."), Rutas.esCarpeta(u) else { return nil }
            return String(n.split(separator: "-").first ?? Substring(n))
        })).sorted()
        let q = QuitarDescarga(raices: Nube.raices(), minDias: Self.diasICloud)
        guard !q.raices.isEmpty else { return [] }
        let b = Nube.buscar(q, abiertos: c.procesos.abiertos)
        guard !b.candidatos.isEmpty else { return [] }
        var quedan: [String] = []
        func n(_ x: Int, _ uno: String, _ varios: String) -> String { "\(Formato.numero(x)) \(x == 1 ? uno : varios)" }
        if b.recientes > 0 { quedan.append(n(b.recientes, "abierto", "abiertos") + " en los últimos 3 meses") }
        if b.sinSubir > 0 { quedan.append(n(b.sinSubir, "con cambios sin subir del todo (o con conflictos)", "con cambios sin subir del todo (o con conflictos)")) }
        if b.abiertos > 0 { quedan.append(n(b.abiertos, "abierto ahora", "abiertos ahora")) }
        var motivos: [Motivo] = [
            .bien("icloud.fill", "Sigue en iCloud",
                  "No se borra nada: cada archivo sigue en iCloud Drive y en su carpeta, con su nombre (con el icono de la nube). Solo se quita la copia que el Mac guarda además en el disco."),
            .bien("checkmark.icloud.fill", "Subido y sin cambios",
                  "Solo los que iCloud tiene enteros: subidos, sin cambios pendientes, sin conflictos y sin abrir desde hace 3 meses o más."),
            .info("arrow.down.circle.fill", "Se vuelve a descargar",
                  "Al abrir uno, macOS lo descarga otra vez (necesita internet). Para tenerlo siempre en el Mac: clic derecho › «Descargar ahora» o «Mantener descargado»."),
        ]
        if !quedan.isEmpty { motivos.append(.info("hand.raised.fill", "Se quedan como están", "No toco \(Formato.lista(quedan)).")) }
        return [Elemento(
            nombre: "Copias locales de iCloud Drive que no abres hace 3 meses",
            detalle: "\(Formato.numero(b.candidatos.count)) \(b.candidatos.count == 1 ? "archivo" : "archivos") de iCloud Drive que ocupan \(Formato.bytes(b.ocupan)) en el Mac y ya están en la nube.",
            consecuencia: "Siguen en iCloud y en su carpeta; el Mac deja de guardar su copia. Al abrir uno se vuelve a descargar (necesita internet). Para deshacerlo: clic derecho en la carpeta › «Descargar ahora».",
            rutas: q.raices.map { URL(fileURLWithPath: $0) }, tamanoFijo: b.ocupan, ultimoUso: b.candidatos.map(\.abierto).max(),
            categoria: .olvidados, riesgo: .seguro, seleccionado: true, accion: .quitarDescarga(q), motivos: motivos,
            dueno: "iCloud Drive", nivel: .maximo, costes: [.descarga(bytes: b.ocupan)],
            prevision: PrevisionCompresion(b.candidatos.map { .init(ruta: $0.ruta, ahorro: $0.ocupa) }, ocupan: b.ocupan))]
    }

    // MARK: - Archivos grandes

    private func grandes(_ c: Contexto, ofrecidas: [String]) -> [Elemento] {
        let instaladores: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "apk", "xapk", "ipa"]
        let comprimidos: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"]
        let yaOfrecidas = Set(ofrecidas)
        func cubierta(_ ruta: String) -> Bool { yaOfrecidas.contains(ruta) || Totales.dentroDe(ruta, yaOfrecidas) }

        var r: [Elemento] = []
        var vistos = Set<String>()
        let candidatos = c.indice.grandes + c.indice.comprimidos.filter { $0.bytes >= 20_000_000 }
        for a in candidatos where vistos.insert(a.ruta).inserted {
            let ext = a.url.pathExtension.lowercased()
            if instaladores.contains(ext) || cubierta(a.ruta) || Self.esCompaneroDeBase(a.ruta) { continue }
            let extraido = comprimidos.contains(ext) ? carpetaExtraida(a.url) : nil
            switch a.zona {
            case .personal, .compartida:
                guard a.bytes >= 50_000_000 || extraido != nil else { continue }
            case .library, .oculta:
                guard a.bytes >= 200_000_000, !a.ruta.contains("/com.apple.") else { continue }
            case .sistema:
                continue   // ya están en «Temporales del sistema»
            }

            let tipo = describirTipo(ext)
            var motivos: [Motivo] = []
            var riesgo = Riesgo.cuidado
            var detalle = "\(tipo) en \(Formato.rutaCorta(a.carpeta))."
            var consecuencia = "Se borra el archivo. Si te arrepientes, puedes recuperarlo de la Papelera antes de vaciarla."
            var dueno: String? = nil

            if a.zona == .library || a.zona == .oculta {
                dueno = duenoDeRuta(a.ruta, c)
                let quien = dueno ?? "una app"
                detalle = "Archivo interno de \(quien) (\(tipo.lowercased()))."
                consecuencia = "\(quien) puede fallar o tener que volver a descargarlo."
                motivos.append(.aviso("app.badge.fill", "Datos de \(quien)",
                                      "Es parte de los datos de \(quien). Revisa desde la propia app si puedes liberarlo."))
            }
            if a.ruta.contains("/Music/Music/") || a.ruta.contains("/iTunes/") {
                motivos.append(.aviso("music.note", "Biblioteca de Música",
                                      "Está dentro de la biblioteca de la app Música: si lo borras aquí, la canción quedará rota en la app. Mejor bórrala desde Música."))
            }
            if let extraido {
                motivos.append(.bien("archivebox.fill", "Ya descomprimido", "Ya existe la carpeta «\(extraido)» con su contenido."))
                riesgo = .revisar
                consecuencia = "La carpeta «\(extraido)» se queda; solo se borra el archivo comprimido."
            }
            r.append(Elemento(
                nombre: a.nombre, detalle: detalle, consecuencia: consecuencia, rutas: Self.conCompaneros(a.url),
                ultimoUso: Fechas.ultimoUsoArchivo(a.url) ?? a.fecha, categoria: .grandes, riesgo: riesgo,
                motivos: motivos, dueno: dueno))
        }

        // Copias de seguridad de iPhone/iPad (solo se ven con Acceso total al disco).
        for b in Rutas.hijos(Rutas.enHome("Library/Application Support/MobileSync/Backup")) where Rutas.esCarpeta(b) {
            let info = NSDictionary(contentsOf: b.appendingPathComponent("Info.plist"))
            let nombre = info?["Device Name"] as? String ?? "iPhone/iPad"
            r.append(Elemento(
                nombre: "Copia de seguridad de \(nombre)",
                detalle: "Copia local completa de un dispositivo.",
                consecuencia: "Si pierdes o cambias el dispositivo, no podrás restaurarlo desde esta copia.",
                rutas: [b], ultimoUso: info?["Last Backup Date"] as? Date, categoria: .grandes, riesgo: .cuidado,
                motivos: [.aviso("iphone", "Copia de seguridad", "Bórrala solo si ya tienes otra copia (por ejemplo, en iCloud).")]))
        }
        return r
    }

    /// Si al lado de «fotos.zip» existe la carpeta «fotos», ya se descomprimió.
    private func carpetaExtraida(_ url: URL) -> String? {
        var base = url.deletingPathExtension()
        if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        return Rutas.esCarpeta(base) ? base.lastPathComponent : nil
    }

    private func describirTipo(_ ext: String) -> String {
        switch ext {
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "mts": return "Vídeo"
        case "mp3", "m4a", "wav", "aiff", "flac", "aac": return "Audio"
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst": return "Archivo comprimido"
        case "vmdk", "vdi", "qcow2", "img", "raw", "utm", "hdd": return "Disco virtual"
        case "gguf", "safetensors", "onnx", "mlmodel", "pt", "pth", "ckpt": return "Modelo de IA"
        case "sqlite", "db", "realm": return "Base de datos"
        case "pdf", "psd", "ai", "key", "pages", "numbers", "docx", "xlsx", "pptx": return "Documento"
        case "jpg", "jpeg", "heic", "png", "tiff", "dng": return "Imagen"
        default: return "Archivo"
        }
    }

    private func duenoDeRuta(_ ruta: String, _ c: Contexto) -> String? {
        let home = Rutas.home.path
        for base in ["/Library/Application Support/", "/Library/Containers/", "/Library/Caches/", "/Library/Group Containers/"] {
            let prefijo = home + base
            if ruta.hasPrefix(prefijo), let carpeta = ruta.dropFirst(prefijo.count).split(separator: "/").first {
                return c.apps.nombreApp(para: String(carpeta)) ?? String(carpeta)
            }
        }
        if ruta.hasPrefix(home + "/."), let carpeta = ruta.dropFirst(home.count + 2).split(separator: "/").first {
            return String(carpeta)
        }
        return nil
    }

    // MARK: - Comprimir sin borrar

    /// Lo que se puede guardar comprimido con la compresión transparente de APFS (ver `Compresor`): las conversaciones de
    /// Codex y Claude Code y los programas de herramientas y del SDK de Android que llevan días sin cambiar. No se borra
    /// nada, así que es Seguro y se marca solo; cada archivo se elige con las reglas de `Compresor.buscar` (sin lo
    /// abierto, lo reciente, los clones, lo que ya viene comprimido…) y al limpiar se vuelve a comprobar uno por uno.
    private func compresibles(_ c: Contexto) -> [Elemento] {
        struct Grupo {
            let nombre: String
            let que: String
            let dueno: String
            let compresion: Compresion
            var enUso: EnUso? = nil
        }
        let casa = { (rel: String) in Rutas.enHome(rel).path }
        let sdk = sdkAndroid(c).path
        let grupos = [
            Grupo(nombre: "Comprimir conversaciones de Codex",
                  que: "Las conversaciones que guardó Codex (sessions y archived_sessions) y que llevan 3 días o más sin cambios",
                  dueno: "Codex",
                  compresion: Compresion(raices: [casa(".codex/sessions"), casa(".codex/archived_sessions")], minDias: 3)),
            Grupo(nombre: "Comprimir transcripciones de Claude Code",
                  que: "Las transcripciones de las sesiones de Claude Code (~/.claude/projects) que llevan 7 días o más sin cambios",
                  dueno: "Claude Code",
                  compresion: Compresion(raices: [casa(".claude/projects")], minDias: 7, extensiones: ["jsonl"])),
            Grupo(nombre: "Comprimir runtimes y programas de herramientas",
                  que: "Programas, librerías y versiones de lenguajes que instalaron tus herramientas (Node, Python, Java, Rust, Codex, Cursor, Claude Code…) y que llevan 7 días o más sin cambios",
                  dueno: "Herramientas",
                  compresion: Compresion(raices: [".local/runtime", ".local/bin", ".local/share/uv/python", ".local/share/cursor-agent",
                                                  ".local/share/fnm/node-versions", ".codex/packages", ".codex/plugins",
                                                  ".cache/codex-runtimes", "Library/Application Support/Claude/claude-code",
                                                  "Library/Java/JavaVirtualMachines", ".nvm/versions", ".pyenv/versions",
                                                  ".rustup/toolchains", ".volta/tools/image", ".sdkman/candidates", ".gradle/jdks"].map(casa),
                                         minDias: 7)),
            Grupo(nombre: "Comprimir el SDK de Android",
                  que: "Las plataformas, build-tools, el emulador, el NDK y las imágenes del sistema del SDK de Android (las de más de 512 MiB se quedan como están) que llevan 7 días o más sin cambios",
                  dueno: "Android Studio",
                  compresion: Compresion(raices: ["platforms", "build-tools", "emulator", "sources", "ndk", "ndk-bundle", "cmake",
                                                  "system-images"].map { sdk + "/" + $0 }, minDias: 7),
                  // Mientras el emulador funciona usa sus imágenes y sus librerías: no se toca nada del SDK.
                  enUso: .programas(nombre: "El emulador de Android",
                                    ejecutables: ["emulator", "qemu-system-aarch64", "qemu-system-aarch64-headless",
                                                  "qemu-system-x86_64", "qemu-system-x86_64-headless"])),
        ]
        // Las cuatro búsquedas a la vez: leen una muestra de miles de archivos para estimar cuánto se ahorra.
        final class Caja: @unchecked Sendable { var busquedas: [Int: Compresor.Busqueda] = [:] }
        let caja = Caja()
        let candado = NSLock()
        let abiertos = c.procesos.abiertos
        let compresiones = grupos.map { g in
            Compresion(raices: g.compresion.raices.filter { Rutas.existe($0) && Seguridad.sePuedeModificar(URL(fileURLWithPath: $0)) },
                       minDias: g.compresion.minDias, extensiones: g.compresion.extensiones)
        }
        DispatchQueue.concurrentPerform(iterations: compresiones.count) { i in
            let b = compresiones[i].raices.isEmpty ? Compresor.Busqueda() : Compresor.buscar(compresiones[i], abiertos: abiertos)
            candado.lock()
            caja.busquedas[i] = b
            candado.unlock()
        }

        var r: [Elemento] = []
        for (i, g) in grupos.enumerated() {
            guard let b = caja.busquedas[i], !b.candidatos.isEmpty else { continue }
            r.append(Elemento(
                nombre: g.nombre,
                detalle: "\(g.que): \(Formato.numero(b.candidatos.count)) \(b.candidatos.count == 1 ? "archivo" : "archivos") que ocupan \(Formato.bytes(b.ocupan)).",
                consecuencia: "No se borra nada: ocupan menos y se leen igual. Si un programa vuelve a escribir en uno, macOS lo descomprime solo, así que no hace falta deshacerlo. Comprimir gasta un rato de procesador (en las pruebas, unos 10 segundos por cada 2 GB) y lo puedes detener cuando quieras: lo que esté a medias se queda como estaba.",
                rutas: compresiones[i].raices.map { URL(fileURLWithPath: $0) },
                tamanoFijo: b.ahorro, ultimoUso: b.masReciente, categoria: .comprimir, riesgo: .seguro, seleccionado: true,
                accion: .comprimir(compresiones[i]), motivos: Self.motivosDeCompresion(b, dias: g.compresion.minDias),
                enUso: g.enUso, dueno: g.dueno, costes: [.tiempoCPU],
                prevision: PrevisionCompresion(b.candidatos.map { .init(ruta: $0.ruta, ahorro: $0.ahorro) }, ocupan: b.ocupan)))
        }
        return r + appsComprimibles(c)
    }

    /// «Sin borrar nada», el ahorro estimado y lo que se queda como está (y por qué) de una búsqueda de `Compresor`.
    private static func motivosDeCompresion(_ b: Compresor.Busqueda, dias minDias: Double, grandes: Bool = false) -> [Motivo] {
        let dias = Int(minDias)
        var motivos: [Motivo] = [
            .bien("rectangle.compress.vertical", "Sin borrar nada",
                  "Se guardan con la compresión de APFS, la misma con la que macOS guarda sus propias apps: el contenido no cambia y se leen igual. Cada archivo se copia comprimido, se comprueba byte a byte y solo entonces se cambia por el original."),
            .info("gauge.with.dots.needle.33percent", "Ahorro estimado",
                  "Comprimí una muestra de cada archivo: de los \(Formato.bytes(b.ocupan)) que ocupan \(Formato.numero(b.candidatos.count)) archivos se ahorran unos \(Formato.bytes(b.ahorro)). Al terminar te digo lo ahorrado de verdad."),
        ]
        var quedan: [String] = []
        func n(_ x: Int, _ uno: String, _ varios: String) -> String { "\(Formato.numero(x)) \(x == 1 ? uno : varios)" }
        if b.recientes > 0 { quedan.append(n(b.recientes, "con cambios", "con cambios") + " de hace menos de \(dias == 1 ? "un día" : "\(dias) días")") }
        if b.abiertos > 0 { quedan.append(n(b.abiertos, "abierto ahora o en marcha", "abiertos ahora o en marcha")) }
        if b.grandes > 0 {
            // Con pocos, se nombran («app.asar (562 MB)»).
            let cuales = grandes && b.nombresGrandes.count <= 3
                ? ": " + Formato.lista(b.nombresGrandes.map { "\($0.nombre) (\(Formato.bytes($0.bytes)))" }) : " (\(Formato.bytes(b.bytesGrandes)))"
            quedan.append(n(b.grandes, "de más de 512 MiB", "de más de 512 MiB") + "\(cuales), demasiado \(b.grandes == 1 ? "grande" : "grandes") para comprimir\(b.grandes == 1 ? "lo" : "los") así")
        }
        if b.compartidos > 0 {
            quedan.append(n(b.compartidos, "que comparte espacio con una copia", "que comparten espacio con una copia") + " (clones o enlaces duros: comprimidos ocuparían más)")
        }
        if b.noRentan > 0 { quedan.append(n(b.noRentan, "que casi no ahorra nada", "que casi no ahorran nada")) }
        if b.yaComprimidos > 0 { quedan.append(n(b.yaComprimidos, "que ya estaba comprimido", "que ya estaban comprimidos") + " (\(Formato.bytes(b.bytesYaComprimidos)))") }
        if !quedan.isEmpty {
            motivos.append(.info("hand.raised.fill", "Se quedan como están", "No toco \(Formato.lista(quedan))."))
        }
        return motivos
    }

    /// Lo mínimo que tiene que ahorrar comprimir una app: un 15 % de lo que ocupa (si no, no compensa pedir el permiso ni
    /// tocarla) y al menos 10 MB.
    static let ahorroMinimoApps = 0.15

    /// Las apps tuyas que llevan un día o más sin actualizarse y que comprimidas ocupan bastante menos (E11): «Comprimir
    /// <App>», Seguro (no se borra ni se cambia nada: se leen igual y su firma sigue valiendo) y solo para «Liberar al
    /// máximo» (nivel .maximo). Necesita que la app esté cerrada y que ningún actualizador esté trabajando, y el permiso
    /// «Gestión de apps». No entran: las de Apple, las de la App Store, las de otro dueño (root: E16), las que ya vienen
    /// comprimidas en un 50 % o más y las que se actualizaron hace menos de un día (puede que a medias).
    private func appsComprimibles(_ c: Contexto) -> [Elemento] {
        let apps = AppsPropias.candidatas()
        final class Caja: @unchecked Sendable { var busquedas: [Int: Compresor.Busqueda] = [:] }
        let caja = Caja()
        let candado = NSLock()
        let abiertos = c.procesos.abiertos
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let b = Compresor.buscar(Compresion(raices: [apps[i].ruta], minDias: 1, apps: true), abiertos: abiertos)
            candado.lock()
            caja.busquedas[i] = b
            candado.unlock()
        }
        var r: [Elemento] = []
        for (i, app) in apps.enumerated() {
            guard let b = caja.busquedas[i], !b.candidatos.isEmpty, b.recientes == 0, b.bytesVistos > 0,
                  Double(b.tamanoYaComprimido) < 0.5 * Double(b.tamanoVisto),
                  Double(b.ahorro) >= Self.ahorroMinimoApps * Double(b.bytesVistos), b.ahorro >= 10_000_000 else { continue }
            var motivos = Self.motivosDeCompresion(b, dias: 1, grandes: true)
            motivos.insert(.bien("checkmark.seal.fill", "Su firma sigue valiendo",
                                 "La firma de una app comprueba su contenido, no cómo se guarda, y comprimirla no cambia ni un byte (WhatsApp y Xcode ya vienen así). Aun así compruebo su firma antes y después; si fallara, la descomprimo sola al momento."), at: 1)
            motivos.append(b.faltaPermiso
                ? .info("lock.app.dashed", "Necesita tu permiso",
                        "macOS todavía no deja a LimpiadorMac modificar apps (el permiso «Gestión de apps»). Al limpiar lo intento con un solo archivo: si macOS no lo deja, no toco nada más de la app y te digo dónde activarlo (Ajustes › Privacidad y seguridad › Gestión de apps).")
                : .info("lock.app.dashed", "Permiso «Gestión de apps»",
                        "Ahora macOS deja modificar esta app. Si al limpiar no lo deja (falta el permiso «Gestión de apps»), lo intento con un solo archivo, paro sin tocar nada más y te digo dónde activarlo."))
            motivos.append(.info("arrow.triangle.2.circlepath", "Al actualizarse",
                                 "Lo que traiga una actualización llega sin comprimir: la app vuelve a ocupar lo de antes y el próximo análisis la vuelve a ofrecer."))
            r.append(Elemento(
                nombre: "Comprimir \(app.nombre)",
                detalle: "La app \(app.nombre)\(app.version.map { " \($0)" } ?? "") (\(Formato.rutaCorta(app.ruta))): \(Formato.numero(b.candidatos.count)) \(b.candidatos.count == 1 ? "archivo" : "archivos") que ocupan \(Formato.bytes(b.ocupan)) de los \(Formato.bytes(b.bytesVistos)) de la app.",
                consecuencia: "No se borra nada ni cambia ningún archivo: la app se abre y funciona igual, y su firma sigue siendo válida (la compruebo antes y después). Solo se comprime cerrada; tarda un rato de procesador y lo puedes detener. Al actualizarse vuelve a ocupar lo de antes. Si después no se abre bien, la descomprimes en Análisis › Descomprimir una app.",
                rutas: [URL(fileURLWithPath: app.ruta)], tamanoFijo: b.ahorro, ultimoUso: b.masReciente, categoria: .comprimir,
                riesgo: .seguro, seleccionado: true, accion: .comprimir(Compresion(raices: [app.ruta], minDias: 1, apps: true)),
                motivos: motivos, enUso: .appInstalada(nombre: app.nombre, id: app.id, ruta: app.ruta), dueno: app.nombre,
                nivel: .maximo, costes: [.seDeshaceAlActualizar(app: app.nombre), .tiempoCPU],
                prevision: PrevisionCompresion(b.candidatos.map { .init(ruta: $0.ruta, ahorro: $0.ahorro) }, ocupan: b.ocupan)))
        }
        return r
    }

    /// Nombres de las carpetas de material propio: entregas, resultados e informes (y los «reports» de una compilación).
    private static let carpetasDeMaterial: Set<String> = ["entrega", "entregas", "resultados", "results", "informes", "deliverables"]

    /// Tu material grande que el análisis no marca (informes de pruebas en build/reports, entregas, resultados): «Comprimir
    /// <carpeta> de <proyecto>», Seguro (no se borra nada) y solo para «Liberar al máximo». Carpetas de 100 MB o más de tus
    /// carpetas que no se ofrecen ya para borrar como Seguro (`seguras`); dentro solo se comprimen los archivos sin
    /// cambios en 7 días, y nunca emuladores, bases de datos ni lo que ya viene comprimido (imágenes, APK, zip…).
    private func materialPropio(_ c: Contexto, seguras: [String]) -> [Elemento] {
        let casa = Rutas.home.path + "/"
        let yaSeguras = Set(seguras)
        var elegidas: [String] = []
        for (ruta, info) in c.indice.carpetas where info.bytes >= 100_000_000 && ruta.hasPrefix(casa) {
            let dentro = ruta.dropFirst(casa.count)
            // Solo en tus carpetas: ni en Library ni en carpetas ocultas, apps, dependencias o git.
            guard !dentro.hasPrefix("Library/"), !dentro.split(separator: "/").contains(where: {
                $0.hasPrefix(".") || $0.hasSuffix(".app") || $0 == "node_modules"
            }) else { continue }
            let nombre = Rutas.nombre(ruta).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            let deCompilacion = nombre == "reports" && Rutas.nombre(Rutas.padre(ruta)) == "build"
            guard deCompilacion || Self.carpetasDeMaterial.contains(nombre),
                  !yaSeguras.contains(ruta), !Totales.dentroDe(ruta, yaSeguras),
                  Seguridad.sePuedeModificar(URL(fileURLWithPath: ruta)) else { continue }
            elegidas.append(ruta)
        }
        // Las de dentro de otra elegida van con ella.
        let todas = Set(elegidas)
        elegidas = elegidas.filter { !Totales.dentroDe($0, todas) }.sorted()
        final class Caja: @unchecked Sendable { var busquedas: [Int: Compresor.Busqueda] = [:] }
        let caja = Caja()
        let candado = NSLock()
        let abiertos = c.procesos.abiertos
        let lista = elegidas
        DispatchQueue.concurrentPerform(iterations: lista.count) { i in
            let b = Compresor.buscar(Compresion(raices: [lista[i]], minDias: 7), abiertos: abiertos)
            candado.lock()
            caja.busquedas[i] = b
            candado.unlock()
        }
        var r: [Elemento] = []
        for (i, ruta) in lista.enumerated() {
            guard let b = caja.busquedas[i], b.ahorro >= 10_000_000 else { continue }
            // «build/reports de ProyectoMayda», «entrega de FotoTextoAndroid».
            var proyecto = Rutas.padre(ruta)
            var carpeta = Rutas.nombre(ruta)
            if Rutas.nombre(proyecto) == "build" {
                carpeta = "build/" + carpeta
                proyecto = Rutas.padre(proyecto)
            }
            let deQuien = Rutas.nombre(proyecto)
            var motivos = Self.motivosDeCompresion(b, dias: 7)
            motivos.insert(.info("folder.fill.badge.person.crop", "Tu material",
                                 "Son informes, resultados o entregas tuyas: no los marco nunca para borrar. Comprimidos siguen en su sitio y se leen igual. Lo que ya viene comprimido (imágenes, vídeos, APK, zip), las bases de datos y los emuladores se quedan como están."), at: 1)
            r.append(Elemento(
                nombre: "Comprimir \(carpeta) de \(deQuien)",
                detalle: "\(Formato.rutaCorta(ruta)): \(Formato.numero(b.candidatos.count)) \(b.candidatos.count == 1 ? "archivo" : "archivos") sin cambios en 7 días o más que ocupan \(Formato.bytes(b.ocupan)).",
                consecuencia: "No se borra nada: tus archivos siguen en su sitio, con su nombre y sus fechas, y se leen igual. Si vuelves a escribir en uno, macOS lo descomprime solo. Tarda un rato de procesador y lo puedes detener.",
                rutas: [URL(fileURLWithPath: ruta)], tamanoFijo: b.ahorro, ultimoUso: b.masReciente, categoria: .comprimir,
                riesgo: .seguro, seleccionado: true, accion: .comprimir(Compresion(raices: [ruta], minDias: 7)),
                motivos: motivos, dueno: deQuien, nivel: .maximo, costes: [.tiempoCPU],
                prevision: PrevisionCompresion(b.candidatos.map { .init(ruta: $0.ruta, ahorro: $0.ahorro) }, ocupan: b.ocupan)))
        }
        return r
    }

    // MARK: - Utilidades

    /// "com.google.Chrome" -> "Chrome (com.google.Chrome)"
    private func nombreBonito(_ n: String) -> String {
        let partes = n.split(separator: ".")
        if partes.count >= 3, let ultima = partes.last { return "\(ultima) (\(n))" }
        return n
    }
}
