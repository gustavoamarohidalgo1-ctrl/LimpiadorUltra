import SwiftUI

/// Recorre las carpetas ordenadas por tamaño para ver en detalle qué ocupa espacio.
/// Si ya hay un análisis, usa su índice (instantáneo); si no, mide con `du`.
struct VistaExplorador: View {
    @EnvironmentObject var almacen: Almacen
    @State private var ruta: [URL] = [Rutas.home]
    @State private var hijos: [(url: URL, tamano: Int64)] = []
    @State private var sueltos: Int64 = 0
    @State private var cargando = false
    @State private var cache: [URL: [(url: URL, tamano: Int64)]] = [:]
    @State private var aBorrar: URL?
    @State private var avisosBorrar: [String] = []

    private var actual: URL { ruta.last ?? Rutas.home }
    private var total: Int64 { hijos.reduce(0) { $0 + $1.tamano } + sueltos }

    var body: some View {
        VStack(spacing: 0) {
            barraRuta
            Divider()
            if cargando {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Midiendo \(Formato.rutaCorta(actual))…").foregroundStyle(.secondary)
                    Text("Consejo: después de «Analizar a fondo», el explorador es instantáneo.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(hijos.enumerated()), id: \.element.url) { i, h in
                            fila(h.url, h.tamano)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(i.isMultiple(of: 2) ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.clear),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        if sueltos >= 1_000_000 {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.on.doc").frame(width: 22).foregroundStyle(.secondary)
                                Text("Archivos sueltos y carpetas pequeñas").foregroundStyle(.secondary)
                                Spacer()
                                Text(Formato.bytes(sueltos)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                                Image(systemName: "chevron.right").opacity(0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                    .padding(12)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Explorador de espacio")
        .task(id: actual) { await cargar() }
        .onChange(of: almacen.analizado) { _, _ in
            cache = [:]
            Task { await cargar() }
        }
        .confirmationDialog("¿Mover a la Papelera?", isPresented: Binding(get: { aBorrar != nil }, set: { if !$0 { aBorrar = nil } })) {
            Button("Mover a la Papelera", role: .destructive) {
                if let u = aBorrar { moverAPapelera(u) }
            }
        } message: {
            if let u = aBorrar {
                if avisosBorrar.isEmpty {
                    Text(Formato.rutaCorta(u))
                } else {
                    Text("\(Formato.rutaCorta(u))\n\n⚠️ Contiene \(Formato.lista(avisosBorrar)). Asegúrate de que no lo necesitas.")
                }
            }
        }
    }

    private var barraRuta: some View {
        HStack(spacing: 6) {
            Button {
                if ruta.count > 1 { ruta.removeLast() }
            } label: { Image(systemName: "chevron.left") }
            .disabled(ruta.count <= 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(ruta.enumerated()), id: \.offset) { i, u in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        Button(i == 0 ? nombreRaiz(u) : u.lastPathComponent) {
                            ruta = Array(ruta.prefix(i + 1))
                        }
                        .buttonStyle(.plain)
                        .fontWeight(i == ruta.count - 1 ? .semibold : .regular)
                    }
                }
            }
            Menu("Ir a") {
                Button("Carpeta personal") { ruta = [Rutas.home] }
                Button("Library (datos de apps)") { ruta = [Rutas.home, Rutas.enHome("Library")] }
                Button("Aplicaciones") { ruta = [URL(fileURLWithPath: "/Applications")] }
                Button("Carpeta compartida") { ruta = [URL(fileURLWithPath: "/Users/Shared")] }
            }
            .fixedSize()
            Button {
                cache[actual] = nil
                Task { await cargar(forzarDu: true) }
            } label: { Image(systemName: "arrow.clockwise") }
            .help("Volver a medir")
            if !cargando {
                Text(Formato.bytes(total)).font(.headline.monospacedDigit())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func nombreRaiz(_ u: URL) -> String {
        u == Rutas.home ? "Carpeta personal" : u.lastPathComponent
    }

    private func fila(_ url: URL, _ tamano: Int64) -> some View {
        let esCarpeta = Rutas.esCarpeta(url) && url.pathExtension != "app"
        let fraccion = total > 0 ? Double(tamano) / Double(total) : 0
        let elemento = almacen.elemento(enRuta: url.path)
        return HStack(spacing: 10) {
            IconoArchivo(url: url).frame(width: 22, height: 22)
            Text(url.lastPathComponent).lineLimit(1)
            if let elemento {
                Button {
                    almacen.irA(elemento)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: elemento.categoria.icono)
                        Text(elemento.categoria.titulo)
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(EtiquetaRiesgo.color(elemento.riesgo).opacity(0.15), in: Capsule())
                    .foregroundStyle(EtiquetaRiesgo.color(elemento.riesgo))
                }
                .buttonStyle(.plain)
                .help("Está en los resultados del análisis (\(elemento.riesgo.etiqueta)). Clic para ver por qué.")
            }
            Spacer()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor.gradient).frame(width: max(2, g.size.width * fraccion))
                }
            }
            .frame(width: 160, height: 6)
            Text(Formato.bytes(tamano))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .opacity(esCarpeta ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if esCarpeta { ruta.append(url) } }
        .contextMenu {
            if let elemento {
                Button("Ver por qué es \(elemento.riesgo.etiqueta.lowercased())") { almacen.irA(elemento) }
            }
            Button("Mostrar en Finder") { almacen.mostrarEnFinder(url) }
            Divider()
            Button("Mover a la Papelera…", role: .destructive) { prepararBorrado(url) }
                .disabled(!Seguridad.sePuedeBorrar(url))
        }
    }

    private func prepararBorrado(_ url: URL) {
        avisosBorrar = almacen.indice.map { Evaluador.avisosRapidos(de: url, indice: $0) } ?? []
        aBorrar = url
    }

    private func cargar(forzarDu: Bool = false) async {
        let destino = actual
        if let c = cache[destino] {
            hijos = c
            sueltos = 0
            return
        }
        // Con índice: instantáneo.
        if !forzarDu, let indice = almacen.indice, let info = indice.info(destino.path) {
            var lista = indice.hijosOrdenados(de: destino.path).map { (url: URL(fileURLWithPath: $0.ruta), tamano: $0.bytes) }
            lista += indice.grandes.filter { $0.carpeta == destino.path }.map { (url: $0.url, tamano: $0.bytes) }
            lista.sort { $0.tamano > $1.tamano }
            hijos = lista
            sueltos = max(0, info.bytes - lista.reduce(0) { $0 + $1.tamano })
            return
        }
        cargando = true
        let r = await Task.detached(priority: .userInitiated) { Tamanos.hijos(de: destino) }.value
        guard destino == actual else { return }
        cache[destino] = r
        hijos = r
        sueltos = 0
        cargando = false
    }

    private func moverAPapelera(_ url: URL) {
        guard Seguridad.sePuedeBorrar(url) else { return }
        var destino: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &destino)
            if let d = destino?.path {
                let tamano = hijos.first { $0.url == url }?.tamano ?? 0
                Historial.guardarUltima(LimpiezaGuardada(fecha: Date(), movimientos: [
                    Movimiento(original: url.path, enPapelera: d, nombre: url.lastPathComponent, bytes: tamano),
                ]))
                Historial.registrar(["papelera\t\(tamano)\t\(url.path)"])
            }
            hijos.removeAll { $0.url == url }
            for u in ruta { cache[u] = nil }
            cache[actual] = hijos
            almacen.actualizarDisco()
        } catch {
            NSSound.beep()
        }
    }
}
