import AppKit
import Foundation

// «Liberar al máximo»: qué se limpiaría por niveles (`PlanMaximo`) y las apps abiertas que bloquean elementos Seguro
// (`CierreDeApps`, para «Cerrar y limpiar»). Aquí no se borra nada: Limpiador hace el trabajo.

extension Elemento {
    /// Vuelve a mirar si algo lo usa, con una captura nueva (por si desde el análisis se cerró o se abrió algo). Si ya no
    /// lo usa nadie, quita los avisos de uso; si no se pudo mirar (`fiable` false), no cambia nada.
    mutating func comprobarUso(_ p: Procesos) {
        guard p.fiable else { return }
        motivos.removeAll { $0.icono == "questionmark.app.dashed" }
        let quien = p.quienUsa(self)
        if abiertoAhora && quien == nil {
            abiertoAhora = false
            usadoPor = nil
            motivos.removeAll { $0.icono == "macwindow.badge.plus" || $0.icono == "play.circle.fill" }
        } else if let quien {
            abiertoAhora = true
            usadoPor = quien
        }
    }

    /// No tiene más avisos que los de «algo lo usa ahora» (que se vuelven a mirar en el momento).
    var soloAvisosDeUso: Bool { avisos.allSatisfy { Evaluador.iconosDeUso.contains($0.icono) } }
}

/// Una app abierta con ventana (Brave, por ejemplo) que no deja limpiar elementos Seguro: son suyos (sus cachés) o tiene
/// abierto algo de ellos. «Cerrar y limpiar» la cierra como ⌘Q y limpia solo esos elementos.
struct BloqueoDeApp: Identifiable, Hashable {
    var id: String { bundleID }
    /// En minúsculas, como lo guarda `Procesos`.
    let bundleID: String
    let nombre: String
    /// Dónde está la app, para volver a abrirla.
    let url: URL?
    /// Los elementos que bloquea (todos Seguro y marcables si la app estuviera cerrada).
    let elementos: [Elemento.ID]
}

/// Lo que pasó al pedir cerrar una app con «Cerrar y limpiar».
struct CierreDeApp {
    enum Estado { case cerrando, noSeCerro, limpiada, reabierta }
    let bloqueo: BloqueoDeApp
    var estado: Estado = .cerrando
    /// La limpieza de lo que bloqueaba, cuando ya se cerró.
    var resultado: ResultadoLimpieza?
}

/// Cerrar una app abierta para poder limpiar lo suyo, siempre tras un clic: como ⌘Q (`NSRunningApplication.terminate`),
/// nunca a la fuerza. Si la app pregunta algo (guardar un documento) o no se cierra, no se toca nada.
enum CierreDeApps {
    /// Apps que no se ofrece cerrar: las que forman parte del sistema (el Finder, el Dock…) y esta misma.
    static let nunca: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow",
                                     "com.apple.controlcenter", "com.gustavo.limpiadormac"]

    /// Las apps que bloquean elementos que se marcarían si estuvieran cerradas, de la que más bloquea a la que menos. Un
    /// elemento solo cuenta si lo bloquea una sola app con ventana y nada más (un programa suelto, Gradle, un emulador):
    /// si no, cerrarla no lo liberaría.
    static func bloqueos(_ elementos: [Elemento], _ p: Procesos) -> [BloqueoDeApp] {
        guard p.fiable else { return [] }
        let propia = getpid()
        var porApp: [String: [Elemento]] = [:]
        for el in elementos where el.marcable && el.riesgo == .seguro && el.accion == .borrar && el.soloAvisosDeUso && !el.desmarcadoAMano {
            guard p.quienUsa(el) != nil, let apps = appsQueLoBloquean(el, p), apps.count == 1, let id = apps.first,
                  !nunca.contains(id), !p.apps.contains(where: { $0.bundleID == id && $0.pid == propia }) else { continue }
            porApp[id, default: []].append(el)
        }
        return porApp.map { id, lista in
            let app = p.apps.first { $0.bundleID == id && $0.normal }
            return (BloqueoDeApp(bundleID: id, nombre: app?.nombre ?? id, url: app?.url, elementos: lista.map(\.id)),
                    Totales.sumaSinRepetir(lista))
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// Las apps con ventana que hay detrás de todo lo que usa el elemento ahora mismo: la app a la que pertenece (`.app`)
    /// y las que tienen abierto algo de sus rutas. nil si algo más lo usa (otro tipo de `enUso`, o un proceso que no es
    /// de ninguna app con ventana).
    static func appsQueLoBloquean(_ el: Elemento, _ p: Procesos) -> Set<String>? {
        var r = Set<String>()
        if let uso = el.enUso, p.quienUsa(uso) != nil {
            guard case .app(_, let claves) = uso, let apps = p.appsQueCierran(claves) else { return nil }
            r.formUnion(apps)
        }
        for u in el.rutasVigiladas {
            guard let pid = p.abiertos.proceso(dentroDe: u.path) else { continue }
            guard let id = p.appConVentana(pid: pid) else { return nil }
            r.insert(id)
        }
        return r.isEmpty ? nil : r
    }

    /// Pide a la app que se cierre como con ⌘Q (puede guardar, preguntar o negarse). Devuelve los procesos a los que se les
    /// pidió (vacío si no estaba abierta o no se pudo pedir). Nunca usa `forceTerminate`.
    @discardableResult
    static func pedirCierre(_ bundleID: String) -> [pid_t] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier?.lowercased() == bundleID && $0.activationPolicy == .regular }
            .filter { $0.terminate() }
            .map(\.processIdentifier)
    }

    /// Espera hasta `maximo` segundos a que terminen esos procesos. true si terminaron todos.
    static func esperarCierre(_ pids: [pid_t], maximo: TimeInterval = 20) -> Bool {
        guard !pids.isEmpty else { return false }
        let limite = Date().addingTimeInterval(maximo)
        while true {
            if pids.allSatisfy({ kill($0, 0) != 0 && errno == ESRCH }) { return true }
            if Date() > limite { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Después de cerrar una app, sus ayudantes tardan un poco en terminar y soltar lo que tenían abierto: vuelve a mirar
    /// cada segundo, como mucho `maximo` segundos, hasta que nada use esos elementos. Devuelve la última captura.
    static func esperarQueSuelte(_ elementos: [Elemento], maximo: TimeInterval = 10,
                                 capturar: () -> Procesos = { Procesos.capturar() }) -> Procesos {
        let limite = Date().addingTimeInterval(maximo)
        var p = capturar()
        while p.fiable && elementos.contains(where: { p.quienUsa($0) != nil }) && Date() < limite {
            Thread.sleep(forTimeInterval: 1)
            p = capturar()
        }
        return p
    }
}

/// Lo que haría «Liberar al máximo», por bloques, con lo que se sabe ahora (el análisis más una captura nueva de lo que
/// está en uso: los elementos ya deben llevar `comprobarUso`). No marca ni borra nada: lo usan la hoja de «Liberar al
/// máximo» y `--diagnostico --maximo`. Lo que no es Seguro nunca entra solo, en ningún bloque.
struct PlanMaximo {
    /// Se regenera solo o ya no se usa (nivel normal): lo mismo que marca el modo normal, más lo que se liberó desde el
    /// análisis. Sin internet.
    var regenera: [Elemento] = []
    /// Sin borrar nada: comprimir (nivel normal; apps y tu material, nivel máximo), unir copias idénticas y compactar el
    /// historial de git sin podar nada (nivel máximo).
    var sinBorrar: [Elemento] = []
    /// Cuesta volver a descargar o recompilar (nivel máximo): dependencias, wrappers, lo que se usó hace unas horas, las
    /// copias locales de iCloud…
    var cuesta: [Elemento] = []
    /// Apps abiertas que bloquean elementos Seguro: se ofrecen app por app con «Cerrar y limpiar».
    var cerrarApps: [BloqueoDeApp] = []
    /// Lo que marcaste tú y el análisis no marcaría (Revisar, Cuidado o Seguro con algún aviso): se respeta; lo que no es
    /// Seguro va a la Papelera.
    var aMano: [Elemento] = []
    /// Lo que no se marca nunca: Revisar y Cuidado (puede ser valioso o no se puede recuperar).
    var nunca: [Elemento] = []
    /// Seguro, pero ahora no: algo lo usa, cambió hace poco, tiene algún aviso, no compensa o lo desmarcaste tú.
    var fuera: [Elemento] = []

    static func calcular(_ elementos: [Elemento], bloqueos: [BloqueoDeApp] = []) -> PlanMaximo {
        var plan = PlanMaximo()
        plan.cerrarApps = bloqueos
        let bloqueados = Set(bloqueos.flatMap(\.elementos))
        for el in elementos {
            if el.seleccionado && !el.marcable {
                plan.aMano.append(el)
            } else if el.riesgo != .seguro {
                plan.nunca.append(el)
            } else if el.desmarcadoAMano {
                // Lo quitaste tú: no se vuelve a meter, aunque se pudiera.
                plan.fuera.append(el)
            } else if el.marcable && !el.abiertoAhora && el.avisos.isEmpty && el.accion != .vaciarPapelera {
                // Quitar la copia local de iCloud no borra nada, pero cuesta volver a descargarlo: va con lo que cuesta.
                // Compactar git tampoco borra nada (no poda) ni cuesta descargas: va con comprimir y unir.
                if (el.accion.noBorraNada && !el.accion.quitaDescarga) || el.accion.compactaGit {
                    plan.sinBorrar.append(el)
                } else if el.nivel == .normal {
                    plan.regenera.append(el)
                } else if el.nivel == .maximo {
                    plan.cuesta.append(el)
                } else {
                    plan.fuera.append(el)
                }
            } else if !bloqueados.contains(el.id) {
                plan.fuera.append(el)
            }
        }
        let porTamano = { (a: Elemento, b: Elemento) in a.bytesLiberables > b.bytesLiberables }
        plan.regenera.sort(by: porTamano)
        plan.sinBorrar.sort(by: porTamano)
        plan.cuesta.sort(by: porTamano)
        plan.aMano.sort(by: porTamano)
        plan.nunca.sort(by: porTamano)
        plan.fuera.sort(by: porTamano)
        return plan
    }

    /// Lo que se limpiaría: lo que se regenera, siempre; lo demás según lo que se elija.
    func aLimpiar(sinBorrar conSinBorrar: Bool = true, cuesta conCoste: Bool = true, aMano conAMano: Bool = true) -> [Elemento] {
        regenera + (conSinBorrar ? sinBorrar : []) + (conCoste ? cuesta : []) + (conAMano ? aMano : [])
    }

    /// Lo que cuesta liberar esos elementos, en frases cortas y juntando lo repetido («Gradle vuelve a descargar unos
    /// 1,7 GB…»), para decirlo antes de hacerlo.
    static func costes(_ elementos: [Elemento]) -> [String] {
        var descargas: [(quien: String, bytes: Int64)] = []
        var proyectos: [String] = []
        var arranque = false
        var actualizar: [String] = []
        var procesador = false
        var git = false
        var apps = false
        var salidas: [String] = []
        for el in elementos {
            if el.accion.comprimeApps { apps = true }
            if el.accion.compactaGit { git = true }
            for c in el.costes {
                switch c {
                case .descarga(let bytes):
                    let quien = el.dueno ?? el.nombre
                    if let i = descargas.firstIndex(where: { $0.quien == quien }) { descargas[i].bytes += bytes } else { descargas.append((quien, bytes)) }
                case .recompilacion(let proyecto): if !proyectos.contains(proyecto) { proyectos.append(proyecto) }
                case .arranqueEnFrio: arranque = true
                case .seDeshaceAlActualizar(let app): if !actualizar.contains(app) { actualizar.append(app) }
                case .tiempoCPU: procesador = true
                case .borraSalidas(let proyecto): if !salidas.contains(proyecto) { salidas.append(proyecto) }
                }
            }
        }
        var r: [String] = []
        if !descargas.isEmpty {
            let total = descargas.reduce(Int64(0)) { $0 + $1.bytes }
            let partes = descargas.sorted { $0.bytes > $1.bytes }.map { $0.bytes > 0 ? "\($0.quien) (\(Formato.bytes($0.bytes)))" : $0.quien }
            r.append(total > 0
                ? "Se vuelven a descargar unos \(Formato.bytes(total)) cuando hagan falta (necesita internet): \(Formato.listaCorta(partes, maximo: 4))."
                : "Se vuelven a descargar las dependencias de \(Formato.listaCorta(partes, maximo: 4)) cuando hagan falta (necesita internet).")
        }
        if !proyectos.isEmpty {
            r.append("La próxima compilación de \(Formato.listaCorta(proyectos, maximo: 4)) se hace desde cero (más lenta).")
        }
        if !salidas.isEmpty {
            r.append("De \(Formato.listaCorta(salidas, maximo: 4)) se borra también lo que entregas (APK, AAB, dist…) y los informes y resultados de pruebas: se vuelven a crear al compilar o al pasar las pruebas, pero los informes de pruebas pasadas no vuelven.")
        }
        if arranque {
            r.append("El emulador arranca en frío la próxima vez (uno o dos minutos más) y, si usas Quick Boot, vuelve a guardar su arranque rápido al cerrarse.")
        }
        if !actualizar.isEmpty {
            r.append("\(Formato.listaCorta(actualizar)) \(actualizar.count == 1 ? "vuelve" : "vuelven") a ocupar lo mismo al actualizarse.")
        }
        if procesador {
            // Comprimir y unir miran si se pidió detener entre un grupo de archivos y otro; git gc, una vez empezado, no.
            r.append(git
                ? "Comprimir, unir copias y compactar historiales gastan un rato de procesador. Comprimir y unir los puedes detener cuando quieras (termino el grupo de archivos que tenga entre manos); git, una vez empieza con un historial, lo termina (o lo corto a los 30 minutos)."
                : "Comprimir y unir copias gastan un rato de procesador; lo puedes detener cuando quieras (termino el grupo de archivos que tenga entre manos).")
        }
        if apps {
            r.append("Para comprimir apps, macOS tiene que dejar a LimpiadorMac modificarlas (Ajustes › Privacidad y seguridad › Gestión de apps); si no lo deja, no toco ninguna y te digo cómo activarlo. Solo se comprimen cerradas.")
        }
        return r
    }

    /// Alguno de esos elementos borra salidas de compilación (lo que entregas, informes…): entonces no se puede decir que
    /// «no se pierde nada».
    static func borraSalidas(_ elementos: [Elemento]) -> Bool {
        elementos.contains { el in el.costes.contains { if case .borraSalidas = $0 { return true } else { return false } } }
    }

    /// Lo limpiado que vuelve a crecer con el uso, para decirlo en el resultado.
    static func volveraACrecer(_ elementos: [Elemento]) -> [String] {
        var r: [String] = []
        func agregar(_ s: String) { if !r.contains(s) { r.append(s) } }
        if elementos.contains(where: \.accion.comprimeApps) { agregar("las apps que comprimí (al actualizarse)") }
        if elementos.contains(where: \.accion.quitaDescarga) { agregar("los archivos de iCloud que vuelvas a abrir (se descargan)") }
        for el in elementos where !el.accion.noBorraNada {
            if el.costes.contains(.arranqueEnFrio) { agregar("el arranque rápido del emulador (al cerrarlo, si usas Quick Boot)") }
            switch el.categoria {
            case .proyectos where el.accion == .borrar && el.nombre.hasPrefix("Intermedios de compilación"):
                agregar("los intermedios de compilación (al compilar)")
            case .proyectos where el.accion == .borrar:
                agregar("las dependencias y lo que generan tus proyectos (al instalarlas o al compilar)")
            case .desarrollo where el.dueno == "Gradle": agregar("las cachés de Gradle (al compilar)")
            case .desarrollo: agregar("las cachés de tus herramientas de desarrollo (al usarlas)")
            case .cachesApps: agregar("las cachés de las apps (al usarlas)")
            case .sistema: agregar("los temporales de macOS y de tus programas")
            default: break
            }
        }
        return r
    }
}
