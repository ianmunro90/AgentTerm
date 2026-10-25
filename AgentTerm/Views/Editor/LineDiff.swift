import Foundation

/// Lines of two versions of a file paired up for a side-by-side view, and the change marks
/// VS Code draws beside the line numbers.
enum LineDiff {
    struct Row {
        /// 0-based line in the old and new version; nil is a filler opposite added or removed lines.
        let old: Int?
        let new: Int?
        let changed: Bool
    }

    enum Mark {
        case added, modified
        /// Lines were removed just above (or, on the last line, just below) this one.
        case deletedAbove, deletedBelow
    }

    static func lines(_ text: String) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }   // the final newline
        return lines
    }

    /// Unchanged lines side by side; each run of changes pairs removed with added lines, with
    /// fillers opposite the extra ones.
    static func align(_ old: [Substring], _ new: [Substring]) -> [Row] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if (i < old.count && removed.contains(i)) || (j < new.count && inserted.contains(j)) || i >= old.count || j >= new.count {
                var gone: [Int] = []
                var added: [Int] = []
                while i < old.count, removed.contains(i) || j >= new.count { gone.append(i); i += 1 }
                while j < new.count, inserted.contains(j) || i >= old.count { added.append(j); j += 1 }
                for k in 0..<max(gone.count, added.count) {
                    rows.append(Row(old: k < gone.count ? gone[k] : nil, new: k < added.count ? added[k] : nil, changed: true))
                }
            } else {
                rows.append(Row(old: i, new: j, changed: false))
                i += 1
                j += 1
            }
        }
        return rows
    }

    /// Gutter marks for the new version, keyed by 0-based line.
    static func marks(_ rows: [Row], newCount: Int) -> [Int: Mark] {
        var marks: [Int: Mark] = [:]
        var index = 0
        while index < rows.count {
            guard rows[index].changed else { index += 1; continue }
            var end = index
            while end < rows.count, rows[end].changed { end += 1 }
            let run = rows[index..<end]
            let newLines = run.compactMap(\.new)
            if newLines.isEmpty {
                // Pure deletion: point at the next surviving line.
                let next = rows[end...].lazy.compactMap(\.new).first
                if let next { marks[next] = .deletedAbove } else if newCount > 0 { marks[newCount - 1] = .deletedBelow }
            } else {
                let kind: Mark = run.contains { $0.old != nil } ? .modified : .added
                for line in newLines { marks[line] = kind }
            }
            index = end
        }
        return marks
    }
}

/// Lanes for a commit graph, laid out row by row like VS Code's (and `git log --graph`'s).
enum CommitGraph {
    struct Segment: Hashable {
        enum Point: Hashable { case top, middle, bottom }
        let fromLane: Int
        let from: Point
        let toLane: Int
        let to: Point
        /// Which lane's colour it's drawn in.
        let colorLane: Int
    }

    struct Row: Hashable {
        let lane: Int
        let segments: [Segment]
        /// Lanes still running below the commit, drawn straight through anything shown under
        /// its row (its expanded files).
        let continuing: [Int]
        let width: Int
    }

    static func layout(_ commits: [ExplorerModel.Commit]) -> [Row] {
        var lanes: [String?] = []
        var rows: [Row] = []
        for commit in commits {
            var segments: [Segment] = []
            let lane = lanes.firstIndex(of: commit.sha) ?? lanes.firstIndex(of: nil) ?? lanes.count
            if lane == lanes.count { lanes.append(nil) }

            // From the top: lanes waiting for this commit join it; the rest pass by.
            for (index, expected) in lanes.enumerated() {
                guard let expected else { continue }
                if expected == commit.sha {
                    segments.append(Segment(fromLane: index, from: .top, toLane: lane, to: .middle, colorLane: index))
                    lanes[index] = nil
                } else {
                    segments.append(Segment(fromLane: index, from: .top, toLane: index, to: .bottom, colorLane: index))
                }
            }

            // To the bottom: the first parent carries on in this lane (even if another lane
            // expects it too: they join at the parent, so main lines stay put), others branch off.
            if let first = commit.parents.first {
                lanes[lane] = first
                segments.append(Segment(fromLane: lane, from: .middle, toLane: lane, to: .bottom, colorLane: lane))
            }
            for parent in commit.parents.dropFirst() {
                let target: Int
                if let existing = lanes.firstIndex(of: parent) {
                    target = existing
                } else {
                    target = lanes.firstIndex(of: nil) ?? lanes.count
                    if target == lanes.count { lanes.append(nil) }
                    lanes[target] = parent
                }
                segments.append(Segment(fromLane: lane, from: .middle, toLane: target, to: .bottom, colorLane: target))
            }

            while lanes.last == .some(nil) { lanes.removeLast() }
            let continuing = lanes.indices.filter { lanes[$0] != nil }
            let width = max(lane + 1, segments.map { max($0.fromLane, $0.toLane) + 1 }.max() ?? 1)
            rows.append(Row(lane: lane, segments: segments, continuing: continuing, width: width))
        }
        return rows
    }
}
