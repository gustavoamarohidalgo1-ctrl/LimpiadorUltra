import AppKit
import Foundation

/// Borra (o comprime) lo que el usuario seleccionó. Antes de tocar cada elemento vuelve a comprobar que sea seguro:
/// rutas protegidas, apps abiertas, emuladores encendidos y programas con archivos abiertos dentro.
enum Limpiador {
    /// Cada cuántos segundos se vuelve a mirar qué está funcionando mientras se limpia (git gc o una carpeta
    /// enorme pueden tardar minutos, y mientras tanto se puede abrir una app).
    private static let vigenciaProcesos: TimeInterval = 3

    /// `cancelado` se consulta antes de cada elemento y, al comprimir, antes de cada lote: si devuelve true, lo que
    /// quedaba no se toca. `capturar` y `libre` solo se cambian en las pruebas, para simular lo que está funcionando y el
    /// espacio libre que ve git antes de compactar.
    ///
    /// Con `maximo` («Liberar al máximo») se limpia como en el modo definitivo y en este orden: los comandos oficiales, lo
    /// Seguro de mayor a menor (sin pasar por la Papelera), lo de Revisar o Cuidado que elegiste a mano (a la Papelera),
    /// comprimir y unir copias. Antes de cada elemento se vuelve a comprobar que nada lo use y que no haya cambiado.
    ///
    /// Antes de nada se recoge lo que dejó una compresión o una unión que se cortó (`recogerRestos`), se limpie lo que se
    /// limpie; `raicesConRestos` son las carpetas en las que el análisis vio restos (`Indice.raicesConRestos`).
    static func limpiar(_ elementos: [Elemento], modo modoPedido: ModoLimpieza, maximo: Bool = false,
                        raicesConRestos: [String] = [],
                        progreso: @Sendable (Double, String) -> Void,
                        cancelado: () -> Bool = { false },
                        capturar: () -> Procesos = { Procesos.capturar() },
                        libre: () -> Int64 = { InfoDisco.libreAhora() }) -> ResultadoLimpieza {
        let fm = FileManager.default
        let modo: ModoLimpieza = maximo ? .definitivo : modoPedido
        // Primero, lo que dejó una compresión o una unión que se cortó (se colgó la app, se cerró de golpe, se apagó el
        // Mac): solo se borra lo que está repetido, y antes de medir el disco (no es parte de esta limpieza).
        let restos = recogerRestos(elementos, ademas: raicesConRestos, progreso: progreso)
        // Lo liberado se mide en el disco (libre de verdad, sin lo purgable) y además se calcula, para explicar
        // las diferencias: otros programas escribiendo, clones que se quedan, instantáneas de Time Machine.
        let libreAntes = InfoDisco.libreAhora()
        let instantaneas = Instantaneas.locales() ?? 0
        var eliminadas: [(String, Int64)] = []   // rutas eliminadas para siempre y lo que liberan
        var liberadoAparte: Int64 = 0           // simuladores, Papelera y git: lo que liberan sin pasar por rutas
        var enPapelera: Int64 = 0
        var procesos = capturar()
        if !procesos.fiable { procesos = capturar() }   // un fallo pasajero de ps: se intenta otra vez
        var capturados = Date()
        var errores: [String] = restos.avisos
        var omitidos: [String] = []
        var movimientos: [Movimiento] = []
        var registro: [String] = []
        var limpiados = 0
        var forzados = 0
        var appsAPapelera = 0
        var bytes: Int64 = 0
        var exitosos = Set<Elemento.ID>()
        var comprimido: Int64 = 0
        var unido: Int64 = 0
        var quitadoDeICloud: Int64 = 0
        var appsComprimidas: [String] = []
        var sinPermisoApps = false
        var detenido = false
        var sinTerminar: [String] = []

        // Vaciar la Papelera va primero: después se llevaría por delante lo que esta misma limpieza acaba de mover allí.
        // Después, los comandos oficiales (brew cleanup…), que ya dejan su parte hecha. Comprimir y unir copias van al
        // final: lo que se borra antes ya no hace falta cambiarlo. Y unir, después de comprimir: así las copias heredan
        // la compresión del original (comprimir un clon después rompería los bloques que comparte).
        let esComando = { (el: Elemento) in el.accion.lineaDeComando != nil }
        var borrar = elementos.filter { $0.accion != .vaciarPapelera && !esComando($0) && !$0.accion.noBorraNada }
        if maximo {
            // Lo Seguro primero y de mayor a menor (lo grande libera sitio pronto, y comprimir necesita margen); lo de
            // Revisar o Cuidado, que va a la Papelera, después.
            borrar.sort { a, b in
                a.riesgo == .seguro && b.riesgo != .seguro
                    || (a.riesgo == .seguro) == (b.riesgo == .seguro) && a.bytesLiberables > b.bytesLiberables
            }
        }
        let ordenados = elementos.filter { $0.accion == .vaciarPapelera }
            + elementos.filter(esComando)
            + borrar
            + elementos.filter { $0.accion.noBorraNada && !$0.accion.une }
            + elementos.filter { $0.accion.une }
        // Las copias que se van a cambiar por un clon de otra no se comprimen antes: dejarían de estarlo al unirlas.
        let aUnir = Set(elementos.flatMap { el -> [String] in
            if case .clonar(let union) = el.accion { return union.copias.map(\.ruta) }
            return []
        })
        // Lo que esta limpieza borra o manda a la Papelera: una copia que esté ahí no vale para borrar lo de /tmp que la
        // necesita (luego se vaciaría la Papelera y no quedaría ninguna).
        let quitadas = Set(elementos.filter { $0.accion == .borrar }.flatMap { $0.rutas.map(\.path) })
        for (i, el) in ordenados.enumerated() {
            progreso(Double(i) / Double(max(elementos.count, 1)), el.nombre)
            // Se pidió detener: lo ya hecho se queda hecho y lo demás no se empieza.
            if detenido || cancelado() {
                detenido = true
                sinTerminar.append(el.nombre)
                continue
            }

            // Comprobación de último momento: puede que una app se haya abierto, o que un programa haya abierto algo
            // de aquí, después del análisis. Si hace unos segundos que se miró, se vuelve a mirar.
            if Date().timeIntervalSince(capturados) > vigenciaProcesos {
                procesos = capturar()
                capturados = Date()
            }
            // Sin saber qué está funcionando no se toca nada: podría estar en uso.
            guard procesos.fiable else {
                omitidos.append("\(el.nombre): no pude comprobar qué programas están funcionando, así que no lo toqué. Vuelve a limpiar en un momento.")
                continue
            }
            if let quien = procesos.quienUsa(el) {
                omitidos.append("\(el.nombre): \(quien) lo está usando. Ciérralo y vuelve a limpiar.")
                continue
            }
            // Lo que solo se ofrece por llevar un tiempo quieto (intermedios de compilación, transformaciones de Gradle):
            // si algo cambió dentro después del análisis, se está usando otra vez.
            if let analizado = el.cambioAnalizado, el.accion == .borrar {
                let limite = Int(analizado.timeIntervalSince1970)
                if Fechas.ultimoCambio(el.rutas.map(\.path), despuesDe: limite) > limite {
                    omitidos.append("\(el.nombre): algo cambió dentro después del análisis (¿se está compilando?). Vuelve a analizar y limpia otra vez.")
                    continue
                }
            }
            // Lo de /tmp que se ofreció porque sus resultados también están en tus carpetas: esas copias tienen que seguir
            // ahí, iguales, y no irse con esta misma limpieza. Si no, sus resultados serían lo único que queda.
            if let falta = el.copiasExigidas.first(where: { c in quitadas.contains(c.ruta) || Totales.dentroDe(c.ruta, quitadas) }) {
                omitidos.append("\(el.nombre): la copia de \(Rutas.nombre(falta.de)) que hay en \(Formato.rutaCorta(Rutas.padre(falta.ruta))) también se limpia ahora, así que no lo toqué (sería lo único que queda). Vuelve a analizar.")
                continue
            }
            if let falta = el.copiasExigidas.first(where: { !$0.sigueIgual }) {
                omitidos.append("\(el.nombre): \(Rutas.nombre(falta.de)) ya no tiene su copia en \(Formato.rutaCorta(Rutas.padre(falta.ruta))) (se borró o cambió), así que no lo toqué. Vuelve a analizar.")
                continue
            }
            // Lo que no es 100 % seguro nunca se elimina sin pasar por la Papelera.
            let modoElemento: ModoLimpieza = (modo == .definitivo && el.riesgo != .seguro) ? .papelera : modo
            if modoElemento != modo && el.accion == .borrar { forzados += 1 }

            var ok = true
            var liberado = el.tamano
            switch el.accion {
            case .borrar:
                if let disco = el.imagenMontada {
                    Shell.ejecutar("/usr/bin/hdiutil", ["detach", disco, "-quiet"], limite: 30)
                }
                for (j, url) in el.rutas.enumerated() {
                    guard Rutas.existe(url) else { continue }
                    guard Seguridad.sePuedeBorrar(url) else {
                        errores.append("\(Formato.rutaCorta(url)): ruta protegida, no se tocó.")
                        ok = false
                        continue
                    }
                    if url.path.contains("/Library/LaunchAgents/") {
                        // Se descarga el agente para que deje de intentar arrancar.
                        Shell.ejecutar("/bin/launchctl", ["bootout", "gui/\(getuid())", url.path], limite: 10)
                    }
                    let tamano = j < el.tamanosRutas.count ? el.tamanosRutas[j] : 0
                    // Lo que se libera al eliminarla: sin lo que comparte con clones que se quedan.
                    let libera = el.liberable(ruta: j)
                    // Una app nunca se elimina para siempre, ni en «Liberar al máximo»: va a la Papelera. Puede ser una
                    // versión que guardaste a propósito, y no se vuelve a descargar igual.
                    let modoRuta: ModoLimpieza = Self.esApp(url) ? .papelera : modoElemento
                    if modoRuta != modoElemento { appsAPapelera += 1 }
                    do {
                        if modoRuta == .papelera {
                            var destinoEnPapelera: NSURL?
                            try fm.trashItem(at: url, resultingItemURL: &destinoEnPapelera)
                            if let destino = destinoEnPapelera?.path {
                                movimientos.append(Movimiento(original: url.path, enPapelera: destino, nombre: el.nombre, bytes: tamano).identificado())
                            }
                            enPapelera += tamano
                        } else {
                            try fm.removeItem(at: url)
                            eliminadas.append((url.path, libera))
                        }
                        registro.append("\(modoRuta == .papelera ? "papelera" : "eliminado")\t\(tamano)\t\(url.path)")
                    } catch {
                        if Self.esApp(url) {
                            // Una app instalada con un instalador es del sistema: como el Finder, macOS pide la contraseña.
                            // Nunca se vacía por dentro: quedaría rota.
                            if modoRuta == .papelera, let destino = reciclar(url) {
                                movimientos.append(Movimiento(original: url.path, enPapelera: destino.path, nombre: el.nombre, bytes: tamano).identificado())
                                registro.append("papelera\t\(tamano)\t\(url.path)")
                                enPapelera += tamano
                            } else {
                                errores.append("\(url.lastPathComponent): macOS no me dejó moverla. Arrástrala a la Papelera desde Finder.")
                                ok = false
                            }
                            continue
                        }
                        // Algunas carpetas no se pueden mover enteras (permisos): se intenta con su contenido.
                        let parcial = vaciarContenido(de: url, modo: modoElemento)
                        movimientos += parcial.movimientos.map {
                            Movimiento(original: $0.0, enPapelera: $0.1, nombre: el.nombre, bytes: 0).identificado()
                        }
                        if !parcial.completo {
                            errores.append("\(Formato.rutaCorta(url)): \(error.localizedDescription)")
                            ok = false
                        } else if modoElemento == .papelera {
                            enPapelera += tamano
                        } else {
                            eliminadas.append((url.path, libera))
                        }
                    }
                }
            case .eliminarSimulador(let udid):
                ok = Shell.ejecutar("/usr/bin/xcrun", ["simctl", "delete", udid], limite: 120).estado == 0
                if ok { registro.append("simulador eliminado\t\(el.tamano)\t\(udid)") }
                else { errores.append("\(el.nombre): no se pudo eliminar el simulador.") }
            case .vaciarSimulador(let udid):
                Shell.ejecutar("/usr/bin/xcrun", ["simctl", "shutdown", udid], limite: 60)
                ok = Shell.ejecutar("/usr/bin/xcrun", ["simctl", "erase", udid], limite: 120).estado == 0
                if ok { registro.append("simulador vaciado\t\(el.tamano)\t\(udid)") }
                else { errores.append("\(el.nombre): no se pudo borrar (¿está abierto el simulador?).") }
            case .eliminarRuntime(let id):
                ok = Shell.ejecutar("/usr/bin/xcrun", ["simctl", "runtime", "delete", id], limite: 300).estado == 0
                if ok { registro.append("sistema iOS eliminado\t\(el.tamano)\t\(id)") }
                else { errores.append("\(el.nombre): Xcode no pudo eliminarlo. Prueba desde Xcode › Ajustes › Componentes.") }
            case .vaciarPapelera:
                ok = vaciarPapelera()
                if ok { registro.append("papelera vaciada\t\(el.tamano)\t~/.Trash") }
                else { errores.append("No se pudo vaciar toda la Papelera. Dale Acceso total al disco a LimpiadorMac.") }
            case .compactarGit(let repo):
                // Si git está trabajando en el proyecto (commit, pull…), no se toca.
                if Rutas.existe(repo + "/.git/index.lock") || Rutas.existe(repo + "/.git/gc.pid") {
                    omitidos.append("\(el.nombre): git está trabajando en ese proyecto. Vuelve a limpiar cuando termine.")
                    continue
                }
                // Git escribe el historial empaquetado entero antes de borrar lo suelto: tiene que caber todo, con margen.
                let cuenta = HistorialGit.cuenta(repo)
                let necesario = ((cuenta["size"] ?? 0) + (cuenta["size-pack"] ?? 0)) * 1024 + 1_000_000_000
                guard libre() >= necesario else {
                    omitidos.append("\(el.nombre): para compactarlo hacen falta unos \(Formato.bytes(necesario)) libres (git escribe el historial empaquetado antes de borrar el suelto) y ahora no los hay. Libera otra cosa antes y vuelve a intentarlo.")
                    continue
                }
                let git = URL(fileURLWithPath: repo + "/.git")
                let paquetes = repo + "/.git/objects/pack"
                let temporalesPrevios = Set(HistorialGit.temporales(en: paquetes))
                let antes = Tamanos.de(git)
                // Solo empaqueta: sin podar commits inalcanzables, el reflog ni los worktrees (eso sí borraría cosas).
                let sinPodar = ["-c", "gc.pruneExpire=never", "-c", "gc.reflogExpire=never", "-c", "gc.reflogExpireUnreachable=never",
                                "-c", "gc.worktreePruneExpire=never", "-c", "gc.rerereResolved=never", "-c", "gc.rerereUnresolved=never"]
                let r = Shell.comando("/usr/bin/git", ["-C", repo] + sinPodar + ["gc", "--quiet"], limite: 1800)
                ok = r.estado == 0 && !r.agotado
                if !ok {
                    // Si git falla (sin espacio, o se detuvo por tiempo) deja a medias el paquete que escribía (tmp_pack_…),
                    // y con pruneExpire=never no lo recoge nunca: se borran los que dejó esta vez.
                    HistorialGit.borrarTemporales(en: paquetes, salvo: temporalesPrevios)
                }
                liberado = max(0, antes - Tamanos.de(git))
                if ok { registro.append("git compactado\t\(liberado)\t\(repo)") }
                else {
                    registro.append("git sin compactar\t0\t\(repo) (\(r.agotado ? "detenido por tiempo" : "estado \(r.estado)"))")
                    errores.append("\(el.nombre): git no pudo compactar el historial\(r.agotado ? " en 30 minutos y lo detuve" : ""). Tu historial sigue como estaba.")
                }
            case .borrarSueltos(let carpeta, let prefijo, let minHoras):
                // Solo en tu carpeta de temporales de macOS, y solo los sueltos de esa app.
                guard Rutas.temporalesDelSistema.contains(carpeta) else {
                    errores.append("\(el.nombre): no está en tu carpeta de temporales de macOS; no se tocó.")
                    ok = false
                    break
                }
                let r = borrarSueltos(en: carpeta, prefijo: prefijo, minHoras: minHoras, abiertos: procesos.abiertos)
                liberado = r.bytes
                if r.borrados > 0 { registro.append("temporales sueltos eliminados\t\(r.bytes)\t\(carpeta)/\(prefijo)XXXXXX (\(r.borrados))") }
                if r.fallos > 0 { errores.append("\(el.nombre): \(r.fallos) no se pudieron borrar.") }
                ok = r.borrados > 0 || r.fallos == 0
            case .comprimir(let compresion):
                let parte = 1 / Double(max(elementos.count, 1))
                // Una app solo se comprime si su firma es válida ahora: después se vuelve a comprobar y, si no lo fuera, se
                // deshace (así se sabe que el fallo sería de la compresión y no de antes).
                let app = compresion.apps ? compresion.raices.first : nil
                if let app {
                    progreso(Double(i) / Double(max(elementos.count, 1)), "\(el.nombre): compruebo su firma…")
                    let firma = FirmaDeCodigo.comprobar(app)
                    guard firma == .valida else {
                        let por: String
                        switch firma {
                        case .sinFirma: por = "no está firmada"
                        case .invalida(let motivo): por = "su firma ya no era válida antes de empezar (\(motivo))"
                        case .valida: por = ""
                        }
                        errores.append("\(el.nombre): \(por), así que no la toqué: no podría comprobar que sigue intacta después.")
                        ok = false
                        break
                    }
                }
                let r = Compresor.comprimir(compresion, progreso: { hechos, total, ahorro in
                    progreso((Double(i) + Double(hechos) / Double(max(total, 1))) * parte,
                             "\(el.nombre): \(Formato.numero(hechos)) de \(Formato.numero(total)) archivos · \(Formato.bytes(ahorro)) ahorrados")
                }, cancelado: cancelado, enUso: {
                    // Lo que no se debe tocar mientras algo funciona (el emulador): se vuelve a mirar antes de cada lote.
                    guard let uso = el.enUso else { return nil }
                    return capturar().quienUsa(uso)
                }, excluir: aUnir)
                liberado = r.ahorro
                comprimido += r.ahorro
                for (raiz, x) in r.porRaiz.sorted(by: { $0.key < $1.key }) {
                    registro.append("comprimido\t\(x.ahorro)\t\(raiz) (\(x.archivos) \(x.archivos == 1 ? "archivo" : "archivos"))")
                }
                if let quien = r.enUsoPor {
                    omitidos.append("\(el.nombre): \(quien) empezó a usarlo y paré\(r.comprimidos > 0 ? " a mitad" : ""). Ciérralo y vuelve a limpiar.")
                }
                if r.sinEspacio {
                    errores.append("\(el.nombre): paré porque quedaba poco espacio libre. Cada archivo se copia comprimido antes de cambiarlo por el original, y siempre dejo al menos 2 GB libres de margen.")
                }
                if !r.fallos.isEmpty {
                    errores += r.fallos.prefix(5).map { "\(el.nombre): \($0)" }
                    if r.fallos.count > 5 { errores.append("\(el.nombre): y \(r.fallos.count - 5) archivos más que dejé como estaban.") }
                }
                // Una compresión anterior se cortó y dejó copias que no coinciden con su original (si no se avisó ya al empezar).
                let guardadas = r.copiasGuardadas.filter { !restos.guardados.contains($0) }
                if let primera = guardadas.first {
                    errores.append("\(el.nombre): " + Self.avisoDeRestos(guardadas, de: "una compresión", en: Rutas.padre(Rutas.padre(primera))))
                }
                if r.detenido {
                    detenido = true
                    sinTerminar.append(r.comprimidos > 0 ? "\(el.nombre) (a mitad)" : el.nombre)
                }
                if r.sinPermiso {
                    sinPermisoApps = true
                    errores.append("\(el.nombre): macOS no me deja modificar apps. Activa LimpiadorMac en Ajustes › Privacidad y seguridad › Gestión de apps y vuelve a limpiar; \(r.comprimidos > 0 ? "lo que ya estaba comprimido se queda así y lo demás, como estaba" : "no toqué nada de la app").")
                }
                if let app, r.comprimidos > 0 {
                    let deshecho = comprobarApp(app, el, r, progreso: { progreso(Double(i) / Double(max(elementos.count, 1)), $0) },
                                                errores: &errores, registro: &registro)
                    if deshecho > 0 {
                        // Se descomprimió: lo ahorrado ya no cuenta.
                        liberado = max(0, liberado - deshecho)
                        comprimido = max(0, comprimido - deshecho)
                    } else {
                        appsComprimidas.append(app)
                    }
                }
                ok = r.comprimidos > 0 || (r.fallos.isEmpty && !r.sinEspacio && r.enUsoPor == nil && !r.detenido && !r.sinPermiso)
            case .clonar(let union):
                let r = Clonador.unir(union)
                liberado = r.ahorro
                comprimido += r.ahorro
                unido += r.ahorro
                for u in r.unidas {
                    registro.append("unido\t\(u.ahorro)\t\(u.ruta) (clon de \(r.fuente))")
                }
                if r.abiertas > 0 {
                    omitidos.append("\(el.nombre): \(r.abiertas == 1 ? "una copia estaba abierta" : "\(r.abiertas) copias estaban abiertas") y \(r.abiertas == 1 ? "la dejé" : "las dejé") como estaban. Ciérralas y vuelve a limpiar.")
                }
                if r.cambiaron > 0 && r.unidas.isEmpty {
                    omitidos.append("\(el.nombre): algo cambió desde el análisis, así que no uní nada. Vuelve a analizar y limpia otra vez.")
                }
                errores += r.fallos.prefix(5).map { "\(el.nombre): \($0)" }
                if r.fallos.count > 5 { errores.append("\(el.nombre): y \(r.fallos.count - 5) copias más que dejé como estaban.") }
                let guardadas = r.copiasGuardadas.filter { !restos.guardados.contains($0) }
                if let primera = guardadas.first {
                    errores.append("\(el.nombre): " + Self.avisoDeRestos(guardadas, de: "una unión de copias", en: Rutas.padre(primera)))
                }
                ok = !r.unidas.isEmpty || (r.fallos.isEmpty && r.abiertas == 0 && r.cambiaron == 0)
            case .quitarDescarga(let q):
                let r = Nube.quitar(q, cancelado: cancelado)
                liberado = r.bytes
                quitadoDeICloud += r.bytes
                // Uno por línea: así se sabe qué archivos quedaron solo en iCloud (se descargan al abrirlos).
                for ruta in r.archivos { registro.append("solo en iCloud\t0\t\(ruta)") }
                if r.quitados > 0 { registro.append("copias locales de iCloud quitadas\t\(r.bytes)\t\(r.quitados) archivos") }
                if r.cambiaron + r.abiertos > 0 {
                    let n = r.cambiaron + r.abiertos
                    omitidos.append("\(el.nombre): \(n == 1 ? "un archivo cambió, se abrió o se está subiendo" : "\(n) archivos cambiaron, se abrieron o se están subiendo") desde el análisis; \(n == 1 ? "lo dejé descargado" : "los dejé descargados").")
                }
                errores += r.fallos.prefix(5).map { "\(el.nombre): \($0)" }
                if r.fallos.count > 5 { errores.append("\(el.nombre): y \(r.fallos.count - 5) archivos más que siguen descargados.") }
                ok = r.quitados > 0 || r.fallos.isEmpty
            case .comando(let programa, let argumentos, let entorno, let limite):
                let linea = el.accion.lineaDeComando ?? programa
                // Si el programa ya no está, se dice y no se intenta nada más.
                guard FileManager.default.isExecutableFile(atPath: programa) else {
                    errores.append("\(el.nombre): no encontré «\(Rutas.nombre(programa))» (\(programa)), así que no ejecuté «\(linea)».")
                    ok = false
                    break
                }
                // Lo que ocupa ahora cada cosa que el comando debería quitar: lo que desaparezca es lo liberado.
                let antes = el.rutas.map { ($0.path, Rutas.existe($0) ? Tamanos.recorriendo($0.path) : 0) }
                progreso(Double(i) / Double(max(elementos.count, 1)), "\(el.nombre): \(linea)…")
                let r = Shell.comando(programa, argumentos, entorno: entorno, limite: limite)
                let quitado = antes.filter { !Rutas.existe($0.0) }.reduce(Int64(0)) { $0 + $1.1 }
                // Si no quita rutas que se vean (Docker guarda todo en su disco virtual), lo que dice el propio comando.
                liberado = quitado > 0 ? quitado : Self.recuperado(segun: r.salida) ?? 0
                ok = r.estado == 0 && !r.agotado
                registro.append("comando\t\(liberado)\t\(([programa] + argumentos).joined(separator: " ")) (\(r.agotado ? "detenido por tiempo" : "estado \(r.estado)"))")
                for l in r.salida.split(separator: "\n").suffix(40) { registro.append("salida\t0\t\(l.prefix(300))") }
                if r.agotado {
                    errores.append("\(el.nombre): «\(linea)» tardó más de \(Int(limite)) s y lo detuve. Lo que ya hizo se queda hecho; su salida está en el historial.")
                } else if r.estado != 0 {
                    let ultima = r.salida.split(separator: "\n").last.map { ": \($0.prefix(200))" } ?? ""
                    errores.append("\(el.nombre): «\(linea)» terminó con un error (\(r.estado))\(ultima). No lo reintenté; su salida está en el historial.")
                }
            }
            if ok {
                limpiados += 1
                bytes += liberado
                exitosos.insert(el.id)
                if el.accion != .borrar { liberadoAparte += liberado }
            }
        }
        progreso(1, "Midiendo el espacio liberado…")

        Historial.registrar(registro)
        let enEsta = movimientos.isEmpty ? nil : LimpiezaGuardada(fecha: Date(), movimientos: movimientos)
        if let enEsta { Historial.guardarUltima(enEsta) }
        // Una carpeta y algo de dentro eliminados a la vez cuentan una vez.
        let calculado = Totales.sinRepetir(eliminadas) + liberadoAparte
        // Si no se eliminó nada para siempre (todo fue a la Papelera), no hay nada que esperar.
        let libreDespues = eliminadas.isEmpty && liberadoAparte == 0 ? InfoDisco.libreAhora() : Medidor.estabilizar()
        progreso(1, "Listo")
        var r = ResultadoLimpieza(elementosLimpiados: limpiados, bytesLimpiados: bytes,
                                  libreAntes: libreAntes, libreDespues: libreDespues,
                                  errores: errores, modo: modo, omitidos: omitidos,
                                  forzadosAPapelera: forzados, restaurables: movimientos.count, exitosos: exitosos)
        r.appsAPapelera = appsAPapelera
        r.liberadoCalculado = calculado
        r.enPapelera = enPapelera
        r.comprimido = comprimido
        r.unido = unido
        r.instantaneas = instantaneas
        r.detenido = detenido
        r.sinTerminar = sinTerminar
        r.maximo = maximo
        r.purgable = InfoDisco.actual().purgable
        r.volveraACrecer = PlanMaximo.volveraACrecer(elementos.filter { exitosos.contains($0.id) })
        r.papelera = enEsta
        r.appsComprimidas = appsComprimidas
        r.sinPermisoApps = sinPermisoApps
        r.quitadoDeICloud = quitadoDeICloud
        return r
    }

    /// Recoge lo que dejaron una compresión o una unión que se cortaron (ver `Compresor.recogerTodosLosRestos` y
    /// `Clonador.recogerRestos`): en las carpetas de trabajo de la app, en las raíces donde se estaba comprimiendo, en las
    /// de lo que se va a comprimir ahora y en `ademas`. Solo se borra lo que está repetido (su archivo sigue en su sitio,
    /// con el mismo contenido); lo demás se queda y se avisa. `guardados` es lo que se dejó; `avisos`, cómo se dice.
    static func recogerRestos(_ elementos: [Elemento], ademas: [String] = [],
                              progreso: @Sendable (Double, String) -> Void = { _, _ in })
        -> (guardados: Set<String>, avisos: [String]) {
        let raices = ademas + elementos.flatMap { el -> [String] in
            if case .comprimir(let c) = el.accion, !c.apps { return c.raices }
            return []
        }
        if Compresor.puedeHaberRestos || Clonador.puedeHaberRestos || !ademas.isEmpty {
            progreso(0, "Recojo lo que dejó una limpieza que se cortó…")
        }
        let deCompresion = Compresor.recogerTodosLosRestos(ademas: raices)
        let deUnion = Clonador.recogerRestos()
        var avisos: [String] = []
        if let primera = deCompresion.first {
            avisos.append(avisoDeRestos(deCompresion, de: "una compresión", en: Rutas.padre(Rutas.padre(primera))))
        }
        if let primera = deUnion.first {
            avisos.append(avisoDeRestos(deUnion, de: "una unión de copias", en: Rutas.padre(primera)))
        }
        return (Set(deCompresion + deUnion), avisos)
    }

    /// «Una compresión anterior se cortó y dejó 2 archivos (a.jsonl y b.jsonl) que no coinciden con los tuyos…».
    static func avisoDeRestos(_ guardados: [String], de que: String, en carpeta: String) -> String {
        let n = guardados.count
        let nombres = Formato.listaCorta(guardados.map { Rutas.nombre($0) }, maximo: 3)
        return "\(que.prefix(1).uppercased() + que.dropFirst()) anterior se cortó y dejó \(n == 1 ? "un archivo" : "\(n) archivos") (\(nombres)) que no \(n == 1 ? "coincide" : "coinciden") con \(n == 1 ? "el tuyo" : "los tuyos"). No \(n == 1 ? "lo" : "los") borré: \(n == 1 ? "está" : "están") en \(Formato.rutaCorta(carpeta)); revísa\(n == 1 ? "lo" : "los") antes de borrar\(n == 1 ? "lo" : "los")."
    }

    /// Después de comprimir una app: si su firma ya no valida, la descomprime al momento (los archivos que se acaban de
    /// comprimir) y lo explica; si valida, apunta qué se comprimió para poder deshacerlo más tarde (`AppsComprimidas`).
    /// Devuelve lo que volvió a ocupar al descomprimirla (0 si la firma valida).
    static func comprobarApp(_ app: String, _ el: Elemento, _ r: Compresor.Resultado, progreso: (String) -> Void,
                                     errores: inout [String], registro: inout [String]) -> Int64 {
        progreso("\(el.nombre): compruebo su firma…")
        let firma = FirmaDeCodigo.comprobar(app)
        if firma == .valida {
            var id = ""
            if case .appInstalada(_, let i, _) = el.enUso { id = i }
            AppsComprimidas.apuntar(app: app, nombre: el.dueno ?? el.nombre, identificador: id,
                                    version: AppsPropias.version(de: app), archivos: r.archivos)
            return 0
        }
        var motivo = "ya no tiene firma"
        if case .invalida(let m) = firma { motivo = m }
        progreso("\(el.nombre): su firma no valida; la descomprimo…")
        let d = Compresor.descomprimir(r.archivos, raiz: app, apps: true)
        for (raiz, x) in d.porRaiz { registro.append("descomprimido\t\(d.aumento)\t\(raiz) (\(x.archivos) archivos: su firma no validaba)") }
        let ahora = FirmaDeCodigo.comprobar(app)
        errores.append("\(el.nombre): después de comprimirla, macOS no validaba su firma (\(motivo)), así que la descomprimí al momento (\(Formato.numero(d.comprimidos)) de \(Formato.numero(r.archivos.count)) archivos)"
                       + (ahora == .valida ? " y su firma vuelve a ser válida." : ". Su firma sigue sin validar: reinstálala desde su web para estar seguro."))
        return d.aumento
    }

    /// Es una app (.app): nunca se elimina para siempre, siempre va a la Papelera.
    static func esApp(_ url: URL) -> Bool { url.pathExtension.lowercased() == "app" }

    /// Lo que un comando dice que liberó («Total reclaimed space: 1.2GB», como lo escribe Docker), si lo dice.
    static func recuperado(segun salida: String) -> Int64? {
        for linea in salida.split(separator: "\n").reversed() {
            guard let r = linea.range(of: "reclaimed space:", options: .caseInsensitive) else { continue }
            return Formato.bytes(deTexto: String(linea[r.upperBound...]))
        }
        return nil
    }

    /// Elimina (sin pasar por la Papelera: son miles de archivos de unos KB) los temporales sueltos de una app que llevan
    /// `minHoras` sin cambios. Los vuelve a listar ahora mismo: lo que se creó o se abrió después del análisis se salta.
    static func borrarSueltos(en carpeta: String, prefijo: String, minHoras: Double, abiertos: ArchivosAbiertos)
        -> (borrados: Int, bytes: Int64, fallos: Int) {
        var borrados = 0
        var bytes: Int64 = 0
        var fallos = 0
        for s in TemporalesSueltos.listar(en: carpeta, prefijo: prefijo, minHoras: minHoras, abiertos: abiertos).viejos
        where Seguridad.sePuedeBorrar(URL(fileURLWithPath: s.ruta)) {
            if unlink(s.ruta) == 0 {
                borrados += 1
                bytes += s.bytes
            } else if errno != ENOENT {   // si ya no está (la app lo borró), no es un fallo
                fallos += 1
            }
        }
        return (borrados, bytes, fallos)
    }

    /// Mueve a la Papelera como lo hace el Finder: si hace falta, macOS pide la contraseña de administrador.
    private static func reciclar(_ url: URL) -> URL? {
        final class Caja: @unchecked Sendable { var destino: URL? }
        let caja = Caja()
        let listo = DispatchSemaphore(value: 0)
        NSWorkspace.shared.recycle([url]) { nuevas, error in
            if error == nil { caja.destino = nuevas[url] }
            listo.signal()
        }
        // Margen para que la persona escriba su contraseña.
        _ = listo.wait(timeout: .now() + 300)
        return caja.destino
    }

    private static func vaciarContenido(de url: URL, modo: ModoLimpieza) -> (completo: Bool, movimientos: [(String, String)]) {
        guard Rutas.esCarpeta(url) else { return (false, []) }
        var completo = true
        var movimientos: [(String, String)] = []
        for hijo in Rutas.hijos(url) {
            do {
                if modo == .papelera {
                    var destino: NSURL?
                    try FileManager.default.trashItem(at: hijo, resultingItemURL: &destino)
                    if let d = destino?.path { movimientos.append((hijo.path, d)) }
                } else {
                    try FileManager.default.removeItem(at: hijo)
                }
            } catch { completo = false }
        }
        return (completo, movimientos)
    }

    static func vaciarPapelera() -> Bool {
        let trash = Rutas.enHome(".Trash")
        guard let hijos = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else {
            return false
        }
        var todo = true
        for h in hijos {
            do { try FileManager.default.removeItem(at: h) } catch { todo = false }
        }
        Historial.olvidarUltima()   // lo que había para deshacer ya no existe
        return todo
    }

    static func tamanoPapelera() -> Int64 {
        Tamanos.de(Rutas.enHome(".Trash"))
    }

    /// Lo que pasó al vaciar solo lo de una limpieza.
    struct VaciadoParcial {
        var borrados = 0
        var bytes: Int64 = 0
        /// macOS no dejó borrar (sin «Acceso total al disco» la Papelera está protegida).
        var sinPermiso = 0
        /// Ya no estaba, o en su sitio hay otra cosa (se vació la Papelera y se tiró algo con el mismo nombre).
        var noEstaban = 0
        var errores: [String] = []
    }

    /// Borra para siempre de la Papelera solo lo que movió una limpieza (`l.movimientos`), y solo si cada cosa sigue
    /// siendo la que se movió: directamente dentro de la Papelera y con el mismo disco y número de archivo que cuando se
    /// movió. Lo demás que haya en la Papelera no se toca. `papelera` solo se cambia en las pruebas.
    static func vaciarSoloEsta(_ l: LimpiezaGuardada, papelera: URL = Rutas.enHome(".Trash")) -> VaciadoParcial {
        var r = VaciadoParcial()
        var registro: [String] = []
        let carpeta = Rutas.real(papelera)
        for m in l.movimientos {
            let ruta = URL(fileURLWithPath: m.enPapelera)
            var st = stat()
            guard Rutas.real(URL(fileURLWithPath: Rutas.padre(m.enPapelera))) == carpeta, Rutas.nombre(m.enPapelera) != ".DS_Store",
                  lstat(m.enPapelera, &st) == 0, let inodo = m.inodo, let dispositivo = m.dispositivo,
                  st.st_ino == inodo, st.st_dev == dispositivo else {
                r.noEstaban += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: ruta)
                r.borrados += 1
                r.bytes += m.bytes
                registro.append("eliminado de la Papelera\t\(m.bytes)\t\(m.enPapelera) (de \(m.original))")
            } catch {
                let codigo = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0
                if (error as NSError).code == NSFileWriteNoPermissionError || codigo == Int(EPERM) || codigo == Int(EACCES) {
                    r.sinPermiso += 1
                } else {
                    r.errores.append("\(Rutas.nombre(m.enPapelera)): \(error.localizedDescription)")
                }
            }
        }
        Historial.registrar(registro)
        return r
    }

    /// El Finder borra solo lo que lleva 30 días en la Papelera (Ajustes del Finder › Avanzado).
    static var finderVaciaA30Dias: Bool {
        CFPreferencesCopyAppValue("FXRemoveOldTrashItems" as CFString, "com.apple.finder" as CFString) as? Bool ?? false
    }
}

/// La petición de detener una limpieza larga (comprimir puede tardar minutos), hecha desde la interfaz mientras la
/// limpieza sigue en otro hilo.
final class Cancelacion: @unchecked Sendable {
    private let candado = NSLock()
    private var pedida = false

    var pedido: Bool {
        candado.lock()
        defer { candado.unlock() }
        return pedida
    }

    func pedir() {
        candado.lock()
        pedida = true
        candado.unlock()
    }

    func reiniciar() {
        candado.lock()
        pedida = false
        candado.unlock()
    }
}

// MARK: - Deshacer e historial

struct Movimiento: Codable, Hashable {
    let original: String
    let enPapelera: String
    let nombre: String
    let bytes: Int64
    /// El disco y el número de archivo de lo movido, ya en la Papelera: así «Vaciar solo lo de esta limpieza» sabe que
    /// sigue siendo lo mismo (nil en las limpiezas guardadas antes de que existiera).
    var dispositivo: Int32? = nil
    var inodo: UInt64? = nil

    /// El mismo movimiento con el disco y el número de archivo de lo que quedó en la Papelera.
    func identificado() -> Movimiento {
        var m = self
        var st = stat()
        if lstat(enPapelera, &st) == 0 {
            m.dispositivo = st.st_dev
            m.inodo = st.st_ino
        }
        return m
    }
}

struct LimpiezaGuardada: Codable {
    let fecha: Date
    var movimientos: [Movimiento]

    var bytes: Int64 { movimientos.reduce(0) { $0 + $1.bytes } }
    var elementos: Int { Set(movimientos.map(\.nombre)).count }
}

/// Guarda la última limpieza (para poder deshacerla) y un registro de todo lo que se borró.
enum Historial {
    private static let carpeta = Rutas.enHome("Library/Application Support/LimpiadorMac")
    private static let ultima = carpeta.appendingPathComponent("ultima-limpieza.json")
    static let registroURL = Rutas.enHome("Library/Logs/LimpiadorMac/historial.log")

    static func guardarUltima(_ l: LimpiezaGuardada) {
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let codificador = JSONEncoder()
        codificador.dateEncodingStrategy = .iso8601
        try? codificador.encode(l).write(to: ultima)
    }

    /// La última limpieza, si todavía queda algo en la Papelera para devolver.
    static func cargarUltima() -> LimpiezaGuardada? {
        let decodificador = JSONDecoder()
        decodificador.dateDecodingStrategy = .iso8601
        guard let datos = try? Data(contentsOf: ultima),
              var l = try? decodificador.decode(LimpiezaGuardada.self, from: datos) else { return nil }
        l.movimientos = l.movimientos.filter { Rutas.existe($0.enPapelera) }
        return l.movimientos.isEmpty ? nil : l
    }

    static func olvidarUltima() {
        try? FileManager.default.removeItem(at: ultima)
    }

    /// Devuelve cada cosa a su sitio original.
    static func deshacer(_ l: LimpiezaGuardada) -> (restaurados: Int, bytes: Int64, errores: [String]) {
        let fm = FileManager.default
        var restaurados = 0
        var bytes: Int64 = 0
        var errores: [String] = []
        var lineas: [String] = []
        // Lo que no se pudo devolver pero sigue en la Papelera se recuerda, para intentarlo otra vez.
        var pendientes: [Movimiento] = []
        for m in l.movimientos {
            let origen = URL(fileURLWithPath: m.enPapelera)
            let destino = URL(fileURLWithPath: m.original)
            guard fm.fileExists(atPath: origen.path) else {
                errores.append("\(Formato.rutaCorta(destino)): ya no está en la Papelera.")
                continue
            }
            guard !fm.fileExists(atPath: destino.path) else {
                errores.append("\(Formato.rutaCorta(destino)): ya existe algo con ese nombre; está en la Papelera.")
                pendientes.append(m)
                continue
            }
            do {
                try fm.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: origen, to: destino)
                restaurados += 1
                bytes += m.bytes
                lineas.append("restaurado\t\(m.bytes)\t\(m.original)")
            } catch {
                // Las apps de Aplicaciones instaladas por el sistema solo se pueden devolver desde el Finder.
                let pista = m.original.hasPrefix("/Applications/") ? " Ábrela en la Papelera y usa «Devolver» desde el Finder." : ""
                errores.append("\(Formato.rutaCorta(destino)): \(error.localizedDescription)\(pista)")
                pendientes.append(m)
            }
        }
        registrar(lineas)
        if pendientes.isEmpty { olvidarUltima() } else { guardarUltima(LimpiezaGuardada(fecha: l.fecha, movimientos: pendientes)) }
        return (restaurados, bytes, errores)
    }

    static func registrar(_ lineas: [String]) {
        guard !lineas.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: registroURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fecha = ISO8601DateFormatter().string(from: Date())
        let texto = lineas.map { "\(fecha)\t\($0)" }.joined(separator: "\n") + "\n"
        if let h = try? FileHandle(forWritingTo: registroURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(texto.utf8))
        } else {
            try? Data(texto.utf8).write(to: registroURL)
        }
    }
}
