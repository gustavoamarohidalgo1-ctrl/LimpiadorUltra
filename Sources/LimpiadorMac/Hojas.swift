import SwiftUI

struct HojaConfirmacion: View {
    @EnvironmentObject var almacen: Almacen
    @Environment(\.dismiss) private var cerrar
    @State private var modo: ModoLimpieza = .papelera
    @State private var entendido = false

    var body: some View {
        let sel = almacen.efectivos
        let seguros = sel.filter { $0.riesgo == .seguro }
        let revisar = sel.filter { $0.riesgo == .revisar }
        let cuidado = sel.filter { $0.riesgo == .cuidado }
        let abiertos = sel.filter { $0.abiertoAhora }
        let irreversibles = sel.filter { $0.accion.esIrreversible }
        let comprimir = sel.filter { $0.accion.noBorraNada && !$0.accion.une && !$0.accion.quitaDescarga && !$0.accion.comprimeApps }
        let apps = sel.filter { $0.accion.comprimeApps }
        let nube = sel.filter { $0.accion.quitaDescarga }
        let unir = sel.filter { $0.accion.une }
        let comandos = sel.compactMap { $0.accion.lineaDeComando }

        VStack(alignment: .leading, spacing: 16) {
            if almacen.limpiando {
                ProgresoLimpieza()
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("Limpiar \(Formato.bytes(almacen.bytesSeleccionados))").font(.title.weight(.bold))
                        Text("\(sel.count) elementos seleccionados").foregroundStyle(.secondary)
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GrupoRiesgo(riesgo: .seguro, elementos: seguros, resumido: true)
                        GrupoRiesgo(riesgo: .revisar, elementos: revisar, resumido: false)
                        GrupoRiesgo(riesgo: .cuidado, elementos: cuidado, resumido: false)
                    }
                }
                .frame(maxHeight: 300)

                if !abiertos.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "bolt.circle.fill").foregroundStyle(.orange).font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hay \(abiertos.count) \(abiertos.count == 1 ? "elemento" : "elementos") en uso ahora mismo")
                                .font(.callout.weight(.semibold))
                            Text("Cierra \(Formato.listaCorta(Array(Set(abiertos.compactMap { $0.usadoPor ?? $0.dueno })).sorted())) antes de limpiar. Si siguen abiertas, me saltaré sus archivos para no causarles problemas.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Comprobar otra vez") { almacen.comprobarAppsAbiertas() }
                            .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                // Apps abiertas que no dejan limpiar cachés seguras (que no están marcadas por eso): se cierran una a una,
                // solo si pulsas su botón.
                AppsQueBloquean(niveles: [.normal], modo: modo, maximo: false)

                if !comprimir.isEmpty {
                    Label("\(Formato.listaCorta(comprimir.map(\.nombre))) no \(comprimir.count == 1 ? "borra" : "borran") nada: \(comprimir.count == 1 ? "guarda" : "guardan") comprimidos archivos que llevan días sin cambios y se leen igual. Va al final, tarda un poco y lo puedes detener.",
                          systemImage: "rectangle.compress.vertical")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !apps.isEmpty {
                    Label(apps.count == 1
                          ? "Comprimir \(apps[0].dueno ?? apps[0].nombre) no cambia ningún archivo: se abre igual y compruebo su firma antes y después. Solo con la app cerrada; macOS puede pedir el permiso «Gestión de apps». Si después no se abre bien, la descomprimes en Análisis › Descomprimir una app."
                          : "Comprimir \(Formato.listaCorta(apps.compactMap(\.dueno))) no cambia ningún archivo: se abren igual y compruebo su firma antes y después. Solo con las apps cerradas; macOS puede pedir el permiso «Gestión de apps». Si una no se abre bien, la descomprimes en Análisis › Descomprimir una app.",
                          systemImage: "app.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !unir.isEmpty {
                    Label("Unir \(unir.count == 1 ? "un grupo" : "\(unir.count) grupos") de copias idénticas no borra nada: cada copia sigue en su sitio y el disco guarda su contenido una sola vez. Antes de cambiar cada una la comparo byte a byte.",
                          systemImage: "square.on.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !nube.isEmpty {
                    Label("Quitar las copias locales de iCloud no borra nada: los archivos siguen en iCloud y en su carpeta, y se descargan al abrirlos (necesita internet). Antes de quitar cada una compruebo que esté subida y sin cambios.",
                          systemImage: "icloud.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !comandos.isEmpty {
                    Label("Ejecuto \(comandos.count == 1 ? "el comando oficial" : "los comandos oficiales") \(Formato.lista(comandos.map { "«\($0)»" })): lo que quitan lo decide la propia herramienta, y lo que digan queda en el historial.",
                          systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !irreversibles.isEmpty {
                    Label("\(Formato.listaCorta(irreversibles.map(\.nombre))) no \(irreversibles.count == 1 ? "pasa" : "pasan") por la Papelera: se \(irreversibles.count == 1 ? "borra" : "borran") al instante y no se puede deshacer.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $modo) {
                        ForEach(ModoLimpieza.allCases) { Text($0.titulo).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(modo.descripcion).font(.caption).foregroundStyle(.secondary)
                    Text(cuantoLibera).font(.caption.weight(.medium))
                }

                if !cuidado.isEmpty {
                    Toggle(isOn: $entendido) {
                        Text("Revisé lo marcado como «Cuidado» y quiero borrarlo")
                            .font(.callout.weight(.medium))
                    }
                    .toggleStyle(.checkbox)
                }

                HStack {
                    Spacer()
                    Button("Cancelar") { cerrar() }
                        .keyboardShortcut(.cancelAction)
                    Button(role: modo == .definitivo ? .destructive : nil) {
                        almacen.limpiar(modo: modo)
                    } label: {
                        Text(modo == .papelera ? "Mover a la Papelera" : "Eliminar definitivamente")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(modo == .definitivo ? .red : .accentColor)
                    .disabled(!cuidado.isEmpty && !entendido)
                    .help("Hay que hacer clic: por seguridad, la tecla Enter no borra nada")
                }
            }
        }
        .padding(24)
        .frame(width: 580)
        .onAppear { almacen.comprobarAppsAbiertas() }
        .onChange(of: almacen.resultado != nil) { _, hay in
            if hay { cerrar() }
        }
    }

    /// Lo que libera de verdad cada modo (sin lo que comparten con clones que se quedan).
    private var cuantoLibera: String {
        let total = almacen.bytesSeleccionados
        let alInstante = almacen.bytesAlInstante
        // Lo que no pasa por la Papelera (simuladores, git, comprimir…) se libera igual en los dos modos. Se calcula como
        // la diferencia para no contar lo que se comprime y a la vez se borra.
        let sinPapelera = max(0, total - Totales.sumaSinRepetir(almacen.efectivos.filter { $0.accion == .borrar }))
        switch modo {
        case .papelera:
            return sinPapelera > 0
                ? "Ahora se liberan unos \(Formato.bytes(sinPapelera)) (lo que no pasa por la Papelera); el resto, unos \(Formato.bytes(max(0, total - sinPapelera))), al vaciar la Papelera."
                : "Ahora no se libera nada: unos \(Formato.bytes(total)) se liberan al vaciar la Papelera."
        case .definitivo:
            return total > alInstante
                ? "Se liberan unos \(Formato.bytes(alInstante)) al instante; los \(Formato.bytes(total - alInstante)) de Revisar, Cuidado y las apps, al vaciar la Papelera."
                : "Se liberan unos \(Formato.bytes(total)) al instante."
        }
    }

}

/// «Liberar al máximo»: todo lo que se puede liberar, por niveles y con lo que cuesta cada uno, antes de hacerlo. Solo
/// entra lo Seguro; lo que puede ser valioso (Revisar y Cuidado) se enseña aparte y nunca se marca solo. Al abrirse vuelve
/// a mirar qué está en uso; al limpiar, Limpiador lo comprueba otra vez antes de tocar cada cosa.
struct HojaMaximo: View {
    @EnvironmentObject var almacen: Almacen
    @Environment(\.dismiss) private var cerrar
    /// Lo más alto que puede ser la lista de bloques antes de desplazarse.
    var altoLista: CGFloat = 520
    @State private var conSinBorrar = true
    @State private var conCoste = true
    @State private var conAMano = true
    @State private var entendido = false

    var body: some View {
        let plan = PlanMaximo.calcular(almacen.elementos, bloqueos: almacen.bloqueos)
        let lista = plan.aLimpiar(sinBorrar: conSinBorrar, cuesta: conCoste, aMano: conAMano)
        let total = Totales.sumaSinRepetir(lista)
        let conCuidado = conAMano && plan.aMano.contains { $0.riesgo == .cuidado }
        VStack(alignment: .leading, spacing: 14) {
            if almacen.limpiando {
                ProgresoLimpieza()
            } else {
                encabezado(total: total, cuantos: lista.count)
                resumen(plan)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        BloqueMaximo(icono: "arrow.triangle.2.circlepath", titulo: "Se regenera solo o ya no se usa",
                                     explicacion: "Lo mismo que marca el modo normal: cachés, temporales, intermedios de compilación y versiones que ya nada usa. Sigues trabajando igual; lo único que puede pedir internet son las cachés de descargas (npm, pip, Homebrew…), que se vuelven a bajar solas la próxima vez que instales algo."
                                        + (PlanMaximo.borraSalidas(plan.regenera) ? " De los proyectos que no tocas hace más de un mes se borra también lo que entregas y sus informes (se rehacen al compilar)." : ""),
                                     elementos: plan.regenera, color: .green)
                        BloqueMaximo(icono: "rectangle.compress.vertical", titulo: "Sin borrar nada: comprimir, unir copias y compactar",
                                     explicacion: "Los archivos se quedan en su sitio y se leen igual: se guardan comprimidos (también tus apps cerradas y tus informes y entregas) o, si son copias idénticas, el disco guarda una sola. Y git empaqueta el historial de tus proyectos sin borrar nada de él. Comprimir y unir van al final.",
                                     elementos: plan.sinBorrar, color: .blue, incluir: $conSinBorrar)
                        BloqueMaximo(icono: "arrow.down.circle", titulo: "Se vuelve a descargar o a recompilar",
                                     explicacion: PlanMaximo.borraSalidas(plan.cuesta)
                                        ? "Cuesta algo: volver a descargar dependencias o lo que dejes solo en iCloud, compilar desde cero lo que usaste hace unas horas, rehacer temporales recientes. Y de algún proyecto que no tocas hace más de un mes se borra también lo que entregas y sus informes (se rehacen al compilar)."
                                        : "No se pierde nada, pero cuesta algo: volver a descargar dependencias o lo que dejes solo en iCloud, compilar desde cero lo que usaste hace unas horas, rehacer temporales recientes.",
                                     elementos: plan.cuesta, color: .orange, incluir: $conCoste)
                        if !plan.aMano.isEmpty {
                            BloqueMaximo(icono: "hand.point.up.left", titulo: "Lo que marcaste tú",
                                         explicacion: "Lo que no es Seguro va a la Papelera (puedes deshacerlo); lo Seguro se elimina como lo demás.",
                                         elementos: plan.aMano, color: .purple, incluir: $conAMano)
                        }
                        AppsQueBloquean(niveles: conCoste ? [.normal, .maximo] : [.normal], modo: .definitivo, maximo: true)
                        ListaAparte(icono: "xmark.shield", titulo: "No lo marco: puede ser valioso o no se puede recuperar",
                                    explicacion: "Revisar y Cuidado: tus archivos, proyectos con algo que no se regenera, historiales, emuladores con datos… Nunca lo marco solo, ni aquí. Si quieres borrar algo, míralo y márcalo tú.",
                                    elementos: plan.nunca, razon: { $0.avisos.first?.etiqueta ?? $0.motivos.first?.etiqueta ?? "" }) { el in
                            almacen.irA(el)
                            cerrar()
                        }
                        ListaAparte(icono: "clock", titulo: "Se queda fuera por ahora",
                                    explicacion: "Es Seguro, pero algo lo está usando, cambió hace muy poco, tiene algún aviso, lo desmarcaste tú o son las salidas (APK, informes…) de un proyecto en el que trabajas. Vuelve a analizar más tarde (o márcalo tú si lo quieres).",
                                    elementos: plan.fuera, razon: Self.porQueFuera) { el in
                            almacen.irA(el)
                            cerrar()
                        }
                    }
                }
                .frame(maxHeight: altoLista)

                avisos
                if conCuidado {
                    Toggle(isOn: $entendido) {
                        Text("Revisé lo marcado como «Cuidado» y quiero borrarlo").font(.callout.weight(.medium))
                    }
                    .toggleStyle(.checkbox)
                }
                HStack {
                    if almacen.comprobando {
                        ProgressView().controlSize(.small)
                        Text("Comprobando qué está en uso…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancelar") { cerrar() }
                        .keyboardShortcut(.cancelAction)
                    Button("Solo marcarlo") {
                        almacen.seleccionarMaximo(lista)
                        cerrar()
                    }
                    .disabled(lista.isEmpty || almacen.comprobando)
                    .help("Marca todo esto en las listas para que lo revises; luego limpias con «Limpiar» y eliges si va a la Papelera")
                    Button(role: .destructive) {
                        almacen.liberarAlMaximo(lista)
                    } label: {
                        Text("Liberar \(Formato.bytes(total))")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(lista.isEmpty || almacen.comprobando || (conCuidado && !entendido))
                    .help("Hay que hacer clic: por seguridad, la tecla Enter no borra nada")
                }
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear { almacen.comprobarAppsAbiertas() }
        .onChange(of: almacen.resultado != nil) { _, hay in
            if hay { cerrar() }
        }
    }

    private func encabezado(total: Int64, cuantos: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "bolt.circle.fill").font(.system(size: 34)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Liberar al máximo: \(Formato.bytes(total))").font(.title.weight(.bold))
                Text("\(cuantos) \(cuantos == 1 ? "elemento" : "elementos"). Solo marco lo que es Seguro, nivel por nivel, y te digo lo que cuesta cada uno. Lo que puede ser valioso nunca lo marco solo.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Lo que hay más abajo en la lista, para que no pase desapercibido: lo que marcaste tú, las apps que bloquean algo y lo
    /// que no se marca.
    private func resumen(_ plan: PlanMaximo) -> some View {
        let apps = almacen.appsParaCerrar(niveles: conCoste ? [.normal, .maximo] : [.normal]).filas.filter { almacen.cierres[$0.bundleID] == nil }
        var partes: [String] = []
        if !plan.aMano.isEmpty {
            let delicados = plan.aMano.filter { $0.riesgo != .seguro }.count
            partes.append("\(plan.aMano.count) que marcaste tú\(delicados > 0 ? " (\(delicados) de Revisar o Cuidado: a la Papelera)" : "")")
        }
        if !apps.isEmpty { partes.append(apps.count == 1 ? "1 app abierta que bloquea algo" : "\(apps.count) apps abiertas que bloquean algo") }
        if !plan.nunca.isEmpty { partes.append("lo que no marco (\(Formato.bytes(Totales.sumaSinRepetir(plan.nunca))))") }
        if !plan.fuera.isEmpty { partes.append("lo que se queda fuera por ahora (\(Formato.bytes(Totales.sumaSinRepetir(plan.fuera))))") }
        return Group {
            if !partes.isEmpty {
                Label("Más abajo: \(Formato.lista(partes)).", systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var avisos: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Lo que se regenera, se vuelve a descargar o se recompila se elimina al instante, sin pasar por la Papelera: no se puede deshacer (las apps sí van a la Papelera: nunca las elimino para siempre). Antes de tocar cada cosa vuelvo a comprobar que nada la use y que no haya cambiado desde el análisis, y lo puedes detener entre una y otra.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            if almacen.instantaneas > 0 {
                Label("Hay \(almacen.instantaneas == 1 ? "1 instantánea local" : "\(almacen.instantaneas) instantáneas locales") de Time Machine: lo que borres seguirá ocupando hasta que caduquen.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            if almacen.disco.purgable >= 100_000_000 {
                Label("Aparte, hay \(Formato.bytes(almacen.disco.purgable)) purgables que macOS libera solo cuando le hace falta: no los cuento.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Por qué algo Seguro se queda fuera: quién lo usa, su aviso más grave o su última nota (quien lo encontró añade al
    /// final la razón de no marcarlo: «Usado hace poco», «Sin archivo de bloqueo»…).
    private static func porQueFuera(_ el: Elemento) -> String {
        if el.desmarcadoAMano { return "Lo desmarcaste tú" }
        if el.abiertoAhora { return "En uso por \(el.usadoPor ?? el.dueno ?? "un programa")" }
        return el.avisos.first?.etiqueta ?? el.motivos.last { $0.nivel == .info }?.etiqueta ?? ""
    }
}

/// Un nivel de «Liberar al máximo»: qué es, cuánto libera, algunos de sus elementos y lo que cuesta. Con `incluir`, se
/// puede quitar; sin él, va siempre.
private struct BloqueMaximo: View {
    let icono: String
    let titulo: String
    let explicacion: String
    let elementos: [Elemento]
    var color: Color = .accentColor
    var incluir: Binding<Bool>? = nil

    var body: some View {
        if !elementos.isEmpty {
            let incluido = incluir?.wrappedValue ?? true
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let incluir {
                        Toggle("", isOn: incluir).toggleStyle(.checkbox).labelsHidden()
                    } else {
                        Image(systemName: "checkmark.square.fill").foregroundStyle(.tint)
                            .help("Siempre se incluye: es lo que marca el modo normal")
                    }
                    Label(titulo, systemImage: icono).font(.callout.weight(.semibold))
                    Spacer()
                    Text(Formato.bytes(Totales.sumaSinRepetir(elementos)))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(incluido ? .primary : .secondary)
                }
                Text(explicacion).font(.caption).foregroundStyle(.secondary)
                Text("\(elementos.count) \(elementos.count == 1 ? "elemento" : "elementos"): \(Formato.listaCorta(elementos.map(\.nombre), maximo: 4))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(Formato.listaCorta(elementos.map(\.nombre), maximo: 20))
                ForEach(PlanMaximo.costes(elementos), id: \.self) { coste in
                    Label(coste, systemImage: "info.circle").font(.caption).foregroundStyle(.primary.opacity(0.8))
                }
            }
            .padding(10)
            .background(color.opacity(incluido ? 0.09 : 0.03), in: RoundedRectangle(cornerRadius: 8))
            .opacity(incluido ? 1 : 0.6)
        }
    }
}

/// Lo que «Liberar al máximo» no marca, con su total y la lista para ir a cada elemento.
private struct ListaAparte: View {
    let icono: String
    let titulo: String
    let explicacion: String
    let elementos: [Elemento]
    let razon: (Elemento) -> String
    let irA: (Elemento) -> Void
    @State private var abierta = false

    var body: some View {
        if !elementos.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Label(titulo, systemImage: icono).font(.callout.weight(.semibold))
                    Spacer()
                    Text(Formato.bytes(Totales.sumaSinRepetir(elementos)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(explicacion).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(isExpanded: $abierta) {
                    VStack(spacing: 4) {
                        ForEach(elementos.prefix(60)) { el in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(el.nombre).font(.caption.weight(.medium)).lineLimit(1)
                                    let r = razon(el)
                                    if !r.isEmpty { Text(r).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Formato.bytes(el.bytesLiberables)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                EtiquetaRiesgo(riesgo: el.riesgo)
                                Button("Ver") { irA(el) }
                                    .controlSize(.mini)
                                    .help("Ir a este elemento (cierra esta hoja)")
                            }
                        }
                        if elementos.count > 60 {
                            Text("y \(elementos.count - 60) más…").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(abierta ? "Ocultar la lista" : "Ver la lista (\(elementos.count))").font(.caption)
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Lo que se ve mientras se limpia (también al cerrar una app con «Cerrar y limpiar»), con el botón para detenerlo.
private struct ProgresoLimpieza: View {
    @EnvironmentObject var almacen: Almacen

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(almacen.saliendo ? "Me cierro al terminar…" : almacen.deteniendo ? "Deteniendo…" : "Limpiando…").font(.title2.weight(.bold))
            ProgressView(value: almacen.progresoLimpieza)
            Text(almacen.mensajeLimpieza).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Text("Si lo detienes, lo ya hecho se queda hecho y lo que esté a medias se queda como estaba.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Detener") { almacen.detenerLimpieza() }
                    .disabled(almacen.deteniendo)
            }
        }
    }
}

/// Las apps abiertas que no dejan limpiar elementos Seguro de esos `niveles` (las que bloquean al menos 50 MB), cada una
/// con «Cerrar y limpiar», y las que ya se cerraron (con su resultado y «Volver a abrir»). No se cierra nada sin un clic.
private struct AppsQueBloquean: View {
    @EnvironmentObject var almacen: Almacen
    let niveles: Set<NivelMarcado>
    let modo: ModoLimpieza
    let maximo: Bool
    @State private var saltadas: Set<String> = []

    var body: some View {
        let apps = almacen.appsParaCerrar(niveles: niveles)
        let filas = apps.filas.filter { !saltadas.contains($0.id) }
        if !filas.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Apps abiertas que no dejan limpiar", systemImage: "macwindow.badge.plus")
                    .font(.callout.weight(.semibold))
                Text("No cierro nada sin que pulses su botón. La cierro como con ⌘Q (puede guardar o preguntarte; si no se cierra, no toco nada), espero a que termine, limpio solo lo suyo y luego puedes volver a abrirla.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(filas) { b in
                    FilaCerrarApp(bloqueo: b, niveles: niveles, modo: modo, maximo: maximo) { saltadas.insert(b.id) }
                }
                if apps.resto > 0 {
                    Text("\(apps.resto == 1 ? "Otra app abierta bloquea" : "Otras \(apps.resto) apps abiertas bloquean") \(Formato.bytes(apps.bytesResto)) en total: no compensa cerrarlas.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Una app abierta que bloquea elementos Seguro: «<App> está abierta y bloquea 2,1 GB [Cerrar <App> y limpiar] [Saltar]».
private struct FilaCerrarApp: View {
    @EnvironmentObject var almacen: Almacen
    let bloqueo: BloqueoDeApp
    let niveles: Set<NivelMarcado>
    let modo: ModoLimpieza
    let maximo: Bool
    let saltar: () -> Void

    var body: some View {
        let ids = Set(bloqueo.elementos)
        let lista = almacen.elementos.filter { ids.contains($0.id) && niveles.contains($0.nivel) }
        let cierre = almacen.cierres[bloqueo.bundleID]
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let url = bloqueo.url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "macwindow").font(.title2)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo(cierre, lista)).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(detalle(cierre, lista)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            botones(cierre, lista)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func titulo(_ cierre: CierreDeApp?, _ lista: [Elemento]) -> String {
        switch cierre?.estado {
        case .none: return "\(bloqueo.nombre) está abierta y bloquea \(Formato.bytes(Totales.sumaSinRepetir(lista)))"
        case .cerrando: return "Cerrando \(bloqueo.nombre)…"
        case .noSeCerro: return "\(bloqueo.nombre) no se cerró"
        case .limpiada, .reabierta:
            guard let r = cierre?.resultado else { return "Cerré \(bloqueo.nombre)" }
            return r.modo == .papelera
                ? "Cerré \(bloqueo.nombre) y moví \(Formato.bytes(r.enPapelera)) a la Papelera"
                : "Cerré \(bloqueo.nombre) y liberé \(Formato.bytes(r.liberadoMedido))"
        }
    }

    private func detalle(_ cierre: CierreDeApp?, _ lista: [Elemento]) -> String {
        switch cierre?.estado {
        case .none:
            return "\(Formato.listaCorta(lista.map(\.nombre))). Solo cachés y temporales que la app vuelve a crear; sus datos, sesiones y ajustes no se tocan."
        case .cerrando:
            return "Espero hasta 20 s a que se cierre. Si te pregunta algo (guardar un documento), contéstale."
        case .noSeCerro:
            return "Puede que te esté preguntando si guardas algo o que no quisiera cerrarse. No toqué nada. Nunca la cierro a la fuerza: vuelve a intentarlo cuando quieras."
        case .limpiada:
            guard let r = cierre?.resultado else { return "" }
            let quedan = r.omitidos.count + r.errores.count
            return quedan > 0 ? "\(quedan == 1 ? "Una cosa se quedó" : "\(quedan) cosas se quedaron") sin limpiar: algún ayudante suyo seguía usándolas o no se pudieron borrar."
                              : "Lo suyo ya está limpio; la app lo vuelve a crear a medida que la uses."
        case .reabierta:
            return "Se está abriendo de nuevo."
        }
    }

    @ViewBuilder
    private func botones(_ cierre: CierreDeApp?, _ lista: [Elemento]) -> some View {
        switch cierre?.estado {
        case .none, .noSeCerro:
            VStack(alignment: .trailing, spacing: 4) {
                Button(cierre == nil ? "Cerrar \(bloqueo.nombre) y limpiar" : "Intentar otra vez") {
                    almacen.cerrarYLimpiar(bloqueo, niveles: niveles, modo: modo, maximo: maximo)
                }
                .disabled(almacen.limpiando || lista.isEmpty)
                .help("Cierra \(bloqueo.nombre) como con ⌘Q y limpia solo lo suyo")
                Button("Saltar", action: saltar)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .controlSize(.small)
        case .cerrando:
            ProgressView().controlSize(.small)
        case .limpiada:
            Button("Volver a abrir \(bloqueo.nombre)") { almacen.volverAAbrir(bloqueo.bundleID) }
                .controlSize(.small)
                .disabled(bloqueo.url == nil)
        case .reabierta:
            EmptyView()
        }
    }
}

private struct GrupoRiesgo: View {
    let riesgo: Riesgo
    let elementos: [Elemento]
    let resumido: Bool

    var body: some View {
        if !elementos.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    EtiquetaRiesgo(riesgo: riesgo)
                    Text("\(elementos.count) \(elementos.count == 1 ? "elemento" : "elementos")")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(Formato.bytes(Totales.sumaSinRepetir(elementos)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if resumido {
                    Text(Formato.listaCorta(elementos.sorted { $0.bytesLiberables > $1.bytesLiberables }.map(\.nombre), maximo: 4))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    ForEach(elementos.sorted { $0.bytesLiberables > $1.bytesLiberables }) { el in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(el.nombre).font(.caption.weight(.medium)).lineLimit(1)
                                if let m = el.avisos.first ?? el.motivos.first {
                                    Label(m.texto, systemImage: m.icono)
                                        .font(.caption2)
                                        .foregroundStyle(ColorMotivo.de(m.nivel))
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Formato.bytes(el.bytesLiberables))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help(el.comparteEspacio ? "Ocupa \(Formato.bytes(el.tamano)) contando cada copia, pero parte son clones de APFS: libera \(Formato.bytes(el.bytesLiberables))." : "Lo que se libera al borrarlo")
                        }
                    }
                }
            }
            .padding(10)
            .background(EtiquetaRiesgo.color(riesgo).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct HojaResultado: View {
    @EnvironmentObject var almacen: Almacen
    @Environment(\.dismiss) private var cerrar
    let resultado: ResultadoLimpieza

    /// Lo que fue a la Papelera aunque se pidió eliminarlo: lo de Revisar o Cuidado, y las apps (nunca se eliminan para
    /// siempre).
    private var alaPapelera: String {
        let (n, apps) = (resultado.forzadosAPapelera, resultado.appsAPapelera)
        let cuanto = Formato.bytes(resultado.enPapelera)
        if apps == 0 {
            return "Por seguridad, \(n) \(n == 1 ? "elemento marcado" : "elementos marcados") como Revisar o Cuidado se \(n == 1 ? "movió" : "movieron") a la Papelera en vez de eliminarse (\(cuanto)): se liberan cuando la vacíes."
        }
        let deApps = apps == 1 ? "1 app" : "\(apps) apps"
        if n == 0 {
            return "Las apps nunca las elimino para siempre: \(apps == 1 ? "la app que marcaste se movió" : "las \(apps) apps que marcaste se movieron") a la Papelera (\(cuanto)) y se liberan cuando la vacíes."
        }
        return "Por seguridad, \(n) \(n == 1 ? "elemento" : "elementos") de Revisar o Cuidado y \(deApps) (nunca las elimino para siempre) se movieron a la Papelera en vez de eliminarse (\(cuanto)): se liberan cuando la vacíes."
    }

    var body: some View {
        // Nada se pudo limpiar y algo lo impidió (macOS no dejó borrar, todo estaba en uso…).
        let nada = resultado.elementosLimpiados == 0 && (!resultado.errores.isEmpty || !resultado.omitidos.isEmpty)
        VStack(spacing: 16) {
            Image(systemName: resultado.errores.isEmpty && resultado.omitidos.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(resultado.errores.isEmpty && resultado.omitidos.isEmpty ? .green : .orange)
            if nada {
                Text("No pude liberar nada").font(.title2.weight(.bold))
            } else if resultado.modo == .papelera {
                Text("\(Formato.bytes(resultado.enPapelera)) movidos a la Papelera").font(.title2.weight(.bold))
                Text("Siguen ocupando espacio hasta que vacíes la Papelera. Mientras tanto, puedes deshacerlo.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if resultado.liberadoCalculado > 0 {
                    Text("Lo que no pasa por la Papelera ya se liberó: \(Formato.bytes(resultado.liberadoMedido)), medido en el disco.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            } else {
                Text("¡Listo! Liberaste \(Formato.bytes(resultado.liberadoMedido))")
                    .font(.title2.weight(.bold))
                Text("Liberado de verdad: lo medí en el disco antes y después de limpiar.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if resultado.maximo { cifrasDelMaximo }
                if resultado.forzadosAPapelera > 0 || resultado.appsAPapelera > 0 {
                    Text(alaPapelera).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            if resultado.comprimido > 0 {
                let comprimiendo = resultado.comprimido - resultado.unido
                Text(resultado.unido == 0
                     ? "De eso, \(Formato.bytes(resultado.comprimido)) los ahorré comprimiendo archivos, sin borrar nada: se leen igual."
                     : comprimiendo == 0
                     ? "De eso, \(Formato.bytes(resultado.unido)) los ahorré uniendo copias idénticas, sin borrar ninguna: siguen todas en su sitio."
                     : "De eso, \(Formato.bytes(resultado.comprimido)) los ahorré sin borrar nada: \(Formato.bytes(comprimiendo)) comprimiendo archivos y \(Formato.bytes(resultado.unido)) uniendo copias idénticas.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if resultado.quitadoDeICloud > 0 {
                Text("De eso, \(Formato.bytes(resultado.quitadoDeICloud)) los liberé quitando copias locales de iCloud: siguen en la nube y se descargan al abrirlos.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if !resultado.appsComprimidas.isEmpty {
                let nombres = resultado.appsComprimidas.map { (Rutas.nombre($0) as NSString).deletingPathExtension }
                Label("Comprimí \(Formato.lista(nombres)) y \(nombres.count == 1 ? "su firma sigue" : "sus firmas siguen") siendo \(nombres.count == 1 ? "válida" : "válidas"). Si alguna no se abre bien, descomprímela en Análisis › Descomprimir una app.",
                      systemImage: "app.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if resultado.sinPermisoApps {
                HStack {
                    Label("macOS no me dejó modificar apps: activa LimpiadorMac en Ajustes › Privacidad y seguridad › Gestión de apps y vuelve a limpiar.",
                          systemImage: "lock.app.dashed")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Abrir Ajustes") { almacen.abrirGestionDeApps() }
                        .controlSize(.small)
                }
            }
            if resultado.detenido {
                Label("Lo detuviste: \(resultado.sinTerminar.isEmpty ? "terminé lo que tenía entre manos" : "no terminé \(Formato.listaCorta(resultado.sinTerminar))"). Lo ya hecho se queda hecho; vuelve a analizar para seguir.",
                      systemImage: "stop.circle")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            if resultado.difiere {
                Text("Calculado: \(Formato.bytes(resultado.liberadoCalculado)). La diferencia es lo que otros programas escribieron mientras tanto o lo que retienen clones e instantáneas.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if resultado.instantaneas > 0 {
                Label("Hay \(resultado.instantaneas == 1 ? "1 instantánea local" : "\(resultado.instantaneas) instantáneas locales") de Time Machine: lo que borraste seguirá ocupando hasta que caduquen.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !resultado.volveraACrecer.isEmpty {
                Label("Volverá a crecer con el uso: \(Formato.lista(resultado.volveraACrecer)).", systemImage: "arrow.up.forward.circle")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text("Ahora tienes \(Formato.bytes(almacen.disco.libre)) libres")
                .font(.headline)
                .foregroundStyle(.green)

            if !resultado.omitidos.isEmpty {
                ListaMensajes(titulo: "Me salté \(resultado.omitidos.count) \(resultado.omitidos.count == 1 ? "elemento" : "elementos") porque estaba en uso:",
                              mensajes: resultado.omitidos, color: .orange)
            }
            if !resultado.errores.isEmpty {
                ListaMensajes(titulo: "No se pudo borrar todo (\(resultado.errores.count)):", mensajes: resultado.errores, color: .secondary)
            }

            HStack {
                if resultado.restaurables > 0, almacen.ultimaLimpieza != nil {
                    Button {
                        almacen.deshacer()
                        cerrar()
                    } label: {
                        Label("Deshacer", systemImage: "arrow.uturn.backward")
                    }
                    .help("Devuelve todo a su sitio original")
                }
                Spacer()
                // Solo lo que movió esta limpieza y sigue en la Papelera (lo demás que haya en ella no se toca).
                if let esta = resultado.papelera {
                    let quedan = esta.movimientos.filter { Rutas.existe($0.enPapelera) }
                    if !quedan.isEmpty { BotonVaciarEsta(limpieza: LimpiezaGuardada(fecha: esta.fecha, movimientos: quedan)) }
                }
                Button("Cerrar") { cerrar() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    /// «Liberar al máximo»: lo medido, lo comprimido, lo que quedó en la Papelera y lo purgable, por separado.
    private var cifrasDelMaximo: some View {
        HStack(alignment: .top, spacing: 18) {
            Cifra(titulo: "Liberado (medido)", valor: resultado.liberadoMedido)
            if resultado.comprimido > 0 { Cifra(titulo: "Comprimido sin borrar", valor: resultado.comprimido) }
            if resultado.enPapelera > 0 { Cifra(titulo: "En la Papelera", valor: resultado.enPapelera) }
            if resultado.purgable >= 100_000_000 {
                Cifra(titulo: "Purgable", valor: resultado.purgable)
                    .help("Espacio que macOS libera solo cuando le hace falta: no lo cuento como liberado.")
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Cifra: View {
    let titulo: String
    let valor: Int64

    var body: some View {
        VStack(spacing: 2) {
            Text(Formato.bytes(valor)).font(.callout.weight(.semibold).monospacedDigit())
            Text(titulo).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// «Vaciar solo lo de esta limpieza»: borra de la Papelera lo que movió esa limpieza, y nada más, tras confirmarlo.
struct BotonVaciarEsta: View {
    @EnvironmentObject var almacen: Almacen
    let limpieza: LimpiezaGuardada
    @State private var confirmar = false

    var body: some View {
        let n = limpieza.movimientos.count
        Button("Vaciar solo lo de esta limpieza (\(Formato.bytes(limpieza.bytes)))") { confirmar = true }
            .disabled(almacen.limpiando)
            .help("Borra de la Papelera solo lo que movió esta limpieza; lo demás que tengas en ella no se toca")
            .confirmationDialog("¿Borrar para siempre lo que movió esta limpieza?", isPresented: $confirmar) {
                Button("Borrar \(n == 1 ? "1 cosa" : "\(n) cosas") (\(Formato.bytes(limpieza.bytes)))", role: .destructive) {
                    almacen.vaciarSoloEsta(limpieza)
                }
            } message: {
                Text("Se borran de la Papelera solo \(n == 1 ? "la cosa que movió" : "las \(n) cosas que movió") esta limpieza. Lo demás que tengas en la Papelera no se toca. Ya no podrás deshacer esta limpieza.")
            }
    }
}

private struct ListaMensajes: View {
    let titulo: String
    let mensajes: [String]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo).font(.callout.weight(.semibold)).foregroundStyle(color)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(mensajes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}
