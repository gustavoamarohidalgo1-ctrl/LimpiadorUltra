import Foundation
import Security

// Comprimir apps instaladas (E11): qué apps se pueden comprimir, comprobar su firma antes y después, y apuntar qué
// archivos se comprimieron para poder deshacerlo. La compresión la hace `Compresor` con `Compresion.apps`.

/// Las apps instaladas que se pueden comprimir: las tuyas (`Seguridad.appPropia`) de /Applications y ~/Applications.
enum AppsPropias {
    struct App: Sendable {
        let ruta: String
        let id: String
        let nombre: String
        let version: String?
    }

    /// Las apps de primer nivel de `Seguridad.carpetasDeApps` y las de una carpeta dentro (/Applications/Utilidades),
    /// que son tuyas y no son de Apple ni de la App Store.
    static func candidatas() -> [App] {
        var r: [App] = []
        for carpeta in Seguridad.carpetasDeApps {
            for h in Rutas.hijos(URL(fileURLWithPath: carpeta)) {
                let dentro = h.pathExtension == "app" ? [h]
                    : (h.pathExtension.isEmpty && Rutas.esCarpeta(h) ? Rutas.hijos(h).filter { $0.pathExtension == "app" } : [])
                for app in dentro {
                    let real = Rutas.real(app)
                    // Info.plist se lee del disco cada vez (Bundle guarda lo que leyó y una app se actualiza sola).
                    guard Seguridad.appPropia(real) == real, let info = NSDictionary(contentsOfFile: real + "/Contents/Info.plist"),
                          let id = info["CFBundleIdentifier"] as? String else { continue }
                    let nombre = (info["CFBundleDisplayName"] as? String) ?? app.deletingPathExtension().lastPathComponent
                    r.append(App(ruta: real, id: id, nombre: nombre, version: info["CFBundleShortVersionString"] as? String))
                }
            }
        }
        return r
    }

    /// La versión de una app según su Info.plist (leído ahora del disco).
    static func version(de app: String) -> String? {
        NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
    }
}

/// Qué versión de una app es: su versión, su compilación y quién la firmó (Team ID), leídos ahora del disco. Dos copias
/// con la misma identidad son la misma app; si algo cambia, una de las dos es otra versión (una anterior que guardaste
/// para volver atrás, una nueva sin instalar o la de otro desarrollador).
struct IdentidadDeApp: Equatable {
    let version: String?
    let compilacion: String?
    let equipo: String?

    init(_ app: String) {
        // Info.plist se lee del disco cada vez (Bundle guarda lo que leyó).
        let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
        version = info?["CFBundleShortVersionString"] as? String
        compilacion = info?["CFBundleVersion"] as? String
        equipo = FirmaDeCodigo.equipo(app)
    }

    /// «2.8.1»; con `compilacion`, «2.8.1 (281)» (para distinguir dos compilaciones de la misma versión).
    func texto(compilacion conCompilacion: Bool) -> String {
        switch (version, compilacion) {
        case let (v?, c?) where conCompilacion && c != v: return "\(v) (\(c))"
        case let (v?, _): return v
        case let (nil, c?): return c
        default: return "sin versión"
        }
    }
}

/// La firma de código de una app: macOS la comprueba al abrirla. Comprimir no cambia el contenido (la firma valida el
/// contenido, no cómo se guarda), pero se comprueba antes y después para estar seguros.
enum FirmaDeCodigo {
    enum Estado: Equatable { case valida, sinFirma, invalida(String) }

    /// Comprueba la firma entera (también lo que lleva dentro y todas las arquitecturas), como `codesign --verify
    /// --deep --strict`. Lee toda la app: unos segundos en las grandes.
    static func comprobar(_ ruta: String) -> Estado {
        var codigo: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: ruta) as CFURL, [], &codigo) == errSecSuccess, let codigo else {
            return .invalida("no pude leer su firma")
        }
        let opciones = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        var error: Unmanaged<CFError>?
        let estado = SecStaticCodeCheckValidityWithErrors(codigo, opciones, nil, &error)
        error?.release()
        if estado == errSecSuccess { return .valida }
        if estado == errSecCSUnsigned { return .sinFirma }
        return .invalida(motivo(estado))
    }

    /// El código del desarrollador que la firmó (Team ID), o nil si no tiene (sin firma o firmada sin certificado). Solo
    /// lee la firma, no la comprueba.
    static func equipo(_ ruta: String) -> String? {
        var codigo: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: ruta) as CFURL, [], &codigo) == errSecSuccess, let codigo else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(codigo, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return (d[kSecCodeInfoTeamIdentifier as String] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() }
    }

    /// Por qué no valida, en palabras: los casos habituales en español y, si no, lo que dice el sistema.
    static func motivo(_ estado: OSStatus) -> String {
        switch estado {
        case errSecCSSignatureFailed: return "la firma no coincide con el contenido: algo de la app cambió"
        case errSecCSResourcesInvalid, errSecCSResourcesNotFound, errSecCSResourcesNotSealed:
            return "sus recursos no coinciden con los que firmó el desarrollador"
        case errSecCSReqFailed: return "no cumple los requisitos de su firma"
        case errSecCSInfoPlistFailed: return "su Info.plist no coincide con la firma"
        case errSecCSUnsealedAppRoot: return "hay archivos sueltos dentro de la app que no están en su firma"
        default: return (SecCopyErrorMessageString(estado, nil) as String?) ?? "error \(estado) al comprobar la firma"
        }
    }
}

/// Las apps que comprimió LimpiadorMac y qué archivos de cada una, para poder descomprimirlas si alguna no se abre bien.
/// Se guarda en ~/Library/Application Support/LimpiadorMac/apps-comprimidas, un archivo por app.
enum AppsComprimidas {
    struct Registro: Codable, Identifiable, Hashable {
        var id: String { app }
        /// La .app (ruta real).
        let app: String
        let nombre: String
        let identificador: String
        /// La versión que se comprimió: si la app se actualiza, sus archivos se reemplazan y ya no hay nada que deshacer.
        let version: String?
        var fecha: Date
        /// Los archivos comprimidos, relativos a la app.
        var archivos: [String]
    }

    static var carpeta: URL { Rutas.enHome("Library/Application Support/LimpiadorMac/apps-comprimidas") }

    private static func archivo(de app: String) -> URL {
        let nombre = app.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return carpeta.appendingPathComponent(nombre + ".json")
    }

    /// Apunta los archivos de `app` que se acaban de comprimir (se suman a los que ya estaban, si es la misma versión).
    static func apuntar(app: String, nombre: String, identificador: String, version: String?, archivos: [String]) {
        guard !archivos.isEmpty else { return }
        let relativos = archivos.filter { $0.hasPrefix(app + "/") }.map { String($0.dropFirst(app.count + 1)) }
        var r = leer(app).flatMap { $0.version == version ? $0 : nil }
            ?? Registro(app: app, nombre: nombre, identificador: identificador, version: version, fecha: Date(), archivos: [])
        r.archivos = Array(Set(r.archivos).union(relativos)).sorted()
        r.fecha = Date()
        guardar(r)
    }

    static func leer(_ app: String) -> Registro? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: archivo(de: app))).flatMap { try? d.decode(Registro.self, from: $0) }
    }

    private static func guardar(_ r: Registro) {
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? e.encode(r).write(to: archivo(de: r.app))
    }

    static func olvidar(_ app: String) {
        try? FileManager.default.removeItem(at: archivo(de: app))
    }

    /// Las apps comprimidas que siguen instaladas con la misma versión (si se actualizó, ya no hay nada que deshacer y,
    /// con `olvidar`, se borra su registro; el diagnóstico no borra nada).
    static func lista(olvidar: Bool = true) -> [Registro] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var r: [Registro] = []
        for u in Rutas.hijos(carpeta) where u.pathExtension == "json" {
            guard let datos = try? Data(contentsOf: u), let reg = try? d.decode(Registro.self, from: datos) else { continue }
            let version = AppsPropias.version(de: reg.app)
            guard Rutas.existe(reg.app), version == reg.version else {
                if olvidar { try? FileManager.default.removeItem(at: u) }
                continue
            }
            r.append(reg)
        }
        return r.sorted { $0.nombre.localizedCompare($1.nombre) == .orderedAscending }
    }

    /// Las rutas completas de los archivos apuntados de esa app.
    static func rutas(_ r: Registro) -> [String] { r.archivos.map { r.app + "/" + $0 } }
}
