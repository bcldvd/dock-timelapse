import Testing
@testable import DockCore

func kinds(_ changes: [Change]) -> [String] {
    changes.map { "\($0.kind.rawValue) \($0.app.bundleID!) \($0.old?.bundleID ?? "-")" }
}

@Test func noChange() { #expect(diffDocks(apps("a", "b"), apps("a", "b")).isEmpty) }
@Test func addedAtEnd() { #expect(kinds(diffDocks(apps("a"), apps("a", "b"))) == ["added b -"]) }
@Test func removed() { #expect(kinds(diffDocks(apps("a", "b", "c"), apps("a", "c"))) == ["removed b -"]) }
@Test func replacedInPlace() {
    #expect(kinds(diffDocks(apps("a", "vscode", "c"), apps("a", "cursor", "c"))) == ["replaced cursor vscode"])
}
@Test func unevenReplaceBlockGivesReplacedPlusAdded() {
    #expect(kinds(diffDocks(apps("a", "x", "c"), apps("a", "y", "z", "c"))) == ["replaced y x", "added z -"])
}
@Test func movedAppIsReportedAsMoved() {
    #expect(kinds(diffDocks(apps("a", "b", "c"), apps("b", "c", "a"))) == ["moved a -"])
}
@Test func firstSnapshotIsAllAdded() {
    #expect(diffDocks([], apps("a", "b")).map(\.kind) == [.added, .added])
}
@Test func changeDescribe() {
    #expect(Change(.replaced, apps("cursor")[0], old: apps("vscode")[0]).describe == "VSCODE → CURSOR")
    #expect(Change(.added, apps("x")[0]).describe == "+ X")
    #expect(Change(.removed, apps("x")[0]).describe == "− X")
}

/// 1500 random Dock pairs diffed by the Python engine: the Swift port must agree exactly.
@Test func matchesPythonOracle() throws {
    let cases = try fixture("diff") as! [[String: Any]]
    #expect(cases.count == 1500)
    for c in cases {
        let old = apps(c["old"] as! [String]), new = apps(c["new"] as! [String])
        let expected = (c["changes"] as! [[String: Any]]).map(decodeChange)
        #expect(diffDocks(old, new) == expected, "old=\(c["old"]!) new=\(c["new"]!)")
    }
}

@Test func sequenceMatcherOpcodesMatchPythonExamples() {
    // difflib docs: SequenceMatcher(None, "qabxcd", "abycdf").get_opcodes()
    let ops = SequenceMatcher(a: Array("qabxcd"), b: Array("abycdf")).opcodes()
    #expect(ops.map { "\($0.tag.rawValue) \($0.i1) \($0.i2) \($0.j1) \($0.j2)" } == [
        "delete 0 1 0 0", "equal 1 3 0 2", "replace 3 4 2 3", "equal 4 6 3 5", "insert 6 6 5 6",
    ])
}
