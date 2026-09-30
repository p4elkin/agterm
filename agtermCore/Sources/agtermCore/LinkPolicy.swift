import Foundation

/// Decides what agterm does when a terminal hyperlink is clicked (`GHOSTTY_ACTION_OPEN_URL`). A terminal
/// renders UNTRUSTED program output, so an escape-sequence link can carry any scheme. `disposition(for:)`
/// maps a raw link to OPEN a web/mail URL (`NSWorkspace.open`), REVEAL a LOCAL `file://` link in Finder
/// (`NSWorkspace.activateFileViewerSelecting`), REPORT a schemeless path to `link.path` hooks, or IGNORE
/// anything else. `file://` is revealed, never opened: opening goes through LaunchServices (the Finder
/// double-click path), so a click on `file:///…/X.app` or `.command` would LAUNCH it, while reveal only
/// selects it. A `file://` whose host is NOT this machine is ignored, since `activateFileViewerSelecting`
/// on a remote host can trigger a Finder network/SMB mount. Host-free (Foundation-only) so it is
/// unit-tested — the local host names are injected; the app-side glue only calls the two `NSWorkspace`
/// methods or records the event (same split as `ShellEscape`).
public enum LinkPolicy {
    /// The schemes safe to hand to the system opener — web + mail only, none that hands off to a local
    /// executable/handler.
    public static let permittedSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    /// What a link click should do. Carries the target URL for `.open`/`.reveal`.
    public enum LinkDisposition: Equatable {
        case open(URL)
        case reveal(URL)
        /// A schemeless path, relative or absolute, with an editor-style `:N` suffix split off as `line`.
        case path(String, line: Int?)
        case ignore
    }

    /// Lowercased host names counting as "this machine" for a `file://` link: `localhost` and the
    /// `gethostname()` name (what GNU `ls --hyperlink` emits, e.g. `file://<host>/…`; `eza` uses an empty
    /// host, covered by the empty-host rule). Deliberately NOT `Host.current()`/`ProcessInfo.hostName`:
    /// those resolve via mDNS/Bonjour, tripping the macOS "find devices on local networks" prompt on first
    /// click, while `gethostname()` is a pure syscall. Computed ONCE, the default for `disposition`.
    public static let localHostNames: Set<String> = {
        var raw: Set<String> = ["localhost"]
        var buffer = [CChar](repeating: 0, count: 256)   // gethostname() — the name GNU ls uses, no network
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }   // trim at NUL, then decode
            raw.insert(String(decoding: bytes, as: UTF8.self))
        }
        return expandedHostNames(from: raw)
    }()

    /// Normalize each raw host name and add the `.local`-stripped short form beside the full one. Pure (no
    /// syscalls), so the normalization + `.local` expansion feeding `localHostNames` stays unit-testable.
    static func expandedHostNames(from raw: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for name in raw {
            let norm = normalizedHost(name)
            guard !norm.isEmpty else { continue }
            out.insert(norm)
            if norm.hasSuffix(".local") {
                let short = String(norm.dropLast(6))                               // add the short form too,
                if !short.isEmpty { out.insert(short) }                            // but a bare ".local" → "" is skipped
            }
        }
        return out
    }

    /// Lowercase a host and drop a trailing FQDN dot so matching is stable.
    static func normalizedHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }

    /// The macOS auto-mount roots where a Finder reveal can trigger an NFS/SMB automount: `/net` (`-hosts`),
    /// `/Network` (`/Network/Servers`), `/home` (`auto_home`), PLUS their canonical `/System/Volumes/Data/…`
    /// paths — `/home` is a firmlink/symlink and `auto_home` really lives at `/System/Volumes/Data/home`, so
    /// a LITERAL `/System/Volumes/Data/home/<user>` link would slip past the `/home` entry and still mount.
    /// Matched EXACT or as a `<root>/…` child, case-insensitively (the boot volume is case-insensitive, so
    /// `/NET/…` mounts too), so `/networkx` is NOT caught; the Data root `/System/Volumes/Data` is
    /// deliberately unlisted, backing every real file. The path must already be dot-normalized.
    static func isAutomountPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["/net", "/network", "/home",
                "/system/volumes/data/home",
                "/system/volumes/data/net",
                "/system/volumes/data/network/servers"].contains { lower == $0 || lower.hasPrefix($0 + "/") }
    }

    /// Collapse `.`/`..` in an ABSOLUTE path with a purely LEXICAL, string-only normalizer — no filesystem
    /// access (unlike `URL.standardizedFileURL`, which stats the target) and no symlink resolution, so the
    /// classifier never touches the automount path it may be about to deny (a `stat` inside autofs could
    /// itself trigger the mount). A leading `..` at the root is dropped; the caller guarantees an absolute
    /// input (`hasPrefix("/")`).
    static func lexicallyNormalizedAbsolutePath(_ path: String) -> String {
        var out: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(comp)
        }
        return "/" + out.joined(separator: "/")
    }

    /// Maps a raw terminal link to an action: a permitted web/mail scheme → `.open`; a LOCAL `file://` link
    /// (empty host, or a host in `localHosts`) → `.reveal` of the HOST-STRIPPED, dot-normalized local path,
    /// so Finder only ever sees a plain `/…` path and never leans on the original authority for host
    /// handling; a `file://` with a non-local host, an empty/relative path, a UNC-style `//`-path, an
    /// auto-mount path (`/net`, `/Network`, `/home`, checked AFTER `..` normalization so `/tmp/../net/x`
    /// can't sneak through), or any other scheme / unparseable input → `.ignore`. Schemeless input goes to
    /// `pathDisposition`, which expands a leading `~/` against `homeDirectory` unless it is nil. `localHosts`
    /// is injected (default: this machine's names) so the decision stays host-free and unit-testable.
    public static func disposition(for raw: String, localHosts: Set<String> = localHostNames,
                                   homeDirectory: String? = NSHomeDirectory()) -> LinkDisposition {
        if raw.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil {
            return pathDisposition(raw, homeDirectory: homeDirectory)
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return .ignore }
        if permittedSchemes.contains(scheme) { return .open(url) }
        guard scheme == "file" else { return .ignore }
        let host = normalizedHost(url.host(percentEncoded: false) ?? "")
        guard host.isEmpty || localHosts.contains(host) else { return .ignore }
        // reject an empty/relative path (empty would make `URL(fileURLWithPath:)` the process CWD) and a
        // UNC-style `//` path (a remote target hidden where the host check can't see it).
        let rawPath = url.path(percentEncoded: false)
        guard rawPath.hasPrefix("/"), !rawPath.hasPrefix("//") else { return .ignore }
        // reveal a host-stripped local path, collapsing `.`/`..` LEXICALLY so `/tmp/../net/x` can't sneak
        // past the automount check and the classifier never stats — never risks triggering — the automount
        // path it is about to deny. It also never resolves symlinks: `/tmp/link -> /net` reveals the link,
        // not the target. Do NOT swap in `standardizedFileURL`/`resolvingSymlinksInPath()`, which touch the
        // filesystem.
        let normalizedPath = Self.lexicallyNormalizedAbsolutePath(rawPath)
        guard !isAutomountPath(normalizedPath) else { return .ignore }
        return .reveal(URL(fileURLWithPath: normalizedPath, isDirectory: false))
    }

    /// Relative paths need a `/` and no leading `-`. Only an absolute path may hold a space: ghostty resolves
    /// a match against the pane's pwd, so a pane under `Application Support` delivers one.
    static let pathPatterns = [
        #"^[\w.@+][\w.@+~-]*(?:/[\w.@+~-]+)+$"#,
        #"^~(?:/[\w.@+~-]+)+$"#,
        #"^(?:/[\w.@+~ -]+)+$"#,
    ]

    /// A schemeless link is terminal text, so it is reported only when it looks exactly like a path. Trailing
    /// prose punctuation ghostty's regex keeps (`.`, markdown `**`) is stripped, then an editor-style `:N`,
    /// `:N-M` or `:N:C` suffix becomes the line. A leading `~/` is expanded, since no hook's shell expands a `~`
    /// that arrives inside a variable.
    static func pathDisposition(_ raw: String, homeDirectory: String?) -> LinkDisposition {
        guard raw.count <= 1024, !raw.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true })
        else { return .ignore }
        var path = Substring(raw)
        while let last = path.last, ".*;!?".contains(last) { path = path.dropLast() }
        var line: Int?
        if let suffix = path.range(of: #":([0-9]+)(?:-[0-9]+|:[0-9]+)?$"#, options: .regularExpression) {
            guard let value = Int(path[suffix].dropFirst().prefix { $0.isNumber }), value > 0 else { return .ignore }
            line = value
            path = path[..<suffix.lowerBound]
        }
        let candidate = String(path)
        guard pathPatterns.contains(where: { candidate.range(of: $0, options: .regularExpression) != nil })
        else { return .ignore }
        guard let homeDirectory, candidate.hasPrefix("~/") else { return .path(candidate, line: line) }
        return .path(homeDirectory + candidate.dropFirst(), line: line)
    }
}
