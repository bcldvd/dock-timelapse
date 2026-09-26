/// A human-meaningful change between two Docks.
public struct Change: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case added, removed, replaced, moved }

    public var kind: Kind
    public var app: DockApp
    public var old: DockApp?

    public init(_ kind: Kind, _ app: DockApp, old: DockApp? = nil) {
        self.kind = kind
        self.app = app
        self.old = old
    }

    /// "+ Linear", "− Mail", "↕ Slack", "Xcode → Cursor"
    public var describe: String {
        switch kind {
        case .replaced: "\(old?.label ?? "") → \(app.label)"
        case .added: "+ \(app.label)"
        case .removed: "− \(app.label)"
        case .moved: "↕ \(app.label)"
        }
    }

    enum CodingKeys: String, CodingKey { case kind, app, old }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(app, forKey: .app)
        try c.encode(old, forKey: .old)
    }
}

/// What changed from `old` to `new`: replacements, additions, removals, then moves (Python parity).
public func diffDocks(_ old: [DockApp], _ new: [DockApp]) -> [Change] {
    let oldKeys = old.map(\.key), newKeys = new.map(\.key)
    var removed: [DockApp] = [], added: [DockApp] = [], pairs: [(DockApp, DockApp)] = []
    for op in SequenceMatcher(a: oldKeys, b: newKeys).opcodes() {
        switch op.tag {
        case .delete: removed += old[op.i1..<op.i2]
        case .insert: added += new[op.j1..<op.j2]
        case .replace:
            let olds = Array(old[op.i1..<op.i2]), news = Array(new[op.j1..<op.j2])
            let n = min(olds.count, news.count)
            pairs += zip(olds.prefix(n), news.prefix(n)).map { ($0, $1) }
            removed += olds.dropFirst(n)
            added += news.dropFirst(n)
        case .equal: break
        }
    }

    // An app that disappears in one place and reappears elsewhere just moved.
    let newSet = Set(newKeys), oldSet = Set(oldKeys)
    var movedKeys = Set(removed.map(\.key).filter(newSet.contains)).union(added.map(\.key).filter(oldSet.contains))
    var changes: [Change] = []
    for (o, n) in pairs {
        if newSet.contains(o.key) || oldSet.contains(n.key) {
            for a in [o, n] where newSet.contains(a.key) && oldSet.contains(a.key) { movedKeys.insert(a.key) }
            if !newSet.contains(o.key) { removed.append(o) }
            if !oldSet.contains(n.key) { added.append(n) }
        } else {
            changes.append(Change(.replaced, n, old: o))
        }
    }
    changes += added.filter { !movedKeys.contains($0.key) }.map { Change(.added, $0) }
    changes += removed.filter { !movedKeys.contains($0.key) }.map { Change(.removed, $0) }
    changes += new.filter { movedKeys.contains($0.key) }.map { Change(.moved, $0) }
    return changes
}
