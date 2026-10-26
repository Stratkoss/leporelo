import Foundation
import LeporeloCore

// leporelo-cli: a thin shell over `Workflow` (phase 1 end to end: folder -> project -> PDF).
//
// Exit codes: 0 success, 1 preflight errors (no PDF written), 2 other failures, 64 usage.

let usage = """
    Použití:
      leporelo-cli draft --folder <složka> --title <název> --out <složka> [--profile <id>] [--format <id>]
      leporelo-cli --help

    Vytvoří <out>/<název>.leporelo z fotek ve složce (jpg, jpeg, heic, png, i v podsložkách):
    seskupí je po dnech, zanalyzuje, doporučí výběr, navrhne album, zkopíruje originály
    vybraných fotek, provede kontrolu před tiskem a exportuje PDF do <out>/export/.

    Volby:
      --folder <složka>   složka s fotkami (povinné)
      --title <název>     název alba a projektu (povinné)
      --out <složka>      kam uložit projekt a export (povinné, vytvoří se)
      --profile <id>      profil dodavatele (výchozí: canva-photobook)
      --format <id>       formát knihy (výchozí: první formát na šířku daného profilu)
      -h, --help          tato nápověda

    Návratové kódy: 0 hotovo, 1 kontrola před tiskem našla chyby (PDF se nevytvořilo),
    2 jiná chyba, 64 špatné argumenty.
    """

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String, code: Int32) -> Never {
    log(message)
    exit(code)
}

func usageError(_ message: String) -> Never {
    log("leporelo-cli: \(message)\n")
    fail(usage, code: 64)
}

struct Options {
    var folder: String?
    var title: String?
    var out: String?
    var profile = "canva-photobook"
    var format: String?
}

func parse(_ args: [String]) -> Options {
    if args.contains("--help") || args.contains("-h") {
        print(usage)
        exit(0)
    }
    guard let command = args.first else { usageError("chybí příkaz") }
    guard command == "draft" else { usageError("neznámý příkaz \(command)") }
    var options = Options()
    var rest = args.dropFirst()[...]
    while let flag = rest.popFirst() {
        guard ["--folder", "--title", "--out", "--profile", "--format"].contains(flag) else {
            usageError("neznámá volba \(flag)")
        }
        guard let value = rest.popFirst(), !value.hasPrefix("--") else {
            usageError("volba \(flag) potřebuje hodnotu")
        }
        switch flag {
        case "--folder": options.folder = value
        case "--title": options.title = value
        case "--out": options.out = value
        case "--profile": options.profile = value
        default: options.format = value
        }
    }
    if options.folder == nil { usageError("chybí --folder") }
    if options.title?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { usageError("chybí --title") }
    if options.out == nil { usageError("chybí --out") }
    return options
}

func expand(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

/// A file name for the title: path separators and colons replaced.
func fileName(for title: String) -> String {
    title.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
}

func run(_ options: Options) async -> Int32 {
    let folder = expand(options.folder!)
    let out = expand(options.out!)
    let title = options.title!.trimmingCharacters(in: .whitespaces)

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
        log("Chyba: složka \(folder.path) neexistuje")
        return 2
    }

    let profile: SupplierProfile
    let format: BookFormat
    do {
        profile = try ProfileCatalog.profile(id: options.profile)
        if let id = options.format {
            guard let f = profile.formats.first(where: { $0.id == id }) else {
                log("Chyba: profil \(profile.id) nemá formát \(id) (má: \(profile.formats.map(\.id).joined(separator: ", ")))")
                return 2
            }
            format = f
        } else {
            guard let f = Workflow.defaultFormat(of: profile) else {
                log("Chyba: profil \(profile.id) nemá žádný formát")
                return 2
            }
            format = f
        }
    } catch ProfileCatalogError.profileNotFound(let id) {
        let known = ((try? ProfileCatalog.all()) ?? []).map(\.id).joined(separator: ", ")
        log("Chyba: neznámý profil \(id) (k dispozici: \(known))")
        return 2
    } catch {
        log("Chyba: nelze načíst profily dodavatelů: \(error)")
        return 2
    }

    let packageURL = out.appendingPathComponent(fileName(for: title) + ".leporelo", isDirectory: true)
    let exportURL = out.appendingPathComponent("export", isDirectory: true)
    let source = FolderPhotoSource(folder: folder)

    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        log("Profil: \(profile.name), formát: \(format.name)")
        log("Projekt: \(packageURL.path)")
        let package = try Workflow.createPackage(at: packageURL, title: title, profileID: profile.id,
                                                 formatID: format.id)

        log("Načítám fotky ze složky \(folder.path)…")
        var album = try await Workflow.buildAlbum(
            from: source, query: .dateRange(start: .distantPast, end: .distantFuture), title: title,
            profileID: profile.id, formatID: format.id, package: package, resolver: InMemoryPlaceResolver([]))
        let days = Set(album.photos.values.compactMap(\.dayKey)).count
        log("Fotek: \(album.photos.count), dnů: \(days)")
        guard !album.photos.isEmpty else {
            log("Chyba: ve složce nejsou žádné fotky (jpg, jpeg, heic, png)")
            return 2
        }

        log("Analyzuji fotky…")
        album = await Workflow.analyze(album: album, source: source, package: package) { progress in
            if progress.total > 0, progress.done == progress.total || progress.done % 10 == 0 {
                log("  analýza \(progress.done)/\(progress.total)")
            }
        }
        try package.save(album)
        let failed = album.photos.values.filter { $0.analysis == nil && $0.kind != .video }.count
        if failed > 0 { log("  \(failed) fotek se nepodařilo zanalyzovat (hodnotí se neutrálně)") }

        log("Doporučuji výběr a navrhuji album…")
        album = Workflow.recommendAndDraft(album: album, profile: profile, format: format)
        try package.save(album)
        log("Vybráno fotek: \(album.selectedPhotos.count), dvoustran: \(album.spreads.count), " +
            "stran: \(AlbumDrafter.pageCount(of: album))")

        log("Kopíruji originály vybraných fotek…")
        album = await Workflow.downloadSelectedOriginals(album: album, source: source, package: package) { done, total in
            if total > 0, done == total || done % 10 == 0 { log("  originály \(done)/\(total)") }
        }
        try package.save(album)

        log("Kontrola před tiskem…")
        let issues = Preflight.check(album: album, profile: profile, format: format)
        for issue in issues where issue.severity == .warning {
            log("  varování: \(describe(issue))")
        }
        if Preflight.hasErrors(issues) {
            for issue in issues where issue.severity == .error {
                log("  CHYBA: \(describe(issue))")
            }
            log("Kontrola před tiskem našla chyby, PDF se nevytvořilo. Projekt: \(packageURL.path)")
            return 1
        }

        log("Exportuji PDF…")
        let exporter = PDFExporter(album: album, profile: profile, format: format,
                                   images: PackageImageProvider(package: package, album: album))
        let result = try await exporter.export(to: exportURL) { done, total in
            if done == total || done % 5 == 0 { log("  export \(done)/\(total)") }
        }
        log("Hotovo: \(result.pagesURL.path) (\(result.pageCount) stran)")
        if let cover = result.coverURL { log("Obálka: \(cover.path)") }
        log("Návod k nahrání: \(result.readmeURL.path)")
        return 0
    } catch ProjectError.alreadyExists {
        log("Chyba: projekt \(packageURL.path) už existuje, zvol jiný --title nebo --out")
        return 2
    } catch {
        log("Chyba: \(error)")
        return 2
    }
}

func describe(_ issue: PreflightIssue) -> String {
    let place = [issue.spreadID, issue.frameID].compactMap { $0 }.joined(separator: "/")
    return place.isEmpty ? issue.message : "\(issue.message) [\(place)]"
}

exit(await run(parse(Array(CommandLine.arguments.dropFirst()))))
