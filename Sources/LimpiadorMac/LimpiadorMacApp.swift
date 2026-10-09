import AppKit
import SwiftUI

@main
struct LimpiadorMacApp: App {
    @StateObject private var almacen = Almacen()
    @NSApplicationDelegateAdaptor(DelegadoDeLaApp.self) private var delegado

    init() {
        // Modo diagnóstico: `LimpiadorMac --diagnostico` imprime el análisis en la terminal sin abrir ventanas. Con
        // `--maximo`, también lo que haría «Liberar al máximo», por bloques (sin ejecutar nada).
        if CommandLine.arguments.contains("--diagnostico") {
            Diagnostico.ejecutar(detallado: CommandLine.arguments.contains("--motivos"),
                                 rutas: CommandLine.arguments.contains("--rutas"),
                                 maximo: CommandLine.arguments.contains("--maximo"))
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("LimpiadorMac") {
            VistaPrincipal()
                .environmentObject(almacen)
                .frame(minWidth: 1180, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Análisis") {
                Button("Analizar a fondo") { almacen.analizar() }
                    .keyboardShortcut("r")
                    .disabled(almacen.analizando || almacen.limpiando)
                Button("Ver historial de limpiezas") { almacen.abrirHistorial() }
                // Las apps que comprimió LimpiadorMac, por si alguna no se abre bien: vuelven a guardarse como venían.
                Menu("Descomprimir una app") {
                    if almacen.appsComprimidas.isEmpty {
                        Text("No hay ninguna app comprimida")
                    }
                    ForEach(almacen.appsComprimidas) { r in
                        Button("\(r.nombre) (\(Formato.numero(r.archivos.count)) archivos, \(Formato.haceCuanto(r.fecha).lowercased()))") {
                            almacen.descomprimirApp(r)
                        }
                    }
                }
                .disabled(almacen.analizando || almacen.limpiando)
            }
        }
    }
}

/// Al salir (⌘Q, cerrar sesión o apagar) mientras se limpia, la app no se cierra a mitad de un archivo: pide detener,
/// como el botón «Detener», y se cierra en cuanto termina el archivo o el grupo de archivos que tiene entre manos. Así una
/// compresión o una unión no deja copias a medias en sus carpetas temporales (ver `Almacen.salirAlTerminar`).
@MainActor
final class DelegadoDeLaApp: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let almacen = Almacen.actual, almacen.limpiando else { return .terminateNow }
        almacen.salirAlTerminar()
        return .terminateLater
    }
}

enum Diagnostico {
    /// `detallado` (--motivos) imprime todos los motivos; `rutas` (--rutas), las rutas de los elementos que tienen varias;
    /// `maximo` (--maximo), el plan de «Liberar al máximo» por bloques.
    static func ejecutar(detallado: Bool, rutas: Bool, maximo: Bool = false) {
        let d = InfoDisco.actual()
        print("Disco: \(Formato.bytes(d.libre)) libres de verdad + \(Formato.bytes(d.purgable)) purgables (el Finder dice \(Formato.bytes(d.libreImportante))) de \(Formato.bytes(d.total)) · volumen de datos: \(Formato.bytes(d.usadoDatos)) usados")
        let instantaneas = Instantaneas.locales()
        print("Instantáneas locales: \(instantaneas.map(String.init) ?? "no se pudo saber")\(instantaneas.map { $0 > 0 ? " (de Time Machine: \(Instantaneas.deTimeMachine().map(String.init) ?? "?"))" : "" } ?? "")")
        print("Acceso total al disco: \(Seguridad.tieneAccesoTotal() ? "sí" : "no")")
        let t0 = Date()
        let p = Procesos.capturar()
        print("Procesos: \(p.programas.count) programas, \(p.apps.count) apps, \(Formato.numero(p.abiertos.cuantas)) rutas abiertas, Gradle \(p.versionesGradle.sorted().joined(separator: ", "))\(p.gradleSinVersion ? " (y uno sin versión)" : "") · fiable: \(p.fiable ? "sí" : "NO") · \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        final class Suma: @unchecked Sendable {
            var todos: [Elemento] = []
            var porRiesgo: [Riesgo: Int] = [:]
            var ultimaFase = -1
        }
        let suma = Suma()
        let inicio = Date()
        let indice = Escaner().ejecutar(
            progreso: { e in
                if e.fase != suma.ultimaFase {
                    suma.ultimaFase = e.fase
                    print("\n▶︎ \(e.mensaje)  \(e.detalle)")
                }
            },
            entrega: { els in
                suma.todos += els
                for e in els {
                    suma.porRiesgo[e.riesgo, default: 0] += 1
                    let marca = e.seleccionado ? "[x]" : "[ ]"
                    let abierta = e.abiertoAhora ? " ⚡︎" + (e.usadoPor.map { " (\($0))" } ?? "") : ""
                    let maximo = e.nivel == .maximo ? " · Modo máximo" : ""
                    print("  \(marca) \(Formato.bytes(e.tamano).padding(toLength: 10, withPad: " ", startingAt: 0)) \(e.riesgo.etiqueta.padding(toLength: 8, withPad: " ", startingAt: 0)) \(Formato.haceCuanto(e.ultimoUso).padding(toLength: 14, withPad: " ", startingAt: 0)) \(e.nombre)\(abierta)\(maximo)  —  \(e.rutas.count > 1 ? "\(e.rutas.count) rutas" : Formato.rutaCorta(e.rutaPrincipal))")
                    // Lo que libera de verdad, si comparte espacio con clones.
                    if e.comparteEspacio {
                        let dentro = max(0, e.tamano - e.bytesLiberables - e.retenido)
                        print("         = libera \(Formato.bytes(e.bytesLiberables)) (ocupa \(Formato.bytes(e.tamano)): \(Formato.bytes(e.retenido)) compartidos con clones que se quedan, \(Formato.bytes(dentro)) de copias de dentro que el disco guarda una vez)")
                    }
                    // Lo que se comprime o se une: cuántos archivos, cuánto ocupan y el ahorro estimado.
                    if let p = e.prevision, e.accion.une {
                        print("         = une \(Formato.numero(p.archivos.count)) \(p.archivos.count == 1 ? "copia que ocupa" : "copias que ocupan") \(Formato.bytes(p.ocupan)) con \(Formato.rutaCorta(p.requiere ?? "?")): ahorro \(Formato.bytes(p.ahorro))")
                    } else if let p = e.prevision {
                        print("         = comprime \(Formato.numero(p.archivos.count)) archivos que ocupan \(Formato.bytes(p.ocupan)): ahorro estimado \(Formato.bytes(p.ahorro))")
                    }
                    // El comando oficial que se ejecutaría (no se ejecuta en el diagnóstico).
                    if let linea = e.accion.lineaDeComando {
                        print("         = ejecutaría «\(linea)»")
                    }
                    if rutas && e.rutas.count > 1 {
                        for (i, u) in e.rutas.enumerated() {
                            let ocupa = i < e.tamanosRutas.count ? e.tamanosRutas[i] : 0
                            print("         → \(Formato.bytes(ocupa).padding(toLength: 10, withPad: " ", startingAt: 0)) \(Formato.rutaCorta(u))")
                        }
                    }
                    let mostrar = detallado ? e.motivos : e.motivos.filter { $0.nivel >= .aviso }
                    for m in mostrar {
                        let icono = ["✓", "·", "!", "✗"][m.nivel.rawValue]
                        print("         \(icono) \(m.etiqueta): \(m.texto)")
                    }
                }
            })
        print("\nÍndice: \(Formato.numero(indice.archivosTotales)) archivos, \(Formato.bytes(indice.bytesTotales)), \(indice.carpetas.count) carpetas registradas, \(String(format: "%.1f", indice.duracion)) s (sin permiso: \(indice.sinPermiso))")
        let compartido = indice.raices.reduce(Int64(0)) { $0 + (indice.info($1)?.compartido ?? 0) }
        print("Clones: \(Formato.bytes(compartido)) compartidos en archivos de 1 MiB o más · \(indice.clonados.count) archivos con copias exactas")
        let duracion = Date().timeIntervalSince(inicio)
        if Rutas.casaDePrueba {
            print("Sin revisar: no aplica (casa de prueba)")
        } else {
            let papelera = Limpiador.tamanoPapelera()
            let t = Date()
            let fuera = MedidaFuera.medir()
            let usado = InfoDisco.actual().usadoDatos
            let sin = fuera.flatMap { indice.sinRevisar(usadoDatos: usado, papelera: papelera, fuera: $0) }
            print("Revisado: índice \(Formato.bytes(indice.bytesTotales)) + fuera de tu carpeta \(fuera.map { Formato.bytes(indice.medidoFuera($0)) } ?? "?") + Papelera \(Formato.bytes(papelera)) · sin revisar: \(sin.map(Formato.bytes) ?? "?") de \(Formato.bytes(usado)) (du tardó \(String(format: "%.1f", Date().timeIntervalSince(t))) s, después del análisis)")
        }
        print("Sensibles: \(indice.sensibles.count) · Repos: \(indice.repos.count) · Releases: \(indice.releases.count) · Artefactos: \(indice.artefactos.count) · Duplicables: \(indice.duplicables.count)")
        if !indice.probablesRestos.isEmpty {
            print("Probables restos sin medir (sin Acceso total): " + indice.probablesRestos.map { "\($0.nombre) (\($0.carpetas.count): \($0.carpetas.joined(separator: ", ")))" }.joined(separator: " · "))
        }
        if !indice.otrasNubes.isEmpty { print("Otras nubes (solo se informa): \(indice.otrasNubes.joined(separator: ", "))") }
        if !indice.raicesConRestos.isEmpty {
            print("Restos de una compresión que se cortó (no se ofrecen; la próxima limpieza los recoge): " + indice.raicesConRestos.map { Formato.rutaCorta($0) }.joined(separator: ", "))
        }
        for nota in indice.notas {
            print("Nota (\(nota.categoria.titulo), no se ofrece borrar): \(nota.titulo) — \(Formato.bytes(nota.bytes)) — \(Formato.rutaCorta(nota.ruta))")
        }
        let comprimidas = AppsComprimidas.lista(olvidar: false)
        if !comprimidas.isEmpty {
            print("Apps comprimidas (se pueden descomprimir): " + comprimidas.map { "\($0.nombre) (\($0.archivos.count) archivos)" }.joined(separator: " · "))
        }
        print("Total encontrado: \(Formato.bytes(Totales.sumaSinRepetir(suma.todos))) libera (ocupa \(Formato.bytes(Totales.sumaSinRepetir(suma.todos, liberable: false)))) · Preseleccionado: \(Formato.bytes(Totales.sumaSinRepetir(suma.todos.filter(\.seleccionado))))")
        let porCategoria = Dictionary(grouping: suma.todos, by: \.categoria)
        for c in Categoria.allCases {
            let lista = porCategoria[c] ?? []
            print("  \(c.titulo.padding(toLength: 26, withPad: " ", startingAt: 0)) \(String(lista.count).padding(toLength: 5, withPad: " ", startingAt: 0)) \(Formato.bytes(Totales.sumaSinRepetir(lista)))")
        }
        print("Por riesgo: seguro \(suma.porRiesgo[.seguro] ?? 0), revisar \(suma.porRiesgo[.revisar] ?? 0), cuidado \(suma.porRiesgo[.cuidado] ?? 0)")
        print("Tiempo total: \(String(format: "%.1f", duracion)) s")
        if maximo { imprimirMaximo(suma.todos) }
    }

    /// Lo que haría «Liberar al máximo», por bloques, como lo calcula la hoja: con una captura nueva de lo que está en
    /// uso. No se marca, cierra ni borra nada.
    private static func imprimirMaximo(_ analizados: [Elemento]) {
        let p = Procesos.capturar()
        var todos = analizados
        for i in todos.indices { todos[i].comprobarUso(p) }
        let bloqueos = CierreDeApps.bloqueos(todos, p)
        let plan = PlanMaximo.calcular(todos, bloqueos: bloqueos)
        func linea(_ el: Elemento, _ marca: String, nota: String = "") {
            let maximo = el.nivel == .maximo ? " · Modo máximo" : ""
            print("    \(marca) \(Formato.bytes(el.bytesLiberables).padding(toLength: 10, withPad: " ", startingAt: 0)) \(el.riesgo.etiqueta.padding(toLength: 8, withPad: " ", startingAt: 0)) \(el.nombre)\(maximo)\(nota)")
        }
        func bloque(_ titulo: String, _ lista: [Elemento], marca: String, notas: (Elemento) -> String = { _ in "" }) {
            print("\n  \(titulo) — \(Formato.bytes(Totales.sumaSinRepetir(lista))) (\(lista.count) \(lista.count == 1 ? "elemento" : "elementos"))")
            for el in lista { linea(el, marca, nota: notas(el)) }
            for c in PlanMaximo.costes(lista) where marca == "[x]" { print("    Coste: \(c)") }
        }
        print("\n▶︎ Liberar al máximo (lo que haría; no se ejecuta nada)\(p.fiable ? "" : " · NO se pudo ver qué está en uso: no se marcaría nada")")
        bloque("Se regenera solo o ya no se usa", plan.regenera, marca: "[x]")
        bloque("Sin borrar nada: comprimir, unir copias y compactar", plan.sinBorrar, marca: "[x]")
        bloque("Se vuelve a descargar o a recompilar", plan.cuesta, marca: "[x]")
        let porID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let deApps = bloqueos.map { b in (b, b.elementos.compactMap { porID[$0] }) }
        print("\n  Cerrando apps (solo tras un clic en «Cerrar y limpiar», app por app) — \(Formato.bytes(Totales.sumaSinRepetir(deApps.flatMap(\.1))))")
        for (b, lista) in deApps {
            print("    \(b.nombre) (\(b.bundleID)): \(Formato.bytes(Totales.sumaSinRepetir(lista))) — \(Formato.listaCorta(lista.map(\.nombre), maximo: 4))")
        }
        bloque("No lo marco: puede ser valioso o no se puede recuperar (Revisar y Cuidado)", plan.nunca, marca: "[ ]")
        bloque("Se queda fuera por ahora (Seguro, pero en uso, reciente, con un aviso, desmarcado a mano o salidas de un proyecto activo)", plan.fuera, marca: "[ ]") { el in
            if el.desmarcadoAMano { return "  — lo desmarcaste tú" }
            if let quien = el.usadoPor, el.abiertoAhora { return "  — en uso por \(quien)" }
            if let m = el.avisos.first ?? el.motivos.last(where: { $0.nivel == .info }) { return "  — \(m.etiqueta)" }
            return ""
        }
        let total = Totales.sumaSinRepetir(plan.aLimpiar())
        let normal = Totales.sumaSinRepetir(plan.regenera + plan.sinBorrar.filter { $0.nivel == .normal })
        let cerrando = Totales.sumaSinRepetir(plan.aLimpiar() + deApps.flatMap(\.1))
        print("\n  Total al máximo: \(Formato.bytes(total)) · cerrando además las apps: \(Formato.bytes(cerrando)) · solo el nivel normal: \(Formato.bytes(normal))")
        if !plan.aLimpiar().allSatisfy({ $0.riesgo == .seguro }) { print("  ✗ ERROR: algo que no es Seguro entraría solo") }
    }
}
