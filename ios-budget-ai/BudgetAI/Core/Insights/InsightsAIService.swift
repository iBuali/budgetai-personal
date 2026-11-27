import Foundation

struct DetectedProductInfo: Hashable {
    var name: String?
    var price: Double?
    var imageURL: String?
    var categoryRaw: String?
    var sourceNote: String
}

/// Independent AI intelligence layer grounded strictly in deterministic `FinancialProjectionEngine`
/// outputs and real product metadata. Never invents financial figures or mutates user records.
enum InsightsAIService {

    // MARK: - Product Metadata Detection (URL OpenGraph/JSON-LD + Optional Gemini)

    static func detectProductMetadata(queryOrURL: String, currency: String) async -> DetectedProductInfo? {
        let trimmed = queryOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var fetchedTitle: String? = nil
        var fetchedImage: String? = nil
        var fetchedPrice: Double? = nil
        var sourceNote = "Manual entry"

        // 1. If input looks like a URL, fetch real OpenGraph / JSON-LD metadata safely
        if let url = normalizedURL(from: trimmed) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile", forHTTPHeaderField: "User-Agent")

            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
               let html = String(data: data.prefix(200_000), encoding: .utf8) ?? String(data: data.prefix(200_000), encoding: .isoLatin1) {
                fetchedTitle = extractMetaContent(in: html, keys: ["og:title", "twitter:title"]) ?? extractHTMLTitle(in: html)
                fetchedImage = extractMetaContent(in: html, keys: ["og:image", "twitter:image"])
                if let img = fetchedImage, img.hasPrefix("//") {
                    fetchedImage = "https:" + img
                }
                fetchedPrice = extractPriceFromHTML(in: html)
                sourceNote = "Detected from product link"
            }
        }

        // 2. If Gemini is configured, refine clean product name, category, and estimate only when clearly known
        if GeminiAccount.isConfigured, let client = try? GeminiAccount.client() {
            let categories = SpendCategory.expenseCases.map(\.rawValue)
            let schema: [String: Any] = [
                "type": "OBJECT",
                "properties": [
                    "cleanName": ["type": "STRING", "nullable": true],
                    "estimatedPrice": ["type": "NUMBER", "nullable": true],
                    "category": ["type": "STRING", "enum": categories],
                    "imageURL": ["type": "STRING", "nullable": true]
                ],
                "required": ["category"]
            ]
            let prompt = """
            Extract clean product details for a personal wishlist in currency \(currency).
            Input: \(trimmed)
            Fetched page title: \(fetchedTitle ?? "none")
            Fetched page price: \(fetchedPrice.map { String(format: "%.3f", $0) } ?? "none")
            Fetched page image: \(fetchedImage ?? "none")
            RULES:
            - Never invent a fake price if you are not reasonably confident; return null for estimatedPrice if unknown.
            - If fetched page price is present, prefer it unless clearly wrong.
            - Return a short clean product title in cleanName.
            - Keep fetched page image URL if present; otherwise return null for imageURL.
            """
            if let reply = try? await client.generate(system: nil, turns: [GeminiTurn(isUser: true, text: prompt)], schema: schema, temperature: 0.1),
               let obj = try? GeminiClient.decodeObject(reply) {
                let aiName = (obj["cleanName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let aiPrice = (obj["estimatedPrice"] as? NSNumber)?.doubleValue
                let aiCat = obj["category"] as? String
                let aiImg = (obj["imageURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                let resolvedName = (aiName?.isEmpty == false ? aiName : nil) ?? fetchedTitle
                let resolvedPrice = fetchedPrice ?? ((aiPrice ?? 0) > 0 ? aiPrice : nil)
                let resolvedImage = fetchedImage ?? ((aiImg?.hasPrefix("http") == true) ? aiImg : nil)
                return DetectedProductInfo(
                    name: resolvedName,
                    price: resolvedPrice,
                    imageURL: resolvedImage,
                    categoryRaw: aiCat,
                    sourceNote: fetchedPrice != nil ? "Detected from link & AI" : (resolvedPrice != nil ? "Estimated by AI (verify price)" : "Name & category detected by AI")
                )
            }
        }

        if fetchedTitle != nil || fetchedPrice != nil || fetchedImage != nil {
            return DetectedProductInfo(
                name: fetchedTitle,
                price: fetchedPrice,
                imageURL: fetchedImage,
                categoryRaw: SpendCategory.shopping.rawValue,
                sourceNote: sourceNote
            )
        }
        return nil
    }

    // MARK: - Grounded AI Forecast Insight

    static func enhanceForecastInsight(projection: FinancialProjectionResult, currency: String) async -> PrimaryForecastInsight? {
        guard projection.hasSufficientData, GeminiAccount.isConfigured, let client = try? GeminiAccount.client() else {
            return nil
        }
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "title": ["type": "STRING"],
                "what": ["type": "STRING"],
                "why": ["type": "STRING"],
                "when": ["type": "STRING"],
                "action": ["type": "STRING"]
            ],
            "required": ["title", "what", "why", "when", "action"]
        ]
        let topEvents = projection.events.prefix(8).map {
            "- \($0.title) (\($0.kind.title)) on \($0.date.formatted(.dateTime.month(.abbreviated).day())): \(Money.format($0.amount, currency))"
        }.joined(separator: "\n")
        let system = """
        You are FALAK's financial intelligence assistant. Write one concise, actionable forecast insight strictly from the verified engine data provided.
        CRITICAL RULES:
        - NEVER invent numbers, dates, bills, or income that are not in the input.
        - Keep each field to 1 short sentence (title under 50 chars).
        - Clearly distinguish confirmed commitments from estimated pace.
        """
        let prompt = """
        Period: \(projection.period.title)
        Currency: \(currency)
        Starting balance: \(Money.format(projection.startingBalance, currency))
        Projected end balance: \(Money.format(projection.projectedEndBalance, currency))
        Lowest projected balance: \(Money.format(projection.lowestBalance, currency)) on \(projection.lowestBalanceDate.formatted(.dateTime.month(.abbreviated).day()))
        Expected monthly income: \(Money.format(projection.expectedMonthlyIncome, currency))
        Expected monthly expenses: \(Money.format(projection.expectedMonthlyExpenses, currency))
        Monthly commitments (bills + loans): \(Money.format(projection.expectedMonthlyCommitments, currency))
        Shortfall date: \(projection.shortfallDate?.formatted(.dateTime.month(.abbreviated).day()) ?? "None")
        Upcoming events:
        \(topEvents.isEmpty ? "None" : topEvents)
        """
        guard let reply = try? await client.generate(system: system, turns: [GeminiTurn(isUser: true, text: prompt)], schema: schema, temperature: 0.2),
              let obj = try? GeminiClient.decodeObject(reply),
              let title = obj["title"] as? String,
              let what = obj["what"] as? String,
              let why = obj["why"] as? String,
              let when = obj["when"] as? String,
              let action = obj["action"] as? String else {
            return nil
        }
        return PrimaryForecastInsight(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            what: what.trimmingCharacters(in: .whitespacesAndNewlines),
            why: why.trimmingCharacters(in: .whitespacesAndNewlines),
            when: when.trimmingCharacters(in: .whitespacesAndNewlines),
            action: action.trimmingCharacters(in: .whitespacesAndNewlines),
            severity: projection.primaryInsight.severity,
            isAIEnhanced: true
        )
    }

    // MARK: - Grounded AI Recommendations for Simulations & Wishlist

    static func generateBuyNowRecommendation(simulation: BuyNowSimulationResult, currency: String) async -> String? {
        guard GeminiAccount.isConfigured, let client = try? GeminiAccount.client() else { return nil }
        let prompt = """
        Give a concise 2-sentence practical recommendation for this hypothetical purchase in \(currency). Never invent numbers.
        Purchase: \(simulation.input.name.isEmpty ? "Unnamed item" : simulation.input.name) for \(Money.format(simulation.input.amount, currency))
        Overall status: \(simulation.overallStatus.title)
        Safe to Spend: \(Money.format(simulation.safeToSpend.before, currency)) -> \(Money.format(simulation.safeToSpend.after, currency))
        Budget remaining: \(Money.format(simulation.budget.beforeRemaining, currency)) -> \(Money.format(simulation.budget.afterRemaining, currency))
        Bills covered: \(simulation.bills.billsCovered), Loans covered: \(simulation.bills.loansCovered), Cash shortfall: \(simulation.bills.createsCashShortfall)
        Goal delay days: \(simulation.savingGoals.estimatedDelayDays.map(String.init) ?? "none")
        """
        let reply = try? await client.generate(
            system: "You are FALAK, a concise, honest personal finance advisor. Use only the provided verified numbers.",
            turns: [GeminiTurn(isUser: true, text: prompt)],
            schema: nil,
            temperature: 0.25
        )
        let clean = reply?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean?.isEmpty == false) ? clean : nil
    }

    static func generateSavingGoalAdvice(simulation: SavingGoalSimulationResult, currency: String) async -> String? {
        guard GeminiAccount.isConfigured, let client = try? GeminiAccount.client() else { return nil }
        let prompt = """
        Give a concise 2-sentence practical saving plan suggestion in \(currency). Never invent numbers.
        Goal: \(simulation.input.name.isEmpty ? "New Goal" : simulation.input.name), target \(Money.format(simulation.input.targetAmount, currency)), remaining \(Money.format(simulation.remainingAmount, currency))
        Required monthly: \(Money.format(simulation.requiredMonthlyContribution, currency)) over \(String(format: "%.1f", simulation.remainingMonths)) months
        Achievable: \(simulation.isAchievable), Sustainable: \(simulation.isSustainable)
        Safe to Spend: \(Money.format(simulation.safeToSpendBeforeMonthly, currency)) -> \(Money.format(simulation.safeToSpendAfterMonthly, currency))
        Adjustable categories: \(simulation.adjustableCategories.joined(separator: ", "))
        """
        let reply = try? await client.generate(
            system: "You are FALAK, a concise, honest personal finance advisor. Use only the provided verified numbers.",
            turns: [GeminiTurn(isUser: true, text: prompt)],
            schema: nil,
            temperature: 0.25
        )
        let clean = reply?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean?.isEmpty == false) ? clean : nil
    }

    // MARK: - Private HTML Parsing Helpers

    private static func normalizedURL(from text: String) -> URL? {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text)
        }
        if lower.hasPrefix("www.") {
            return URL(string: "https://" + text)
        }
        return nil
    }

    private static func extractMetaContent(in html: String, keys: [String]) -> String? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let patterns = [
                "(?is)<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']+)[\"']",
                "(?is)<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"']\(escaped)[\"']"
            ]
            for pat in patterns {
                if let regex = try? NSRegularExpression(pattern: pat),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let r = Range(match.range(at: 1), in: html) {
                    let val = decodeHTMLEntities(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { return val }
                }
            }
        }
        return nil
    }

    private static func extractHTMLTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<title[^>]*>([^<]+)</title>"),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let val = decodeHTMLEntities(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
        return val.isEmpty ? nil : val
    }

    private static func extractPriceFromHTML(in html: String) -> Double? {
        if let metaPrice = extractMetaContent(in: html, keys: ["product:price:amount", "og:price:amount"]),
           let parsed = Money.parse(metaPrice), parsed > 0 {
            return parsed
        }
        let jsonLDPattern = #"(?i)"price"\s*:\s*"?([0-9][0-9,]*(?:\.[0-9]{1,3})?)"?"#
        if let regex = try? NSRegularExpression(pattern: jsonLDPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(match.range(at: 1), in: html),
           let parsed = Money.parse(String(html[r])), parsed > 0 {
            return parsed
        }
        return nil
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
