import Foundation

/// Small OpenXML reader. Cell addresses preserve blank columns; only date-styled cells become dates.
enum StatementWorkbookXML {
    final class Node {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        init(_ name: String, _ attributes: [String: String] = [:]) {
            self.name = name.components(separatedBy: ":").last ?? name
            self.attributes = attributes
        }
        func descendants(_ name: String) -> [Node] {
            children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
        }
    }
    private final class Reader: NSObject, XMLParserDelegate {
        let root = Node("root")
        var stack: [Node] = []
        override init() { super.init(); stack = [root] }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let node = Node(elementName, attributeDict)
            stack.last?.children.append(node)
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { stack.removeLast() }
    }
    static func read(_ xml: String) -> Node? {
        let reader = Reader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        return parser.parse() ? reader.root : nil
    }
    static func sharedStrings(_ xml: String) -> [String] {
        read(xml)?.descendants("si").map { $0.descendants("t").map(\.text).joined() } ?? []
    }
    static func dateStyles(_ xml: String) -> Set<Int> {
        guard let root = read(xml) else { return [] }
        var dateFormats = Set([14,15,16,17,18,19,20,21,22,27,30,36,45,46,47,50,57])
        for format in root.descendants("numFmt") {
            guard let id = Int(format.attributes["numFmtId"] ?? "") else { continue }
            let code = (format.attributes["formatCode"] ?? "").lowercased()
                .replacingOccurrences(of: #"\"[^\"]*\"|\[[^\]]*\]|\\."#, with: "", options: .regularExpression)
            if code.contains("y") || code.contains("d") { dateFormats.insert(id) }
        }
        let styles = root.descendants("cellXfs").first?.children ?? []
        return Set(styles.enumerated().compactMap { index, style in
            dateFormats.contains(Int(style.attributes["numFmtId"] ?? "") ?? -1) ? index : nil
        })
    }
    static func worksheet(_ xml: String, strings: [String], dateStyles: Set<Int>, date1904: Bool) -> String {
        guard let root = read(xml) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return root.descendants("row").map { row in
            var cells: [String] = []
            for cell in row.children where cell.name == "c" {
                let letters = (cell.attributes["r"] ?? "").prefix { $0.isLetter }
                let column = letters.uppercased().utf8.reduce(0) { $0 * 26 + Int($1) - 64 }
                let index = column > 0 ? column - 1 : cells.count
                guard index < 16384 else { continue }
                while cells.count <= index { cells.append("") }
                let raw = cell.children.first { $0.name == "v" }?.text ?? ""
                var value = raw
                switch cell.attributes["t"] {
                case "s":
                    value = Int(raw).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? ""
                case "inlineStr": value = cell.descendants("t").map(\.text).joined()
                case "str": value = raw
                case "e", "b": value = ""
                default:
                    if dateStyles.contains(Int(cell.attributes["s"] ?? "0") ?? 0),
                       let serial = Double(raw), serial > 1000 && serial < 100000 {
                        value = formatter.string(from: Date(timeIntervalSince1970: (floor(serial) - (date1904 ? 24107 : 25569)) * 86400))
                    }
                }
                cells[index] = "\"" + value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return cells.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
