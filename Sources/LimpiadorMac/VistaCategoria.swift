import SwiftUI

enum Orden: String, CaseIterable, Identifiable {
    case tamano = "Tamaño"
    case antiguedad = "Más tiempo sin usar"
    case riesgo = "Más seguro primero"
    case nombre = "Nombre"
    var id: String { rawValue }
}

struct VistaCategoria: View {
    @EnvironmentObject var almacen: Almacen
    let categoria: Categoria
    @State private var orden: Orden = .tamano
    @State private var busqueda = ""
    @State private var mostrarDetalle = true

    private var lista: [Elemento] {
        var l = almacen.elementos(de: categoria)
        if !busqueda.isEmpty {
            l = l.filter { $0.nombre.localizedCaseInsensitiveContains(busqueda) || $0.rutaPrincipal.path.localizedCaseInsensitiveContains(busqueda) }
        }
        switch orden {
        case .tamano: l.sort { $0.bytesLiberables != $1.bytesLiberables ? $0.bytesLiberables > $1.bytesLiberables : $0.tamano > $1.tamano }
        case .antiguedad: l.sort { ($0.ultimoUso ?? .distantPast) < ($1.ultimoUso ?? .distantPast) }
        case .riesgo: l.sort { $0.riesgo != $1.riesgo ? $0.riesgo < $1.riesgo : $0.bytesLiberables > $1.bytesLiberables }
        case .nombre: l.sort { $0.nombre.localizedCompare($1.nombre) == .orderedAscending }
        }
        return l
    }

    var body: some View {
        VStack(spacing: 0) {
            encabezado
            Divider()
            if categoria == .restos, let probables = almacen.indice?.probablesRestos, !probables.isEmpty, !almacen.accesoTotal {
                restosSinMedir(probables)
            }
            if categoria == .olvidados, let nubes = almacen.indice?.otrasNubes, !nubes.isEmpty {
                otrasNubes(nubes)
            }
            if let notas = almacen.indice?.notas.filter({ $0.categoria == categoria }), !notas.isEmpty {
                notasGrandes(notas)
            }
            if lista.isEmpty {
                ContentUnavailableView(
                    almacen.analizando ? "Analizando…" : "Nada por aquí",
                    systemImage: almacen.analizando ? "hourglass" : "checkmark.seal",
                    description: Text(almacen.analizando ? "Todavía estoy revisando esta categoría." : "No encontré nada que ocupe espacio en esta categoría."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(lista) { el in
                            FilaElemento(elemento: el, marcado: almacen.detalle == el.id)
                                .onTapGesture { almacen.detalle = el.id }
                        }
                    }
                    .padding(16)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
        .searchable(text: $busqueda, placement: .toolbar, prompt: "Buscar")
        .inspector(isPresented: $mostrarDetalle) {
            Group {
                if let el = almacen.elemento(almacen.detalle), el.categoria == categoria {
                    VistaDetalle(elemento: el)
                } else {
                    ContentUnavailableView("Elige un elemento", systemImage: "hand.point.up.left",
                                           description: Text("Te explico qué es, qué contiene y si es seguro borrarlo."))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    mostrarDetalle.toggle()
                } label: {
                    Label("Detalle", systemImage: "sidebar.trailing")
                }
                .help("Mostrar u ocultar el panel de detalle")
            }
        }
    }

    /// Sin «Acceso total al disco»: las apps desinstaladas que probablemente dejaron carpetas en los contenedores. Solo
    /// se informa (no se sabe cuánto ocupan ni qué hay dentro, así que no se ofrece borrar nada).
    private func restosSinMedir(_ probables: [ProbableResto]) -> some View {
        let partes = probables.map { "\($0.nombre) (\($0.carpetas.count) \($0.carpetas.count == 1 ? "carpeta" : "carpetas"))" }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.folder.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Probables restos que no puedo medir").font(.headline)
                Text("En los contenedores de las apps hay carpetas de apps que no están instaladas: \(Formato.listaCorta(partes, maximo: 6)). Tamaño desconocido: sin «Acceso total al disco» macOS no me deja ver qué hay dentro. Dámelo para medirlos y, si son restos, limpiarlos.")
                    .font(.callout).foregroundStyle(.secondary)
                    .help(probables.map { "\($0.nombre): \($0.carpetas.joined(separator: ", "))" }.joined(separator: "\n"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Abrir Ajustes") { almacen.abrirAccesoTotal() }
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 16)
    }

    /// Las carpetas de otras nubes (OneDrive, Google Drive, Dropbox…): no se tocan; cada una tiene su opción para dejar
    /// los archivos solo en línea.
    private func otrasNubes(_ nubes: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cloud.fill").font(.title2).foregroundStyle(.secondary)
            Text("Tienes \(Formato.lista(nubes)) en el Mac. No toco sus carpetas: para liberar espacio sin borrar nada, usa su opción «Liberar espacio» o «Solo en línea» (clic derecho en la carpeta, en el Finder).")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 16)
    }

    /// Lo grande que no se ofrece limpiar (no hay una forma segura de hacerlo desde aquí): qué es, cuánto ocupa y cómo se
    /// quitaría a mano. Solo se informa.
    private func notasGrandes(_ notas: [NotaGrande]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notas, id: \.self) { nota in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(nota.titulo).font(.headline)
                            Spacer()
                            Text(Formato.bytes(nota.bytes)).font(.callout.weight(.semibold).monospacedDigit())
                        }
                        Text(nota.texto).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Mostrar") { almacen.mostrarEnFinder(URL(fileURLWithPath: nota.ruta)) }
                        .controlSize(.small)
                        .help("Mostrar en el Finder (no se borra nada)")
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 16)
    }

    private var encabezado: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: categoria.icono)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(categoria.titulo).font(.title2.weight(.bold))
                    Text(categoria.subtitulo).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                VStack(alignment: .trailing) {
                    Text(Formato.bytes(almacen.total(de: categoria)))
                        .font(.title.weight(.bold).monospacedDigit())
                    Text("\(Formato.bytes(almacen.totalSeleccionado(de: categoria))) seleccionados")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                Button("Todo") { almacen.seleccionar(categoria) { $0.riesgo != .cuidado } }
                    .help("Marca todo menos lo de «Cuidado»: eso hay que revisarlo y marcarlo uno por uno")
                Button("Nada") { almacen.seleccionar(categoria) { _ in false } }
                // Lo que cuesta descargas o esperas (nivel del Modo máximo) se marca a mano.
                Button("Solo lo seguro") { almacen.seleccionar(categoria) { $0.riesgo == .seguro && $0.nivel == .normal && $0.avisos.isEmpty } }
                    .help("Marca lo que es seguro y no tiene ningún aviso")
                Button("Sin usar +90 días") {
                    almacen.seleccionar(categoria) { ($0.diasSinUso ?? 0) >= 90 && $0.riesgo != .cuidado && !$0.abiertoAhora }
                }
                .help("Marca lo que lleva más de 3 meses sin usarse (excepto lo marcado como «Cuidado»)")
                Spacer(minLength: 8)
                Picker("Ordenar", selection: $orden) {
                    ForEach(Orden.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 230)
            }
            .controlSize(.small)
        }
        .padding(20)
    }
}

struct FilaElemento: View {
    @EnvironmentObject var almacen: Almacen
    let elemento: Elemento
    var marcado = false

    /// Los avisos más graves y, si no hay ninguno, la mejor razón para borrarlo.
    private var chips: [Motivo] {
        let avisos = elemento.avisos.prefix(2)
        if !avisos.isEmpty { return Array(avisos) }
        return Array(elemento.motivos.filter { $0.nivel == .bien }.prefix(1))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: almacen.seleccionado(elemento.id))
                .toggleStyle(.checkbox)
                .labelsHidden()
            IconoArchivo(url: elemento.rutaPrincipal)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(elemento.nombre).font(.body.weight(.medium)).lineLimit(1)
                    if elemento.abiertoAhora {
                        Image(systemName: "bolt.circle.fill")
                            .foregroundStyle(.orange)
                            .help("Algo lo está usando ahora mismo")
                    }
                }
                Text(elemento.detalle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { ChipMotivo(motivo: $0) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                // Lo que se libera de verdad; si comparte espacio con clones, también lo que ocupa. Al comprimir, lo que
                // se ahorra (estimado) y lo que ocupan ahora.
                Text(Formato.bytes(elemento.bytesLiberables))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .help(elemento.accion.une ? "Lo que se ahorra uniendo las copias"
                          : elemento.accion.quitaDescarga ? "Lo que se libera quitando las copias locales (siguen en iCloud)"
                          : elemento.prevision != nil ? "Lo que se ahorra comprimiendo (estimado)"
                          : elemento.comparteEspacio ? "Libera esto al borrarlo" : "Lo que ocupa y libera al borrarlo")
                if let p = elemento.prevision {
                    Text("de \(Formato.bytes(p.ocupan))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(elemento.accion.une ? "Lo que ocupan ahora las copias que se unen"
                              : elemento.accion.quitaDescarga ? "Lo que ocupan en el Mac los \(Formato.numero(p.archivos.count)) archivos"
                              : "Lo que ocupan ahora los \(Formato.numero(p.archivos.count)) archivos que se comprimen")
                } else if elemento.comparteEspacio {
                    Text("ocupa \(Formato.bytes(elemento.tamano))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                        .help("Contando cada copia ocupa \(Formato.bytes(elemento.tamano)), pero parte son clones de APFS (copias que usan los mismos bloques del disco, entre sí o con archivos que se quedan): borrarlo libera \(Formato.bytes(elemento.bytesLiberables)).")
                }
                Text(Formato.haceCuanto(elemento.ultimoUso))
                    .font(.caption)
                    .foregroundStyle((elemento.diasSinUso ?? 0) >= 90 ? .orange : .secondary)
                    .help("Última vez que se usó o modificó algo dentro")
                EtiquetaRiesgo(riesgo: elemento.riesgo)
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            elemento.seleccionado ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.background.secondary),
            in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(marcado ? Color.accentColor : (elemento.seleccionado ? Color.accentColor.opacity(0.35) : .clear),
                          lineWidth: marcado ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button(elemento.seleccionado ? "Desmarcar" : "Marcar para limpiar") { almacen.alternar(elemento.id) }
            Divider()
            Button("Mostrar en Finder") { almacen.mostrarEnFinder(elemento.rutaPrincipal) }
            Button("Copiar ruta") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(elemento.rutas.map(\.path).joined(separator: "\n"), forType: .string)
            }
        }
    }
}

struct ChipMotivo: View {
    let motivo: Motivo

    var body: some View {
        Label(motivo.etiqueta, systemImage: motivo.icono)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(ColorMotivo.de(motivo.nivel).opacity(0.14), in: Capsule())
            .foregroundStyle(ColorMotivo.de(motivo.nivel))
            .help(motivo.texto)
    }
}

enum ColorMotivo {
    static func de(_ nivel: NivelMotivo) -> Color {
        switch nivel {
        case .bien: return .green
        case .info: return .secondary
        case .aviso: return .orange
        case .peligro: return .red
        }
    }
}

struct EtiquetaRiesgo: View {
    let riesgo: Riesgo

    static func color(_ r: Riesgo) -> Color {
        switch r {
        case .seguro: return .green
        case .revisar: return .orange
        case .cuidado: return .red
        }
    }

    var body: some View {
        Text(riesgo.etiqueta)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Self.color(riesgo).opacity(0.15), in: Capsule())
            .foregroundStyle(Self.color(riesgo))
            .help(riesgo.explicacion)
    }
}

struct IconoArchivo: View {
    let url: URL
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
