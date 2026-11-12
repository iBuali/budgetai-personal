import Foundation
import PDFKit

/// Reconstructs supported statement tables using glyph positions, including rows split over pages.
/// No account data or learned personal values are persisted.
enum StatementPDFTable {
    private struct Word {
        var text: String
        var rect: CGRect // Top-left coordinates, in PDF points.
    }

    private struct Layout {
        var cuts: [CGFloat]
        var headers: [String]
        var dateEnd: CGFloat
        var headerBottom: CGFloat
    }

    private static func words(on page: PDFPage) -> [Word] {
        guard let text = page.string else { return [] }
        let ns = text as NSString
        let bounds = page.bounds(for: .mediaBox)
        var result: [Word] = []
        var current: Word?
        func flush() {
            if let word = current { result.append(word) }
            current = nil
        }
        for i in 0..<min(ns.length, page.numberOfCharacters) {
            let character = ns.substring(with: NSRange(location: i, length: 1))
            let rect = page.characterBounds(at: i)
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rect.isEmpty {
                flush()
                continue
            }
            let flipped = CGRect(x: rect.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
            if let previous = current,
               (abs(previous.rect.midY - flipped.midY) > max(2, flipped.height * 0.4) ||
                flipped.minX - previous.rect.maxX > max(2, flipped.height * 0.3) ||
                flipped.maxX < previous.rect.minX) {
                flush()
            }
            if current == nil {
                current = Word(text: character, rect: flipped)
            } else {
                current?.text += character
                current?.rect = current!.rect.union(flipped)
            }
        }
        flush()
        return result
    }

    private static func layout(in words: [Word], width: CGFloat) -> Layout? {
        for desc in words where desc.text.lowercased() == "description" {
            let near = words.filter { abs($0.rect.minY - desc.rect.minY) < max(18, desc.rect.height * 1.7) }
            let dates = near.filter { $0.text.lowercased() == "date" }.sorted { $0.rect.minX < $1.rect.minX }
            let amounts = near.filter { $0.text.lowercased() == "amount" }.sorted { $0.rect.minX < $1.rect.minX }
            guard let firstDate = dates.first, !amounts.isEmpty else { continue }
            func find(_ text: String) -> Word? { near.first { $0.text.lowercased() == text } }
            let headerBottom = near.map(\.rect.maxY).max()! + 1
            let card = find("vat") != nil && find("currency") != nil && dates.count > 1 && amounts.count > 1
            var cuts: [CGFloat]
            var headers: [String]
            var dateEnd = firstDate.rect.maxX + 8
            if find("debit") != nil, find("credit") != nil, let balance = find("balance"), amounts.count == 2 {
                let descriptionStart = (near.filter { $0.rect.minX < firstDate.rect.maxX }.map(\.rect.maxX).max() ?? dateEnd) + 5
                cuts = [0, descriptionStart, amounts[0].rect.minX - 10, amounts[1].rect.minX - 10, balance.rect.minX - 10, width]
                headers = ["Date", "Description", "Debit", "Credit", "Balance"]
            } else if card, let currency = find("currency"), let vat = find("vat") {
                dateEnd = dates[1].rect.minX - 5
                cuts = [0, dateEnd, desc.rect.minX - 8, currency.rect.minX - 8,
                        amounts[0].rect.minX - 8, amounts[1].rect.minX - 8, vat.rect.minX - 8, width]
                // The account-currency amount is deliberately preferred to the foreign amount.
                headers = ["Date", "Transaction Date", "Description", "Currency", "Foreign Amount", "Amount", "VAT"]
            } else if let value = find("value"), let balance = find("balance") {
                cuts = [0, desc.rect.minX - 8, value.rect.minX - 8, amounts[0].rect.minX - 8, balance.rect.minX - 8, width]
                headers = ["Date", "Description", "Value Date", "Amount", "Balance"]
                dateEnd = cuts[1]
            } else { continue }
            guard zip(cuts, cuts.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }) else { continue }
            return Layout(cuts: cuts, headers: headers, dateEnd: dateEnd, headerBottom: headerBottom)
        }
        return nil
    }

    static func extract(_ document: PDFDocument) -> String? {
        var table: Layout?
        var body: [Word] = []
        var offset: CGFloat = 0
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pageWords = words(on: page)
            let current = layout(in: pageWords, width: bounds.width)
            if let current { table = current }
            guard table != nil else { offset += bounds.height; continue }
            let top = current?.headerBottom ?? 0
            let bottom = pageWords.filter { $0.text == "This" && $0.rect.minY > bounds.height * 0.7 }.map(\.rect.minY).min() ?? bounds.height
            body += pageWords.filter { $0.rect.minY >= top && $0.rect.maxY <= bottom }.map {
                Word(text: $0.text, rect: $0.rect.offsetBy(dx: 0, dy: offset))
            }
            offset += bounds.height
        }
        guard let table else { return nil }
        func readingOrder(_ a: Word, _ b: Word) -> Bool {
            let ay = (a.rect.minY / 2).rounded(), by = (b.rect.minY / 2).rounded()
            return ay == by ? a.rect.minX < b.rect.minX : ay < by
        }
        let dateWords = body.filter { $0.rect.minX < table.dateEnd }.sorted(by: readingOrder)
        var dateText = ""
        var ranges: [(NSRange, Word)] = []
        for word in dateWords {
            ranges.append((NSRange(location: (dateText as NSString).length, length: (word.text as NSString).length), word))
            dateText += word.text + " "
        }
        let pattern = #"(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\s+)?(?:\d{1,2}\s+[A-Za-z]{3}\s+\d{2,4}|[A-Za-z]{3}\s+\d{1,2}\s+\d{4}|\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: dateText, range: NSRange(location: 0, length: (dateText as NSString).length))
        let anchors = matches.map { match in
            ranges.filter { NSIntersectionRange($0.0, match.range).length > 0 }.map(\.1.rect).reduce(CGRect.null) { $0.union($1) }
        }
        guard !anchors.isEmpty else { return "" }
        // Exclude the opening-balance row before the first dated transaction.
        var firstBoundary = body.map(\.rect.minY).min() ?? 0
        var firstCursor = firstBoundary
        var firstGap: CGFloat = 0
        for span in body.map(\.rect).filter({ $0.minY < anchors[0].minY }).sorted(by: { $0.minY < $1.minY }) {
            if span.minY - firstCursor > firstGap {
                firstGap = span.minY - firstCursor
                firstBoundary = (span.minY + firstCursor) / 2
            }
            firstCursor = max(firstCursor, span.maxY)
        }
        if anchors[0].minY - firstCursor > firstGap { firstBoundary = (anchors[0].minY + firstCursor) / 2 }
        var boundaries: [CGFloat] = [firstBoundary]
        for (previous, next) in zip(anchors, anchors.dropFirst()) {
            let start = previous.maxY, end = next.minY
            let spans = body.filter { $0.rect.maxY > start && $0.rect.minY < end }.map(\.rect).sorted { $0.minY < $1.minY }
            var cursor = start, largest: CGFloat = -1, boundary = (start + end) / 2
            for span in spans {
                let lo = max(start, span.minY)
                if lo - cursor > largest { largest = lo - cursor; boundary = (lo + cursor) / 2 }
                cursor = max(cursor, min(end, span.maxY))
            }
            if end - cursor > largest { boundary = (cursor + end) / 2 }
            boundaries.append(boundary)
        }
        let closingRow = body.filter { $0.text.lowercased() == "closing" && $0.rect.minY > anchors.last!.maxY }.map(\.rect.minY).min()
        boundaries.append(closingRow.map { $0 - 5 } ?? offset)
        var rows = [table.headers.joined(separator: "\t")]
        for (index, vertical) in zip(boundaries, boundaries.dropFirst()).enumerated() {
            var cells = zip(table.cuts, table.cuts.dropFirst()).map { left, right in
                body.filter { $0.rect.minX >= left && $0.rect.minX < right && $0.rect.midY >= vertical.0 && $0.rect.midY < vertical.1 }
                    .sorted(by: readingOrder).map(\.text).joined(separator: " ")
            }
            // Use the complete date match; a page break may split its glyphs across pages.
            cells[0] = (dateText as NSString).substring(with: matches[index].range)
            rows.append(cells.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: "\t"))
        }
        return rows.joined(separator: "\n")
    }
}
