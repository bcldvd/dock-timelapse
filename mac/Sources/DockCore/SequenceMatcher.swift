/// A faithful port of Python's `difflib.SequenceMatcher` (no junk, `autojunk=False`), which the original
/// engine used to diff Docks and animate transitions. Same algorithm, same tie-breaks, same opcodes.
struct SequenceMatcher<Element: Hashable> {
    enum Tag: String { case replace, delete, insert, equal }

    struct Opcode: Equatable {
        let tag: Tag
        let i1: Int, i2: Int, j1: Int, j2: Int
    }

    let a: [Element]
    let b: [Element]
    private let b2j: [Element: [Int]]

    init(a: [Element], b: [Element]) {
        self.a = a
        self.b = b
        var index: [Element: [Int]] = [:]
        for (j, element) in b.enumerated() { index[element, default: []].append(j) }
        b2j = index
    }

    func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var (besti, bestj, bestsize) = (alo, blo, 0)
        var j2len: [Int: Int] = [:]
        for i in alo..<max(alo, ahi) {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize { (besti, bestj, bestsize) = (i - k + 1, j - k + 1, k) }
            }
            j2len = newj2len
        }
        while besti > alo, bestj > blo, a[besti - 1] == b[bestj - 1] {
            besti -= 1; bestj -= 1; bestsize += 1
        }
        while besti + bestsize < ahi, bestj + bestsize < bhi, a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return (besti, bestj, bestsize)
    }

    func matchingBlocks() -> [(Int, Int, Int)] {
        var queue = [(0, a.count, 0, b.count)]
        var blocks: [(Int, Int, Int)] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = findLongestMatch(alo, ahi, blo, bhi)
            if k > 0 {
                blocks.append((i, j, k))
                if alo < i && blo < j { queue.append((alo, i, blo, j)) }
                if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
            }
        }
        blocks.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        var (i1, j1, k1) = (0, 0, 0)
        var merged: [(Int, Int, Int)] = []
        for (i2, j2, k2) in blocks {
            if i1 + k1 == i2 && j1 + k1 == j2 {
                k1 += k2
            } else {
                if k1 > 0 { merged.append((i1, j1, k1)) }
                (i1, j1, k1) = (i2, j2, k2)
            }
        }
        if k1 > 0 { merged.append((i1, j1, k1)) }
        merged.append((a.count, b.count, 0))
        return merged
    }

    func opcodes() -> [Opcode] {
        var (i, j) = (0, 0)
        var answer: [Opcode] = []
        for (ai, bj, size) in matchingBlocks() {
            let tag: Tag? = i < ai && j < bj ? .replace : i < ai ? .delete : j < bj ? .insert : nil
            if let tag { answer.append(Opcode(tag: tag, i1: i, i2: ai, j1: j, j2: bj)) }
            (i, j) = (ai + size, bj + size)
            if size > 0 { answer.append(Opcode(tag: .equal, i1: ai, i2: i, j1: bj, j2: j)) }
        }
        return answer
    }
}
