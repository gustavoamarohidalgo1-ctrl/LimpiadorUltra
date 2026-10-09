import Foundation

/// Todo lo que el análisis sabe del Mac en este momento.
struct Contexto {
    let indice: Indice
    let apps: AppsInstaladas
    let procesos: Procesos
    let accesoTotal: Bool
    let memoria = Memoria()
}

/// Lo que una categoría descubre y otra necesita saber.
final class Memoria: @unchecked Sendable {
    /// Archivos que son clones de APFS: comparten espacio con otra copia.
    var clones: [String: String] = [:]
    /// Archivos de dentro de build/, dist/… que son copia de uno del proyecto: el original sigue ahí.
    var copias: Set<String> = []
}

/// Revisa cada elemento con reglas generales (contenido, claves, código, uso actual…)
/// y decide su riesgo final. Nunca baja un riesgo: solo lo sube y explica por qué.
enum Evaluador {
    /// Categorías donde encontrar archivos personales es mala señal.
    private static let revisarContenido: Set<Categoria> = [.restos, .herramientas, .cachesApps, .registros, .sistema, .olvidados]
    private static let palabrasRespaldo = ["respaldo", "backup", "copia de seguridad", "copias de seguridad", "evidencia", "evidence"]
    /// En «Compilaciones» solo se ven los repositorios que hay dentro de build/, dist/…, nunca el del propio proyecto.
    private static let revisarCodigo: Set<Categoria> = [.restos, .herramientas, .cachesApps, .registros, .grandes, .sistema, .olvidados,
                                                        .proyectos]
    /// Copias de dependencias que los gestores de paquetes descargan con su historial: se vuelven a descargar.
    /// (Se buscan solo dentro de la carpeta de compilación, no en la ruta de tus carpetas.)
    private static let checkoutsDeDependencias = ["/node_modules/", "/Pods/", "/.build/checkouts/", "/SourcePackages/checkouts/",
                                                  "/Carthage/Checkouts/", "/_deps/", "-prefix/src/", "/deps/", "/.terraform/modules/",
                                                  "/bower_components/"]
    /// Categorías donde algo modificado hace minutos indica que se está usando.
    private static let revisarActividad: Set<Categoria> = [.restos, .herramientas, .grandes, .duplicados, .sistema, .olvidados, .desarrollo, .registros,
                                                           .comprimir]

    static func evaluar(_ el: inout Elemento, _ c: Contexto) {
        let riesgoInicial = el.riesgo
        var nuevos: [Motivo] = []
        var riesgo = el.riesgo
        // Lo que se mira por dentro: lo que se borra, la Papelera o lo que mide el índice (simuladores, git). Los temporales
        // sueltos de una app no se miran por su carpeta (/var/folders/…/T), que comparten todos los programas.
        // Lo que se comprime, se une con sus copias o se deja solo en iCloud tampoco: no se borra nada, así que lo de
        // dentro (archivos tuyos, claves, código, la nube) no corre ningún riesgo y las reglas 1 a 5, 8 y 9 no tienen nada
        // que mirar. Solo cuentan la actividad reciente (6), lo que lo está usando (7) y poder comprobarlo (10).
        let rutas: [URL]
        switch el.accion {
        case .borrar, .vaciarPapelera: rutas = el.rutas
        case .borrarSueltos, .comprimir, .clonar, .quitarDescarga: rutas = []
        default: rutas = el.rutas.filter { c.indice.estaIndexada($0.path) }
        }
        el.contenido = c.indice.contenido(de: rutas)

        // 1. Llaves de firma, certificados y contraseñas.
        let sensibles = c.indice.sensibles(dentro: rutas).filter { !c.memoria.copias.contains($0.ruta) }
        // En Library, una clave es la sesión o las credenciales de la propia app; fuera, son tuyas.
        let deApps = sensibles.filter { $0.zona == .library && $0.tipo != .firebase }
        let tuyas = sensibles.filter { $0.zona != .library }
        let keystores = tuyas.filter { $0.tipo == .keystore }
        let secretos = tuyas.filter { $0.tipo == .certificado || $0.tipo == .llaveSSH || $0.tipo == .secreto }
        let firebase = sensibles.filter { $0.tipo == .firebase }
        if !keystores.isEmpty {
            nuevos.append(.peligro("key.fill", "Keystore",
                "Contiene \(Formato.listaCorta(keystores.map(\.nombre))): la llave con la que firmas apps de Android. Si es la de Play Store y la pierdes, no podrás publicar más actualizaciones de esa app."))
            riesgo = .cuidado
        }
        if !secretos.isEmpty {
            nuevos.append(.peligro("lock.fill", "Claves",
                "Contiene claves o contraseñas: \(Formato.listaCorta(secretos.map(\.nombre))). Guárdalas en otro sitio antes de borrar."))
            riesgo = .cuidado
        }
        if !deApps.isEmpty {
            nuevos.append(.aviso("person.badge.key.fill", "Sesión guardada",
                "Guarda credenciales de la app (\(Formato.listaCorta(deApps.map(\.nombre)))): normalmente tu sesión iniciada. Si la app ya no está, no sirven de nada; si la vuelves a instalar, tendrás que iniciar sesión otra vez."))
            riesgo = max(riesgo, .revisar)
        }
        if !firebase.isEmpty {
            nuevos.append(.aviso("flame.fill", "Firebase",
                "Contiene la configuración de Firebase (\(Formato.listaCorta(firebase.map(\.nombre)))). Se puede volver a descargar desde la consola de Firebase."))
            riesgo = max(riesgo, .revisar)
        }

        // 2. Código fuente con historial (repositorios git).
        if revisarCodigo.contains(el.categoria) {
            var repos = c.indice.repos(dentro: rutas)
            if el.categoria == .proyectos {
                repos = repos.filter { r in
                    // La ruta desde la carpeta de compilación (incluida), para que «~/deps/MiProyecto» no oculte nada.
                    guard let base = rutas.first(where: { r.hasPrefix($0.path + "/") })?.path else { return true }
                    let dentro = "/" + Rutas.nombre(base) + String(r.dropFirst(base.count)) + "/"
                    return !checkoutsDeDependencias.contains { dentro.contains($0) }
                }
            }
            if !repos.isEmpty {
                let nombres = repos.map { Rutas.nombre($0) }
                nuevos.append(.peligro("chevron.left.forwardslash.chevron.right", "Código",
                    "Contiene \(repos.count == 1 ? "un proyecto" : "\(repos.count) proyectos") con código e historial (git): \(Formato.listaCorta(nombres))."))
                riesgo = .cuidado
            }
        }

        // 3. Archivos personales donde no deberían estar.
        if revisarContenido.contains(el.categoria) && el.contenido.esPersonal {
            let grave = el.categoria == .restos || el.categoria == .herramientas
            let texto = "Contiene \(el.contenido.resumenPersonal). Comprueba que no sean tuyos antes de borrarlo."
            nuevos.append(grave ? .peligro("doc.richtext.fill", "Archivos tuyos", texto) : .aviso("doc.richtext.fill", "Archivos tuyos", texto))
            riesgo = max(riesgo, grave ? .cuidado : .revisar)
        }
        if (el.categoria == .restos || el.categoria == .herramientas) && el.contenido.bases > 0 {
            nuevos.append(.info("cylinder.split.1x2.fill", "Datos guardados",
                "Tiene \(el.contenido.bases == 1 ? "una base de datos" : "\(el.contenido.bases) bases de datos"): normalmente historial, sesiones o ajustes de la app."))
        }

        // 4. Apps compiladas para publicar.
        let releases = c.indice.releases(dentro: rutas)
        if !releases.isEmpty && el.categoria != .instaladores {
            nuevos.append(.aviso("shippingbox.and.arrow.backward.fill", "App para publicar",
                "Contiene \(Formato.listaCorta(releases.map { Rutas.nombre($0) })): una app compilada para publicar. Si aún no la subiste a la tienda, guárdala antes (o vuelve a compilarla)."))
            riesgo = max(riesgo, .revisar)
        }

        // 5. Carpetas de respaldo: lo que hay dentro puede ser la única copia de algo.
        let respaldo = rutas.first { u in
            let p = u.path.lowercased()
            return palabrasRespaldo.contains { p.contains("/\($0)") || p.contains("_\($0)") || p.contains("-\($0)") || p.contains(" \($0)") }
        }
        if let respaldo, el.categoria != .emuladores {
            nuevos.append(.aviso("externaldrive.badge.timemachine", "Respaldo",
                "Está dentro de una carpeta de respaldo (\(Formato.rutaCorta(respaldo.deletingLastPathComponent()))): puede ser la única copia de algo que guardaste a propósito."))
            riesgo = max(riesgo, .revisar)
        }

        // 6. Actividad muy reciente.
        if let fecha = el.ultimoUso, Self.revisarActividad.contains(el.categoria) {
            let minutos = Date().timeIntervalSince(fecha) / 60
            if minutos < 60 {
                nuevos.append(.aviso("clock.badge.exclamationmark.fill", "En uso",
                    "Se modificó hace \(max(1, Int(minutos))) minutos: algo lo está usando ahora mismo."))
                riesgo = max(riesgo, .revisar)
            }
        }

        // 7. Algo lo está usando en este momento: una app, un programa o un archivo abierto ahí dentro.
        if let uso = el.enUso, let quien = c.procesos.quienUsa(uso) {
            el.abiertoAhora = true
            el.usadoPor = quien
            switch uso {
            case .simulador where !c.procesos.simuladoresConocidos:
                nuevos.append(.peligro("play.circle.fill", "Sin comprobar",
                    "Xcode no me dijo qué simuladores están encendidos, así que no sé si este lo está. No lo tocaré hasta poder comprobarlo."))
            case .emulador where quien != uso.descripcion:
                // No está encendido, pero un programa (Android Studio, adb…) tiene abierto algo de su carpeta.
                nuevos.append(.aviso("macwindow.badge.plus", "Abierto por \(quien)",
                    "\(quien) tiene abierto algo de este emulador ahora mismo. Ciérralo antes de limpiar; si sigue abierto, me saltaré este elemento."))
            case .emulador, .simulador:
                nuevos.append(.peligro("play.circle.fill", "Encendido",
                    "\(uso.descripcion) está encendido. Apágalo antes de limpiar; si sigue encendido, no lo tocaré."))
            case .gradle:
                nuevos.append(.aviso("macwindow.badge.plus", "Gradle trabajando",
                    "Gradle está funcionando (Android Studio abierto o compilando). Ciérralo antes de limpiar; si sigue activo, me saltaré este elemento."))
            case .gradleVersion(let v):
                let que = quien == "Gradle \(v)" ? "Un daemon de Gradle \(v) está funcionando (Android Studio abierto o compilando); las demás versiones no se ven afectadas"
                    : quien == "Gradle" ? "Hay un Gradle funcionando y no pude saber qué versión usa, así que no toco ninguna"
                    : "\(quien) tiene abiertos archivos de Gradle \(v)"
                nuevos.append(.aviso("macwindow.badge.plus", "Gradle \(v) trabajando",
                    "\(que). Ciérralo antes de limpiar; si sigue activo, me saltaré este elemento."))
            case .proceso(let nombre, _):
                nuevos.append(.aviso("macwindow.badge.plus", "\(nombre) en uso",
                    "\(nombre) se está ejecutando ahora. Ciérralo antes de limpiar; si sigue en marcha, me saltaré este elemento."))
            case .rutas:
                nuevos.append(.aviso("macwindow.badge.plus", "En uso por \(quien)",
                    "\(quien) lo está usando ahora mismo (se ejecuta desde ahí, tiene archivos abiertos dentro o trabaja en esa carpeta). Ciérralo antes de limpiar; si sigue en marcha, me saltaré este elemento."))
            case .programas:
                nuevos.append(.aviso("macwindow.badge.plus", "\(quien) en marcha",
                    "\(quien) se está ejecutando ahora y puede necesitar esto. Espera a que termine; si sigue en marcha al limpiar, me saltaré este elemento."))
            case .proyecto(let nombre, _):
                nuevos.append(.aviso("macwindow.badge.plus", "En uso por \(quien)",
                    "\(quien) está trabajando en \(nombre) ahora mismo (lo tiene abierto, compila o tiene archivos abiertos dentro). Ciérralo antes de limpiar; si sigue en marcha, me saltaré este elemento."))
            case .carpetaTemporal:
                nuevos.append(.aviso("macwindow.badge.plus", "En uso por \(quien)",
                    "\(quien) lo está usando ahora mismo: trabaja ahí dentro, tiene archivos o un socket abiertos, o guardó ahí su número de proceso (.pid) y sigue vivo. Espera a que termine; si sigue en marcha al limpiar, me saltaré este elemento."))
            case .app:
                nuevos.append(.aviso("macwindow.badge.plus", "\(quien) abierta",
                    "\(quien) está abierta. Ciérrala antes de limpiar; si sigue abierta, me saltaré este elemento para no causarle problemas."))
            case .appInstalada(let nombre, _, _):
                let que = quien == nombre ? "\(nombre) está abierta (o algo suyo está funcionando)"
                    : "\(quien) está usando \(nombre) ahora mismo (algo suyo está funcionando o se está actualizando)"
                nuevos.append(.aviso("macwindow.badge.plus", "En uso por \(quien)",
                    "\(que). Una app solo se comprime cerrada: ciérrala antes; si sigue en uso al limpiar, me la saltaré."))
            }
        } else if let quien = c.procesos.abiertos.hayAbierto(dentroDe: el.rutasVigiladas) {
            el.abiertoAhora = true
            el.usadoPor = quien
            nuevos.append(.aviso("macwindow.badge.plus", "Abierto por \(quien)",
                "\(quien) tiene abierto algo de aquí dentro ahora mismo (un archivo, o trabaja en esta carpeta). Ciérralo antes de limpiar; si sigue abierto, me saltaré este elemento."))
        }

        // 8. Clones de APFS (copias que usan los mismos bloques del disco): lo que comparte con otra copia que se
        //    queda no se libera al borrarlo. Si libera menos del 10 % de lo que liberaría sin esas copias, no se
        //    marca solo. Las copias que están todas dentro sí se liberan, aunque el disco las guarde una vez.
        let otra = rutas.lazy.compactMap({ c.memoria.clones[$0.path] }).first
        let libera = el.bytesLiberables
        let pocoLibera = el.liberable != nil && el.retenido > 0 && libera * 10 < libera + el.retenido
        if pocoLibera || (el.liberable == nil && otra != nil) {
            let cuanto = el.liberable != nil ? " (libera \(Formato.bytes(libera)) de los \(Formato.bytes(el.tamano)) que ocupa)" : ""
            nuevos.append(.aviso("square.on.square.dashed", "No libera espacio", otra.map {
                "Es un clon de \(Formato.rutaCorta($0)): los dos comparten el mismo espacio en disco, así que borrar solo este no libera casi nada\(cuanto)."
            } ?? "Comparte casi todo su espacio con otros archivos que se quedan (clones de APFS: copias que usan los mismos bloques del disco), así que borrarlo no libera casi nada\(cuanto). Ese espacio solo vuelve cuando ya no queda ninguna copia."))
        } else if el.liberable != nil {
            let dentro = el.tamano - libera - el.retenido   // copias de dentro, que el disco guarda una vez
            if el.retenido > max(1_000_000, el.tamano / 20) {
                nuevos.append(.info("square.on.square.dashed", "Libera menos",
                    "Comparte \(Formato.bytes(el.retenido)) con otros archivos que se quedan (clones de APFS: copias que usan los mismos bloques del disco): borrarlo libera unos \(Formato.bytes(libera)) de los \(Formato.bytes(el.tamano)) que ocupa."))
            } else if dentro > max(1_000_000, el.tamano / 20) {
                nuevos.append(.info("square.on.square.dashed", "Copias dentro",
                    "Dentro hay copias que comparten los mismos bloques del disco (clones de APFS): contando cada copia ocupa \(Formato.bytes(el.tamano)), pero el disco las guarda una vez y borrarlo libera unos \(Formato.bytes(libera))."))
            }
        }

        // 9. En la nube: borrar aquí lo borra en todos tus dispositivos.
        if rutas.contains(where: { $0.path.contains("/Library/Mobile Documents/") || $0.path.contains("/Library/CloudStorage/") }) {
            nuevos.append(.peligro("icloud.fill", "En la nube",
                "Está en iCloud Drive o en una carpeta sincronizada: si lo borras aquí, se borra en todos tus dispositivos."))
            riesgo = .cuidado
        }

        // 10. Sin saber qué programas están funcionando no se puede asegurar que nada lo use: no se marca solo.
        if !c.procesos.fiable && el.seleccionado {
            nuevos.append(.aviso("questionmark.app.dashed", "Sin comprobar",
                "No pude ver qué programas están funcionando, así que no sé si algo lo usa y no lo marco solo. Si sabes que nada lo usa, márcalo tú: al limpiar lo volveré a comprobar."))
        }

        el.motivos.append(contentsOf: nuevos)
        el.motivos.sort { $0.nivel > $1.nivel }
        el.riesgo = max(el.riesgo, riesgo)
        // Lo que se marcaría si nada lo estuviera usando (para «Liberar al máximo» y «Cerrar y limpiar»): lo que marcó
        // quien lo encontró, si sigue siendo Seguro y no tiene más avisos que los de uso (regla 7) o de no haber podido
        // comprobarlo (regla 10), que se vuelven a mirar en el momento de limpiar.
        el.marcable = el.seleccionado && el.riesgo == .seguro
            && !nuevos.contains { $0.nivel >= .aviso && !Self.iconosDeUso.contains($0.icono) }
        if el.riesgo > riesgoInicial || nuevos.contains(where: { $0.nivel >= .aviso }) {
            el.seleccionado = false
        }
    }

    /// Los iconos de los avisos que dicen que algo lo usa ahora mismo (regla 7) o que no se pudo comprobar (regla 10):
    /// dejan de valer cuando se vuelve a mirar y ya nada lo usa (`Elemento.comprobarUso`).
    static let iconosDeUso: Set<String> = ["macwindow.badge.plus", "play.circle.fill", "questionmark.app.dashed"]

    /// Evaluación rápida de cualquier carpeta (para el explorador): qué hay dentro que convenga conservar.
    static func avisosRapidos(de url: URL, indice: Indice) -> [String] {
        var r: [String] = []
        let s = indice.sensibles(dentro: [url])
        if s.contains(where: { $0.tipo == .keystore }) { r.append("un keystore de Android") }
        if s.contains(where: { $0.tipo != .keystore && $0.tipo != .firebase }) { r.append("claves o contraseñas") }
        let repos = indice.repos(dentro: [url])
        if s.contains(where: { $0.tipo == .firebase }) { r.append("configuración de Firebase") }
        if !repos.isEmpty { r.append(repos.count == 1 ? "un proyecto con código (git)" : "\(repos.count) proyectos con código (git)") }
        let c = indice.contenido(de: [url])
        if c.esPersonal { r.append(c.resumenPersonal) }
        if !indice.releases(dentro: [url]).isEmpty { r.append("apps compiladas para publicar") }
        return r
    }
}
