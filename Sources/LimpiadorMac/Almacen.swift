import AppKit
import Foundation
import SwiftUI

enum Seccion: Hashable {
    case resumen
    case explorador
    case categoria(Categoria)
}

@MainActor
final class Almacen: ObservableObject {
    @Published var elementos: [Elemento] = [] { didSet { recalcular() } }
    @Published var analizando = false
    @Published var estado = EstadoAnalisis(fraccion: 0, fase: 0, mensaje: "")
    @Published var analizado = false
    @Published var disco = InfoDisco.actual()
    @Published var limpiando = false {
        didSet {
            // Se pidió salir (⌘Q) mientras se limpiaba: ahora que terminó, la app se cierra.
            if !limpiando && saliendo {
                saliendo = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
    }
    /// El almacén de la ventana: el delegado de la app lo mira al pedir salir (`DelegadoDeLaApp`).
    static weak var actual: Almacen?
    /// Se pidió salir mientras se limpiaba: la app se cierra en cuanto termine lo que tiene entre manos.
    @Published private(set) var saliendo = false
    /// Se pidió detener la limpieza en curso: termina lo que tiene entre manos y no empieza nada más.
    @Published private(set) var deteniendo = false
    @Published var progresoLimpieza: Double = 0
    @Published var mensajeLimpieza = ""
    @Published var resultado: ResultadoLimpieza?
    @Published var tamanoPapelera: Int64 = 0
    @Published var accesoTotal = Seguridad.tieneAccesoTotal()
    @Published var seccion: Seccion? = .resumen
    /// Elemento que se muestra en el panel de detalle.
    @Published var detalle: Elemento.ID?
    @Published var ultimaLimpieza: LimpiezaGuardada? = Historial.cargarUltima()
    @Published var mensajeDeshacer: String?
    @Published private(set) var indice: Indice?
    /// Instantáneas locales de Time Machine: mientras existan, lo borrado sigue ocupando.
    @Published private(set) var instantaneas = 0
    /// De esas, las de Time Machine (las únicas que se ofrece adelgazar con `tmutil thinlocalsnapshots`).
    @Published private(set) var instantaneasTM = 0
    /// Lo que pasó al pedir a macOS que adelgace las instantáneas (para la tarjeta del resumen).
    @Published private(set) var mensajeInstantaneas: String?
    /// Se dio «Acceso total al disco» con la app abierta (al volver a ella): se ofrece analizar otra vez.
    @Published private(set) var accesoNuevo = false
    /// Se volvió a la app sin Acceso total después de abrir sus Ajustes: puede que macOS lo aplique al volver a abrirla.
    @Published private(set) var volvioDeAjustes = false
    private var abrioAjustes = false
    /// Las apps comprimidas que se pueden descomprimir (menú Análisis › Descomprimir una app).
    @Published private(set) var appsComprimidas: [AppsComprimidas.Registro] = AppsComprimidas.lista()
    /// Cuánto del volumen de datos no se pudo revisar (nil mientras se mide o si no se sabe).
    @Published private(set) var sinRevisar: Int64?
    /// Lo que se libera de verdad al limpiar lo seleccionado (sin lo que comparte con clones).
    @Published private(set) var bytesSeleccionados: Int64 = 0
    /// De eso, lo que se libera en cuanto se elimina: lo Seguro y lo que no pasa por la Papelera. El resto
    /// (Revisar y Cuidado) va siempre a la Papelera y se libera al vaciarla.
    @Published private(set) var bytesAlInstante: Int64 = 0
    @Published private(set) var efectivos: [Elemento] = []
    @Published private(set) var totales: [Categoria: Int64] = [:]
    @Published private(set) var totalesSeleccionados: [Categoria: Int64] = [:]
    @Published private(set) var totalEncontrado: Int64 = 0
    @Published private(set) var duracionAnalisis: TimeInterval = 0
    /// Apps abiertas que bloquean elementos Seguro (para «Cerrar y limpiar»): se calcula cada vez que se vuelve a mirar
    /// qué está en uso.
    @Published private(set) var bloqueos: [BloqueoDeApp] = []
    /// Se está volviendo a mirar qué está en uso.
    @Published private(set) var comprobando = false
    /// Lo que pasó con cada app que se pidió cerrar con «Cerrar y limpiar», por su identificador.
    @Published private(set) var cierres: [String: CierreDeApp] = [:]
    private let cancelacion = Cancelacion()

    init() {
        Self.actual = self
    }

    // MARK: Análisis

    func analizar() {
        guard !analizando else { return }
        analizando = true
        analizado = false
        elementos = []
        resultado = nil
        detalle = nil
        sinRevisar = nil
        bloqueos = []
        cierres = [:]
        accesoTotal = Seguridad.tieneAccesoTotal()
        accesoNuevo = false
        volvioDeAjustes = false
        mensajeInstantaneas = nil
        estado = EstadoAnalisis(fraccion: 0, fase: 0, mensaje: "Preparando…")
        let inicio = Date()
        Task.detached(priority: .userInitiated) {
            let indice = Escaner().ejecutar(
                progreso: { e in Task { @MainActor in self.estado = e } },
                entrega: { nuevos in Task { @MainActor in self.elementos.append(contentsOf: nuevos) } })
            let papelera = Limpiador.tamanoPapelera()
            let instantaneas = Instantaneas.locales() ?? 0
            let deTimeMachine = instantaneas > 0 ? Instantaneas.deTimeMachine() ?? 0 : 0
            let disco = InfoDisco.actual()
            let comprimidas = AppsComprimidas.lista()
            await MainActor.run {
                self.indice = indice
                self.analizando = false
                self.analizado = true
                self.duracionAnalisis = Date().timeIntervalSince(inicio)
                self.disco = disco
                self.tamanoPapelera = papelera
                self.instantaneas = instantaneas
                self.instantaneasTM = deTimeMachine
                self.appsComprimidas = comprimidas
                self.ultimaLimpieza = Historial.cargarUltima()
            }
            // Sin Acceso total al disco, cuánto se quedó sin ver. Lo de fuera de tu carpeta se mide ahora, con du
            // (unos 10 s): durante el análisis lo hacía más lento. El aviso aparece cuando termina.
            guard !Seguridad.tieneAccesoTotal(), !Rutas.casaDePrueba, let fuera = MedidaFuera.medir() else { return }
            let sinRevisar = indice.sinRevisar(usadoDatos: InfoDisco.actual().usadoDatos, papelera: papelera, fuera: fuera)
            await MainActor.run { self.sinRevisar = sinRevisar }
        }
    }

    // MARK: Consultas

    func elementos(de c: Categoria) -> [Elemento] {
        elementos.filter { $0.categoria == c }
    }

    func total(de c: Categoria) -> Int64 { totales[c] ?? 0 }

    func totalSeleccionado(de c: Categoria) -> Int64 { totalesSeleccionados[c] ?? 0 }

    func elemento(_ id: Elemento.ID?) -> Elemento? {
        guard let id else { return nil }
        return elementos.first { $0.id == id }
    }

    /// Lo que conviene revisar sí o sí: elementos con avisos graves.
    var avisosImportantes: [Elemento] {
        elementos.filter { el in el.motivos.contains { $0.nivel == .peligro } }
            .sorted { $0.tamano > $1.tamano }
    }

    /// Qué elemento del análisis borra esa ruta (para el explorador). Solo los que la borran: comprimir una app, quitar
    /// copias de iCloud o borrar los temporales sueltos de una carpeta también la nombran, pero no la borran, y el
    /// explorador no debe enseñarla como «Seguro» para borrar.
    func elemento(enRuta ruta: String) -> Elemento? {
        elementos.first { el in el.accion == .borrar && el.rutas.contains { $0.path == ruta } }
    }

    /// Todos los totales cuentan cada ruta una sola vez, aunque esté en dos elementos
    /// (el emulador entero y su «Restablecer») o dentro de otra carpeta ya contada.
    private func recalcular() {
        var t: [Categoria: Int64] = [:]
        var s: [Categoria: Int64] = [:]
        let porCategoria = Dictionary(grouping: elementos, by: \.categoria)
        for (c, lista) in porCategoria {
            t[c] = Totales.sumaSinRepetir(lista)
            s[c] = Totales.sumaSinRepetir(lista.filter(\.seleccionado))
        }
        totales = t
        totalesSeleccionados = s
        totalEncontrado = Totales.sumaSinRepetir(elementos)

        let seleccionados = elementos.filter(\.seleccionado)
        bytesSeleccionados = Totales.sumaSinRepetir(seleccionados)
        bytesAlInstante = min(bytesSeleccionados,
                              Totales.sumaSinRepetir(seleccionados.filter { !$0.vaSiempreALaPapelera }))
        // Un elemento se limpia si le queda alguna ruta que no esté dentro de otra seleccionada.
        let rutas = Set(seleccionados.filter { $0.accion == .borrar }.flatMap { $0.rutas.map(\.path) })
        efectivos = seleccionados.filter { el in
            guard el.accion == .borrar else { return true }
            return el.rutas.contains { !Totales.dentroDe($0.path, rutas) }
        }
    }

    // MARK: Selección

    func alternar(_ id: Elemento.ID) {
        if let i = elementos.firstIndex(where: { $0.id == id }) { marcarAMano(i, !elementos[i].seleccionado) }
    }

    func seleccionado(_ id: Elemento.ID) -> Binding<Bool> {
        Binding(
            get: { self.elementos.first(where: { $0.id == id })?.seleccionado ?? false },
            set: { v in
                if let i = self.elementos.firstIndex(where: { $0.id == id }) { self.marcarAMano(i, v) }
            })
    }

    /// Marca o desmarca un elemento a mano (su casilla o el menú). Quitar algo que el análisis marcaría (o que se puede
    /// marcar en «Liberar al máximo») es una decisión: «Liberar al máximo» y «Cerrar y limpiar» la respetan.
    private func marcarAMano(_ i: Int, _ marcado: Bool) {
        var el = elementos[i]
        el.seleccionado = marcado
        el.desmarcadoAMano = !marcado && (el.recomendado || el.marcable)
        elementos[i] = el
    }

    /// Los botones «Todo», «Nada», «Solo lo seguro»… de una categoría. Lo que dejan sin marcar y estaba marcado cuenta
    /// como desmarcado a mano, igual que con la casilla (`marcarAMano`); lo que marcan deja de contar. Lo que ya estaba sin
    /// marcar y sigue así no cambia.
    func seleccionar(_ c: Categoria, _ criterio: (Elemento) -> Bool) {
        var copia = elementos
        for i in copia.indices where copia[i].categoria == c {
            let marcado = criterio(copia[i])
            if marcado {
                copia[i].desmarcadoAMano = false
            } else if copia[i].seleccionado {
                copia[i].desmarcadoAMano = copia[i].recomendado || copia[i].marcable
            }
            copia[i].seleccionado = marcado
        }
        elementos = copia
    }

    /// Lo que recomendó el análisis: seguro, de nivel normal, sin avisos y que no se esté usando (también lo que estaba
    /// en uso al analizar y ya no lo está).
    func seleccionarRecomendados() {
        var copia = elementos
        for i in copia.indices {
            copia[i].seleccionado = copia[i].nivel == .normal && copia[i].marcable && copia[i].avisos.isEmpty && !copia[i].abiertoAhora
            // Volver a lo recomendado deshace lo que se había desmarcado a mano.
            copia[i].desmarcadoAMano = false
        }
        elementos = copia
    }

    func irA(_ el: Elemento) {
        seccion = .categoria(el.categoria)
        detalle = el.id
    }

    // MARK: Limpieza

    /// Limpia lo seleccionado. Con `maximo` («Liberar al máximo»), lo Seguro se elimina sin pasar por la Papelera, de
    /// mayor a menor, y lo de Revisar o Cuidado va a la Papelera (ver `Limpiador.limpiar`).
    func limpiar(modo: ModoLimpieza, maximo: Bool = false) {
        let aLimpiar = efectivos
        guard !aLimpiar.isEmpty, !limpiando else { return }
        limpiando = true
        deteniendo = false
        progresoLimpieza = 0
        cancelacion.reiniciar()
        let cancelacion = cancelacion
        let conRestos = indice?.raicesConRestos ?? []
        Task.detached(priority: .userInitiated) {
            let r = Limpiador.limpiar(aLimpiar, modo: modo, maximo: maximo, raicesConRestos: conRestos, progreso: { f, m in
                Task { @MainActor in self.progresoLimpieza = f; self.mensajeLimpieza = m }
            }, cancelado: { cancelacion.pedido })
            let papelera = Limpiador.tamanoPapelera()
            await MainActor.run {
                self.quitarLimpiados(r)
                self.resultado = r
                self.limpiando = false
                self.deteniendo = false
                self.disco = InfoDisco.actual()
                self.tamanoPapelera = papelera
                self.ultimaLimpieza = Historial.cargarUltima()
                self.mensajeDeshacer = nil
                self.appsComprimidas = AppsComprimidas.lista()
            }
        }
    }

    /// Quita de la lista lo que se limpió (lo omitido o fallido sigue apareciendo).
    private func quitarLimpiados(_ r: ResultadoLimpieza) {
        let limpiados = r.exitosos
        let omitidos = Set(r.omitidos)
        elementos.removeAll { el in
            guard !omitidos.contains(where: { $0.hasPrefix(el.nombre + ":") }) else { return false }
            return el.accion == .borrar
                ? !el.rutas.contains(where: Rutas.existe)
                : limpiados.contains(el.id)
        }
    }

    /// Marca exactamente esos elementos (lo que eligió la hoja de «Liberar al máximo», `PlanMaximo`) y desmarca lo demás.
    func seleccionarMaximo(_ lista: [Elemento]) {
        let ids = Set(lista.map(\.id))
        var copia = elementos
        for i in copia.indices { copia[i].seleccionado = ids.contains(copia[i].id) }
        elementos = copia   // así se recalcula `efectivos` (sin lo que está dentro de otra ruta marcada)
    }

    /// «Liberar al máximo»: marca esos elementos y los limpia en el orden del Modo máximo.
    func liberarAlMaximo(_ lista: [Elemento]) {
        guard !limpiando, !lista.isEmpty else { return }
        seleccionarMaximo(lista)
        limpiar(modo: .definitivo, maximo: true)
    }

    /// «Cerrar y limpiar»: cierra la app como con ⌘Q (puede guardar, preguntar o negarse; nunca se fuerza), espera hasta
    /// 20 s a que termine, vuelve a mirar qué está en uso (sus ayudantes tardan un poco en soltar sus archivos) y limpia
    /// solo lo que esa app bloqueaba, de esos `niveles`. Si no se cierra, no se toca nada. Después se puede volver a abrir.
    func cerrarYLimpiar(_ b: BloqueoDeApp, niveles: Set<NivelMarcado>, modo: ModoLimpieza, maximo: Bool) {
        let ids = Set(b.elementos)
        let lista = elementos.filter { ids.contains($0.id) && niveles.contains($0.nivel) }
        guard !lista.isEmpty, !limpiando else { return }
        limpiando = true
        deteniendo = false
        progresoLimpieza = 0
        mensajeLimpieza = "Cerrando \(b.nombre)…"
        cancelacion.reiniciar()
        let cancelacion = cancelacion
        cierres[b.bundleID] = CierreDeApp(bloqueo: b)
        let pids = CierreDeApps.pedirCierre(b.bundleID)
        let conRestos = indice?.raicesConRestos ?? []
        Task.detached(priority: .userInitiated) {
            guard CierreDeApps.esperarCierre(pids, maximo: 20) else {
                await MainActor.run {
                    self.cierres[b.bundleID]?.estado = .noSeCerro
                    self.limpiando = false
                    self.mensajeLimpieza = ""
                }
                return
            }
            await MainActor.run { self.mensajeLimpieza = "Esperando a que \(b.nombre) suelte sus archivos…" }
            _ = CierreDeApps.esperarQueSuelte(lista)
            let r = Limpiador.limpiar(lista, modo: modo, maximo: maximo, raicesConRestos: conRestos, progreso: { f, m in
                Task { @MainActor in self.progresoLimpieza = f; self.mensajeLimpieza = m }
            }, cancelado: { cancelacion.pedido })
            let papelera = Limpiador.tamanoPapelera()
            await MainActor.run {
                self.quitarLimpiados(r)
                self.cierres[b.bundleID]?.estado = .limpiada
                self.cierres[b.bundleID]?.resultado = r
                self.limpiando = false
                self.deteniendo = false
                self.disco = InfoDisco.actual()
                self.tamanoPapelera = papelera
                self.ultimaLimpieza = Historial.cargarUltima()
                self.comprobarAppsAbiertas()
            }
        }
    }

    /// Las apps que se ofrece cerrar: las que bloquean al menos `minimo` de elementos de esos niveles, de la que más a la
    /// que menos, y las que ya se cerraron desde el análisis (para ver el resultado y volver a abrirlas). `resto` y
    /// `bytesResto`: las que bloquean menos, que no compensa cerrar.
    func appsParaCerrar(niveles: Set<NivelMarcado>, minimo: Int64 = 50_000_000) -> (filas: [BloqueoDeApp], resto: Int, bytesResto: Int64) {
        var filas: [BloqueoDeApp] = []
        var resto = 0
        var bytesResto: Int64 = 0
        for b in bloqueos where cierres[b.bundleID] == nil {
            let ids = Set(b.elementos)
            let bytes = Totales.sumaSinRepetir(elementos.filter { ids.contains($0.id) && niveles.contains($0.nivel) })
            guard bytes > 0 else { continue }
            if bytes >= minimo {
                filas.append(b)
            } else {
                resto += 1
                bytesResto += bytes
            }
        }
        let cerradas = cierres.values.map(\.bloqueo).sorted { $0.nombre < $1.nombre }
        return (cerradas + filas, resto, bytesResto)
    }

    /// Vuelve a abrir una app que se cerró con «Cerrar y limpiar».
    func volverAAbrir(_ bundleID: String) {
        guard let url = cierres[bundleID]?.bloqueo.url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        cierres[bundleID]?.estado = .reabierta
    }

    /// Detiene la limpieza en curso en cuanto sea seguro: lo hecho se queda hecho y lo que estaba a medias, como estaba.
    func detenerLimpieza() {
        guard limpiando else { return }
        deteniendo = true
        mensajeLimpieza = "Deteniendo: termino lo que tengo entre manos…"
        cancelacion.pedir()
    }

    /// Se pidió salir (⌘Q, cerrar sesión) mientras se limpia: se detiene como con «Detener» y la app se cierra en cuanto
    /// termine el archivo o el grupo de archivos que tenga entre manos, sin dejar nada a medias en carpetas temporales.
    func salirAlTerminar() {
        guard limpiando else { return }
        saliendo = true
        detenerLimpieza()
        mensajeLimpieza = "Me cierro en cuanto termine lo que tengo entre manos…"
    }

    func deshacer() {
        guard let l = ultimaLimpieza, !limpiando else { return }
        limpiando = true
        mensajeLimpieza = "Devolviendo todo a su sitio…"
        Task.detached {
            let r = Historial.deshacer(l)
            let papelera = Limpiador.tamanoPapelera()
            await MainActor.run {
                self.limpiando = false
                // Lo que no se pudo devolver se queda para volver a intentarlo.
                self.ultimaLimpieza = Historial.cargarUltima()
                self.tamanoPapelera = papelera
                self.disco = InfoDisco.actual()
                var texto = "Devolví \(r.restaurados) \(r.restaurados == 1 ? "elemento" : "elementos") a su sitio (\(Formato.bytes(r.bytes)))."
                if !r.errores.isEmpty { texto += " \(r.errores.count) no se pudieron devolver." }
                self.mensajeDeshacer = texto
                self.resultado = nil
                // Lo restaurado vuelve a aparecer en el próximo análisis.
            }
        }
    }

    func vaciarPapelera() {
        limpiando = true
        mensajeLimpieza = "Vaciando la Papelera…"
        let ocupaba = tamanoPapelera
        Task.detached {
            let antes = InfoDisco.libreAhora()
            let instantaneas = Instantaneas.locales() ?? 0
            let ok = Limpiador.vaciarPapelera()
            // El espacio vuelve en unos segundos: se mide cuando la lectura se estabiliza.
            let despues = Medidor.estabilizar()
            let papelera = Limpiador.tamanoPapelera()
            await MainActor.run {
                self.limpiando = false
                self.disco = InfoDisco.actual()
                self.tamanoPapelera = papelera
                self.ultimaLimpieza = nil
                self.elementos.removeAll { $0.accion == .vaciarPapelera }
                var r = ResultadoLimpieza(
                    elementosLimpiados: 1, bytesLimpiados: max(0, ocupaba - papelera), libreAntes: antes,
                    libreDespues: despues,
                    errores: ok ? [] : ["No se pudo vaciar toda la Papelera. Dale Acceso total al disco a LimpiadorMac."],
                    modo: .definitivo)
                // Sin Acceso total al disco no se sabe cuánto ocupaba: entonces solo vale lo medido.
                r.liberadoCalculado = ocupaba > 0 ? max(0, ocupaba - papelera) : r.liberadoMedido
                r.instantaneas = instantaneas
                self.resultado = r
            }
        }
    }

    /// «Vaciar solo lo de esta limpieza»: borra para siempre de la Papelera lo que movió esa limpieza y nada más (ver
    /// `Limpiador.vaciarSoloEsta`). Si macOS no lo deja (sin «Acceso total al disco»), lo explica.
    func vaciarSoloEsta(_ l: LimpiezaGuardada) {
        guard !limpiando else { return }
        limpiando = true
        mensajeLimpieza = "Vaciando de la Papelera lo de esta limpieza…"
        Task.detached {
            let antes = InfoDisco.libreAhora()
            let instantaneas = Instantaneas.locales() ?? 0
            let v = Limpiador.vaciarSoloEsta(l)
            let despues = v.borrados > 0 ? Medidor.estabilizar() : InfoDisco.libreAhora()
            let papelera = Limpiador.tamanoPapelera()
            let purgable = InfoDisco.actual().purgable
            let treintaDias = Limpiador.finderVaciaA30Dias
            await MainActor.run {
                var errores = v.errores
                if v.sinPermiso > 0 {
                    errores.insert("macOS no me dejó borrar \(v.sinPermiso == 1 ? "una cosa" : "\(v.sinPermiso) cosas") de la Papelera: sin «Acceso total al disco» la Papelera está protegida. Puedes vaciarla tú desde el Finder (clic derecho en la Papelera del Dock › Vaciar Papelera)"
                                   + (treintaDias ? "; además, el Finder borra solo lo que lleva 30 días en ella." : ", o darle Acceso total al disco a LimpiadorMac y volver a intentarlo."), at: 0)
                }
                if v.noEstaban > 0 {
                    errores.append("\(v.noEstaban == 1 ? "Una cosa ya no estaba" : "\(v.noEstaban) cosas ya no estaban") en la Papelera, o no pude comprobar que fuera lo mismo que movió esta limpieza: no la toqué.")
                }
                var r = ResultadoLimpieza(elementosLimpiados: v.borrados, bytesLimpiados: v.bytes, libreAntes: antes,
                                          libreDespues: despues, errores: errores, modo: .definitivo)
                r.liberadoCalculado = v.bytes
                r.instantaneas = instantaneas
                r.purgable = purgable
                self.limpiando = false
                self.disco = InfoDisco.actual()
                self.tamanoPapelera = papelera
                self.ultimaLimpieza = Historial.cargarUltima()
                self.resultado = r
            }
        }
    }

    func actualizarDisco() {
        disco = InfoDisco.actual()
        accesoTotal = Seguridad.tieneAccesoTotal()
        ultimaLimpieza = Historial.cargarUltima()
        Task.detached {
            let p = Limpiador.tamanoPapelera()
            await MainActor.run { self.tamanoPapelera = p }
        }
    }

    /// Al volver a la app (por ejemplo desde Ajustes): se vuelve a mirar el disco y si ya tiene «Acceso total al disco».
    /// Si se acaba de dar con un análisis hecho sin él, se ofrece analizar otra vez (ahora se ve lo que faltaba).
    func alVolverALaApp() {
        let antes = accesoTotal
        guard !analizando && !limpiando else { return }
        actualizarDisco()
        if !antes && accesoTotal && analizado { accesoNuevo = true }
        if !accesoTotal && abrioAjustes { volvioDeAjustes = true }
    }

    /// Vuelve a abrir LimpiadorMac (una copia nueva y esta se cierra): macOS aplica el «Acceso total al disco» a las apps
    /// cuando se vuelven a abrir.
    func volverAAbrirLaApp() {
        guard !analizando && !limpiando else { return }
        let configuracion = NSWorkspace.OpenConfiguration()
        configuracion.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuracion) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Pide a macOS que adelgace las instantáneas locales de Time Machine (ver `Instantaneas.adelgazar`): libera lo que
    /// retienen de lo que ya borraste. Las copias del disco de Time Machine no se tocan. Mide el disco antes y después.
    func adelgazarInstantaneas() {
        guard !limpiando, instantaneasTM > 0 else { return }
        limpiando = true
        mensajeLimpieza = "Pidiendo a macOS que adelgace las instantáneas…"
        let total = disco.total
        Task.detached {
            let antes = InfoDisco.libreAhora()
            let r = Instantaneas.adelgazar(bytes: max(total, 1_000_000_000))
            let despues = Medidor.estabilizar()
            let quedan = Instantaneas.deTimeMachine()
            let todas = Instantaneas.locales()
            Historial.registrar(["instantáneas adelgazadas\t\(max(0, despues - antes))\ttmutil thinlocalsnapshots / (estado \(r.bien ? 0 : 1); quedan \(quedan.map(String.init) ?? "?"))"])
            await MainActor.run {
                self.limpiando = false
                self.disco = InfoDisco.actual()
                if let quedan { self.instantaneasTM = quedan }
                if let todas { self.instantaneas = todas }
                let liberado = max(0, despues - antes)
                if r.bien {
                    self.mensajeInstantaneas = "macOS adelgazó las instantáneas: \(quedan.map { $0 == 0 ? "ya no queda ninguna de Time Machine" : "quedan \($0)" } ?? "no pude ver cuántas quedan") y se liberaron \(Formato.bytes(liberado)) (medido en el disco)."
                } else {
                    let ultima = r.salida.split(separator: "\n").last.map { ": \($0)" } ?? ""
                    self.mensajeInstantaneas = "macOS no las adelgazó\(ultima). Puedes hacerlo tú en la Terminal con «tmutil thinlocalsnapshots / \(max(total, 1_000_000_000)) 4» (puede pedir tu contraseña con sudo)."
                }
            }
        }
    }

    /// Descomprime una app que comprimió LimpiadorMac (si no se abre bien o prefieres dejarla como venía): sus archivos
    /// vuelven a guardarse sin comprimir, con la misma comprobación byte a byte. Tiene que estar cerrada.
    func descomprimirApp(_ registro: AppsComprimidas.Registro) {
        guard !limpiando else { return }
        limpiando = true
        mensajeLimpieza = "Descomprimiendo \(registro.nombre)…"
        Task.detached {
            let p = Procesos.capturar()
            let uso = EnUso.appInstalada(nombre: registro.nombre, id: registro.identificador, ruta: registro.app)
            var texto: String
            if !p.fiable {
                texto = "No pude ver qué está funcionando, así que no toqué \(registro.nombre). Inténtalo otra vez en un momento."
            } else if let quien = p.quienUsa(uso) {
                texto = quien == registro.nombre ? "\(registro.nombre) está abierta: ciérrala y vuelve a intentarlo."
                    : "\(quien) está usando \(registro.nombre): ciérralo y vuelve a intentarlo."
            } else {
                let d = Compresor.descomprimir(AppsComprimidas.rutas(registro), raiz: registro.app, apps: true, enUso: {
                    Procesos.capturar().quienUsa(uso)
                })
                for (raiz, x) in d.porRaiz { Historial.registrar(["descomprimido\t\(d.aumento)\t\(raiz) (\(x.archivos) archivos)"]) }
                if d.sinPermiso {
                    texto = "macOS no me deja modificar \(registro.nombre): activa LimpiadorMac en Ajustes › Privacidad y seguridad › Gestión de apps y vuelve a intentarlo."
                } else {
                    texto = "Descomprimí \(Formato.numero(d.comprimidos)) \(d.comprimidos == 1 ? "archivo" : "archivos") de \(registro.nombre): vuelve a ocupar \(Formato.bytes(d.aumento)) más, como venía."
                    if !d.fallos.isEmpty || d.abiertos > 0 || d.enUsoPor != nil {
                        texto += " Algunos se quedaron comprimidos (se leen igual): \(d.enUsoPor.map { "\($0) empezó a usarla" } ?? d.fallos.first ?? "estaban abiertos")."
                    } else {
                        AppsComprimidas.olvidar(registro.app)
                    }
                }
            }
            let lista = AppsComprimidas.lista()
            let mensaje = texto
            await MainActor.run {
                self.limpiando = false
                self.disco = InfoDisco.actual()
                self.appsComprimidas = lista
                self.mensajeDeshacer = mensaje
            }
        }
    }

    /// Vuelve a mirar qué apps están abiertas y qué archivos tienen abiertos los programas (por si el usuario los cerró
    /// tras el análisis), y qué apps abiertas bloquean elementos Seguro. `luego` se llama al terminar.
    func comprobarAppsAbiertas(luego: (@MainActor @Sendable () -> Void)? = nil) {
        comprobando = true
        let actuales = elementos
        Task.detached {
            let p = Procesos.capturar()
            // Si no se pudo mirar, todo se queda como estaba: no se sabe si se cerró.
            var revisados = actuales
            if p.fiable {
                for i in revisados.indices { revisados[i].comprobarUso(p) }
            }
            let bloqueos = p.fiable ? CierreDeApps.bloqueos(revisados, p) : nil
            let porID = Dictionary(uniqueKeysWithValues: revisados.map { ($0.id, $0) })
            await MainActor.run {
                if let bloqueos {
                    // Solo cambia lo que dice si está en uso: lo demás (lo que se marcó mientras tanto) se queda.
                    var copia = self.elementos
                    for i in copia.indices {
                        guard let r = porID[copia[i].id] else { continue }
                        copia[i].abiertoAhora = r.abiertoAhora
                        copia[i].usadoPor = r.usadoPor
                        copia[i].motivos = r.motivos
                    }
                    self.elementos = copia
                    self.bloqueos = bloqueos
                }
                self.comprobando = false
                luego?()
            }
        }
    }

    // MARK: Finder

    func mostrarEnFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func abrirAccesoTotal() {
        abrioAjustes = true
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Ajustes › Privacidad y seguridad › Gestión de apps (para comprimir apps).
    func abrirGestionDeApps() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
            NSWorkspace.shared.open(url)
        }
    }

    func abrirHistorial() {
        if Rutas.existe(Historial.registroURL) { NSWorkspace.shared.open(Historial.registroURL) }
    }
}
