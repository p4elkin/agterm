import Foundation

extension WindowLibrary {
    /// The open store holding `session` itself. Matched by object identity rather than through
    /// `store(forSession:)`, which answers with the first window carrying that id and a snapshot written by
    /// an older build can put one id in two windows.
    public func store(owning session: Session) -> AppStore? {
        openIDs().compactMap { store(for: $0) }.first { store in
            store.workspaces.contains { $0.sessions.contains { $0 === session } }
        }
    }

    /// Records a clicked path in the window holding `session` itself; false when no open window does.
    @discardableResult
    public func recordLinkPathEvent(session: Session, pane: CommandContext.Pane, path: String, line: Int?,
                                    cwd: String) -> Bool {
        store(owning: session)?.recordLinkPathEvent(forSession: session.id, pane: pane, path: path, line: line,
                                                    cwd: cwd) ?? false
    }
}
