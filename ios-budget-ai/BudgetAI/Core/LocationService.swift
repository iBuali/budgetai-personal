import Foundation
import CoreLocation
import MapKit
import SwiftUI

struct TransactionLocationData: Equatable, Sendable {
    var name: String
    var address: String?
    var latitude: Double?
    var longitude: Double?
}

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    var isFetching = false
    var lastError: String?
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Fast non-blocking check for a recently cached GPS location
    var cachedRecentLocation: CLLocation? {
        guard let loc = manager.location else { return nil }
        if abs(loc.timestamp.timeIntervalSinceNow) < 900,
           (-90.0...90.0).contains(loc.coordinate.latitude),
           (-180.0...180.0).contains(loc.coordinate.longitude),
           (abs(loc.coordinate.latitude) > 0.0001 || abs(loc.coordinate.longitude) > 0.0001) {
            return loc
        }
        return nil
    }

    @MainActor
    func captureCurrentLocation(fallbackPlaceName: String? = nil, timeoutSeconds: Double = 1.0) async -> TransactionLocationData? {
        // Fast-path: use cached recent location without waking GPS hardware
        if let cached = cachedRecentLocation {
            return await reverseGeocode(location: cached, fallbackPlaceName: fallbackPlaceName, maxWaitSeconds: 0.8)
        }

        isFetching = true
        lastError = nil
        defer { isFetching = false }

        let currentStatus = manager.authorizationStatus
        guard currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways else {
            if currentStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            lastError = "Location access is not enabled in Settings."
            return nil
        }

        let loc: CLLocation? = await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { cont in
                    if let existing = self.continuation {
                        self.continuation = nil
                        existing.resume(returning: nil)
                    }
                    self.continuation = cont
                    self.manager.requestLocation()
                }
            }
            group.addTask {
                let nanoseconds = UInt64(max(0.3, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let firstResult = await group.next() ?? nil
            await MainActor.run {
                if let cont = self.continuation {
                    self.continuation = nil
                    cont.resume(returning: nil)
                }
            }
            group.cancelAll()
            return firstResult
        }

        guard let loc else {
            lastError = "Unable to determine current location."
            return nil
        }

        return await reverseGeocode(location: loc, fallbackPlaceName: fallbackPlaceName, maxWaitSeconds: 0.8)
    }

    func reverseGeocode(location: CLLocation, fallbackPlaceName: String? = nil, maxWaitSeconds: Double = 0.8) async -> TransactionLocationData {
        var placeName = fallbackPlaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var addressParts: [String] = []

        let placemark: CLPlacemark? = await withTaskGroup(of: CLPlacemark?.self) { group in
            group.addTask {
                let geocoder = CLGeocoder()
                if let placemarks = try? await geocoder.reverseGeocodeLocation(location), let first = placemarks.first {
                    return first
                }
                return nil
            }
            group.addTask {
                let nanos = UInt64(max(0.2, maxWaitSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let res = await group.next() ?? nil
            group.cancelAll()
            return res
        }

        if let pm = placemark {
            if placeName.isEmpty || isGenericPlaceName(placeName) {
                placeName = pm.name ?? pm.subLocality ?? pm.locality ?? "Current Location"
            }
            if let thoroughfare = pm.thoroughfare, thoroughfare != placeName {
                addressParts.append(thoroughfare)
            }
            if let subLocality = pm.subLocality, subLocality != placeName, !addressParts.contains(subLocality) {
                addressParts.append(subLocality)
            }
            if let locality = pm.locality, locality != placeName, !addressParts.contains(locality) {
                addressParts.append(locality)
            }
            if let country = pm.country, !addressParts.contains(country) {
                addressParts.append(country)
            }
        }

        if placeName.isEmpty {
            placeName = "Purchase Location"
        }

        return TransactionLocationData(
            name: placeName,
            address: addressParts.isEmpty ? nil : addressParts.joined(separator: ", "),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    private func isGenericPlaceName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let generics: Set<String> = [
            "current location", "purchase location", "purchase", "expense", "debit",
            "card purchase", "pos purchase", "transaction", "payment", "fawri+", "fawri transfer",
            "bank transfer", "transfer out", "transfer in", "incoming", "outgoing"
        ]
        return generics.contains(lower) || lower.isEmpty
    }

    /// Automatically resolves location from:
    /// 1. Explicit coordinates (e.g. from Shortcuts 'Get Current Location' → Latitude/Longitude)
    /// 2. Raw location/address string from Shortcuts 'Current Location'
    /// 3. Real-time GPS capture when live SMS arrives (AddBankSMSIntent)
    /// 4. Fallback inference from SMS text & merchant keywords
    @MainActor
    func resolveLocation(
        rawInput: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        rawSMS: String? = nil,
        merchant: String? = nil,
        autoCaptureGPS: Bool = false
    ) async -> TransactionLocationData? {
        // 1. Explicit valid coordinates passed in
        if let lat = latitude, let lon = longitude,
           (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon),
           (abs(lat) > 0.0001 || abs(lon) > 0.0001) {
            let clLoc = CLLocation(latitude: lat, longitude: lon)
            return await reverseGeocode(location: clLoc, fallbackPlaceName: merchant ?? rawInput, maxWaitSeconds: 0.8)
        }

        // 2. Coordinate numbers or address passed as rawInput string
        if let raw = rawInput?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let coords = Self.parseCoordinates(from: raw) {
                let clLoc = CLLocation(latitude: coords.latitude, longitude: coords.longitude)
                return await reverseGeocode(location: clLoc, fallbackPlaceName: merchant, maxWaitSeconds: 0.8)
            }

            if !isGenericPlaceName(raw) {
                let placemark: CLPlacemark? = await withTaskGroup(of: CLPlacemark?.self) { group in
                    group.addTask {
                        let geocoder = CLGeocoder()
                        if let placemarks = try? await geocoder.geocodeAddressString(raw), let pm = placemarks.first {
                            return pm
                        }
                        return nil
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        return nil
                    }
                    let res = await group.next() ?? nil
                    group.cancelAll()
                    return res
                }

                if let pm = placemark, let loc = pm.location {
                    var parts: [String] = []
                    if let thoroughfare = pm.thoroughfare { parts.append(thoroughfare) }
                    if let sub = pm.subLocality, !parts.contains(sub) { parts.append(sub) }
                    if let city = pm.locality, !parts.contains(city) { parts.append(city) }
                    if let country = pm.country, !parts.contains(country) { parts.append(country) }

                    let cleanMerchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let name = (!cleanMerchant.isEmpty && !isGenericPlaceName(cleanMerchant)) ? cleanMerchant : (pm.name ?? raw)
                    return TransactionLocationData(
                        name: name,
                        address: parts.isEmpty ? raw : parts.joined(separator: ", "),
                        latitude: loc.coordinate.latitude,
                        longitude: loc.coordinate.longitude
                    )
                }

                let cleanMerchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let displayName = (!cleanMerchant.isEmpty && !isGenericPlaceName(cleanMerchant)) ? cleanMerchant : raw
                return TransactionLocationData(
                    name: displayName,
                    address: raw,
                    latitude: nil,
                    longitude: nil
                )
            }
        }

        // 3. Automatic GPS capture when triggered by live SMS automation (AddBankSMSIntent)
        if autoCaptureGPS {
            if let liveGPS = await captureCurrentLocation(fallbackPlaceName: merchant, timeoutSeconds: 1.0) {
                return liveGPS
            }
        }

        // 4. Inferred location from SMS text and merchant keywords
        if let inferred = Self.inferLocation(from: rawSMS, merchant: merchant ?? "") {
            return inferred
        }

        return nil
    }

    static func parseCoordinates(from string: String) -> (latitude: Double, longitude: Double)? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "N", with: "")
            .replacingOccurrences(of: "E", with: "")
            .components(separatedBy: CharacterSet(charactersIn: ", \t"))
            .filter { !$0.isEmpty }
        if parts.count >= 2,
           let lat = Double(parts[0]),
           let lon = Double(parts[1]),
           (-90.0...90.0).contains(lat),
           (-180.0...180.0).contains(lon) {
            return (lat, lon)
        }
        return nil
    }

    func searchPlaces(query: String) async -> [TransactionLocationData] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        // Default region centered around Bahrain for fast local merchant/place discovery
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 26.2235, longitude: 50.5876),
            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
        )

        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return [] }

        return response.mapItems.prefix(12).map { item in
            let pm = item.placemark
            var parts: [String] = []
            if let street = pm.thoroughfare { parts.append(street) }
            if let area = pm.subLocality, !parts.contains(area) { parts.append(area) }
            if let city = pm.locality, !parts.contains(city) { parts.append(city) }
            if let country = pm.country, !parts.contains(country) { parts.append(country) }

            return TransactionLocationData(
                name: item.name ?? pm.name ?? trimmed,
                address: parts.isEmpty ? nil : parts.joined(separator: ", "),
                latitude: pm.coordinate.latitude,
                longitude: pm.coordinate.longitude
            )
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in
            if let cont = self.continuation {
                self.continuation = nil
                cont.resume(returning: loc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let cont = self.continuation {
                self.continuation = nil
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: Bahrain & Regional Place Recognition from SMS / Merchant

    private struct KnownPlace {
        let keywords: [String]
        let name: String
        let address: String
        let lat: Double
        let lon: Double
    }

    private static let knownBahrainPlaces: [KnownPlace] = [
        KnownPlace(keywords: ["city centre", "city center", "ccb"], name: "City Centre Bahrain", address: "Seef District, Manama, Bahrain", lat: 26.2336, lon: 50.5532),
        KnownPlace(keywords: ["the avenues", "avenues bahrain", "avenues mall"], name: "The Avenues Bahrain", address: "Bahrain Bay, Manama, Bahrain", lat: 26.2442, lon: 50.5738),
        KnownPlace(keywords: ["seef mall"], name: "Seef Mall", address: "Seef District, Manama, Bahrain", lat: 26.2335, lon: 50.5414),
        KnownPlace(keywords: ["marassi galleria", "marassi"], name: "Marassi Galleria", address: "Diyar Al Muharraq, Bahrain", lat: 26.2981, lon: 50.6531),
        KnownPlace(keywords: ["moda mall", "world trade center"], name: "Moda Mall", address: "Manama, Bahrain", lat: 26.2393, lon: 50.5813),
        KnownPlace(keywords: ["al liwan", "liwan"], name: "Al Liwan", address: "Hamala, Bahrain", lat: 26.1472, lon: 50.4764),
        KnownPlace(keywords: ["dragon city"], name: "Dragon City Bahrain", address: "Diyar Al Muharraq, Bahrain", lat: 26.2869, lon: 50.6331),
        KnownPlace(keywords: ["oasis mall", "juffair"], name: "Oasis Mall Juffair", address: "Juffair, Manama, Bahrain", lat: 26.2125, lon: 50.6068),
        KnownPlace(keywords: ["enma mall", "riffa"], name: "Enma Mall", address: "East Riffa, Bahrain", lat: 26.1353, lon: 50.5681),
        KnownPlace(keywords: ["saar mall", "saar"], name: "Saar Mall", address: "Saar, Bahrain", lat: 26.1972, lon: 50.4931),
        KnownPlace(keywords: ["atrium mall"], name: "The Atrium Mall", address: "Janabiyah, Bahrain", lat: 26.1786, lon: 50.4717),
        KnownPlace(keywords: ["dana mall"], name: "Dana Mall", address: "Sanabis, Manama, Bahrain", lat: 26.2286, lon: 50.5469),
        KnownPlace(keywords: ["lulu hypermarket", "lulu"], name: "LuLu Hypermarket", address: "Manama, Bahrain", lat: 26.2289, lon: 50.5471),
        KnownPlace(keywords: ["carrefour"], name: "Carrefour Bahrain", address: "City Centre Bahrain, Seef", lat: 26.2336, lon: 50.5532),
        KnownPlace(keywords: ["alosra"], name: "Alosra Supermarket", address: "Saar / Amwaj, Bahrain", lat: 26.1985, lon: 50.4922),
        KnownPlace(keywords: ["aljazira", "al jazira"], name: "Al Jazira Supermarket", address: "Zinj, Manama, Bahrain", lat: 26.2089, lon: 50.5761),
        KnownPlace(keywords: ["megamart"], name: "Megamart", address: "Juffair, Manama, Bahrain", lat: 26.2145, lon: 50.6042),
        KnownPlace(keywords: ["ikea"], name: "IKEA Bahrain", address: "Salmabad, Bahrain", lat: 26.1833, lon: 50.5256),
        KnownPlace(keywords: ["bapco", "sadeem"], name: "Bapco Service Station", address: "Bahrain", lat: 26.1658, lon: 50.5475),
        KnownPlace(keywords: ["adliya", "block 338"], name: "Block 338, Adliya", address: "Adliya, Manama, Bahrain", lat: 26.2147, lon: 50.5881),
        KnownPlace(keywords: ["amwaj"], name: "Amwaj Islands", address: "Muharraq, Bahrain", lat: 26.2886, lon: 50.6631),
        KnownPlace(keywords: ["muharraq"], name: "Muharraq", address: "Muharraq, Bahrain", lat: 26.2572, lon: 50.6119),
        KnownPlace(keywords: ["isa town"], name: "Isa Town", address: "Isa Town, Bahrain", lat: 26.1736, lon: 50.5478),
        KnownPlace(keywords: ["hamad town"], name: "Hamad Town", address: "Hamad Town, Bahrain", lat: 26.1153, lon: 50.5069),
        KnownPlace(keywords: ["bahrain airport", "bah airport", "duty free"], name: "Bahrain International Airport", address: "Muharraq, Bahrain", lat: 26.2708, lon: 50.6336)
    ]

    static func inferLocation(from text: String?, merchant: String) -> TransactionLocationData? {
        let combined = "\(merchant) \(text ?? "")".lowercased()
        for place in knownBahrainPlaces {
            if place.keywords.contains(where: { combined.contains($0) }) {
                let displayTitle = merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? place.name : merchant
                return TransactionLocationData(
                    name: displayTitle,
                    address: place.address,
                    latitude: place.lat,
                    longitude: place.lon
                )
            }
        }
        return nil
    }
}

// MARK: - Apple Wallet Style Location Card

struct TransactionLocationCard: View {
    let placeName: String
    let address: String?
    let latitude: Double?
    let longitude: Double?
    var onCaptureCurrent: (() -> Void)? = nil
    var onSearchPlace: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    private var coordinate: CLLocationCoordinate2D {
        if let lat = latitude, let lon = longitude, abs(lat) > 0.0001 || abs(lon) > 0.0001 {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        // Fallback center in Manama, Bahrain when only place name is stored
        return CLLocationCoordinate2D(latitude: 26.2235, longitude: 50.5876)
    }

    private var cameraPosition: MapCameraPosition {
        .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Small Apple Wallet–style map header
            ZStack(alignment: .topTrailing) {
                Map(position: .constant(cameraPosition), interactionModes: []) {
                    Marker(placeName, coordinate: coordinate)
                        .tint(Theme.brand)
                }
                .frame(height: 148)
                .allowsHitTesting(false)

                Button {
                    openInAppleMaps()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square.fill")
                        Text("Maps")
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(Theme.ink)
                }
                .padding(10)
            }

            // Place of purchase row directly under the map (Apple Wallet style)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.brand.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(placeName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)

                    if let address, !address.isEmpty {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(2)
                    } else if let lat = latitude, let lon = longitude {
                        Text(String(format: "%.4f, %.4f", lat, lon))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }

                Spacer()

                if onSearchPlace != nil || onRemove != nil {
                    Menu {
                        if let onSearchPlace {
                            Button {
                                onSearchPlace()
                            } label: {
                                Label("Edit Location / Move Pin", systemImage: "map.fill")
                            }
                        }
                        Button {
                            openInAppleMaps()
                        } label: {
                            Label("Open in Apple Maps", systemImage: "arrow.up.right.square")
                        }
                        if let onRemove {
                            Divider()
                            Button(role: .destructive) {
                                onRemove()
                            } label: {
                                Label("Remove Location", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
            .padding(14)
            .background(Theme.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func openInAppleMaps() {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = placeName
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))
        ])
    }
}

// MARK: - Location Picker Sheet (Search + Interactive Movable Pin Map)

struct LocationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialName: String
    var initialLatitude: Double? = nil
    var initialLongitude: Double? = nil
    let onSelect: (TransactionLocationData) -> Void

    init(
        initialName: String,
        initialLatitude: Double? = nil,
        initialLongitude: Double? = nil,
        onSelect: @escaping (TransactionLocationData) -> Void
    ) {
        self.initialName = initialName
        self.initialLatitude = initialLatitude
        self.initialLongitude = initialLongitude
        self.onSelect = onSelect
    }

    // Default coordinate: provided coordinates, or center of Manama, Bahrain (26.2235, 50.5876)
    @State private var pinCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 26.2235, longitude: 50.5876)
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var placeName: String = ""
    @State private var placeAddress: String = ""
    @State private var searchQuery: String = ""
    @State private var searchResults: [TransactionLocationData] = []
    @State private var isSearching = false
    @State private var isReverseGeocoding = false
    @State private var hasDroppedPin: Bool = false
    @State private var reverseGeocodeTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Search Bar
                searchHeaderView

                // Search Results Dropdown List (if search is active with results)
                if !searchResults.isEmpty {
                    searchResultsListView
                }

                // Interactive Map View with Movable Pin
                interactiveMapView

                // Bottom Selected Location Card & Actions
                bottomLocationCard
            }
            .navigationTitle("Transaction Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveAndDismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasDroppedPin)
                }
            }
            .onAppear(perform: initializeLocation)
        }
    }

    // MARK: - Subviews

    private var searchHeaderView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search place, store, cafe, mall...", text: $searchQuery)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit {
                        performSearch()
                    }

                if isSearching {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if !searchQuery.isEmpty && searchResults.isEmpty {
                    Button("Search") {
                        performSearch()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(Theme.surface)
    }

    private var searchResultsListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(searchResults, id: \.self) { result in
                    Button {
                        selectSearchResult(result)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Theme.brand)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                if let addr = result.address, !addr.isEmpty {
                                    Text(addr)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.surface)
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 44)
                }
            }
        }
        .frame(maxHeight: 220)
        .background(Theme.surface)
        .shadow(color: Color.black.opacity(0.08), radius: 6, y: 4)
    }

    private var interactiveMapView: some View {
        ZStack {
            // Interactive Map Reader supporting user taps anywhere to drop/move the pin
            MapReader { reader in
                Map(position: $cameraPosition) {
                    if hasDroppedPin {
                        Marker(placeName.isEmpty ? "Selected Location" : placeName, coordinate: pinCoordinate)
                            .tint(Theme.brand)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { screenPoint in
                    // Manually drop/move pin where user taps on the interactive map
                    if let tappedCoord = reader.convert(screenPoint, from: .local) {
                        movePin(to: tappedCoord)
                    }
                }
            }

            // Floating helper pill for instructions
            VStack {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill")
                        .font(.caption2)
                    Text("Tap anywhere on the map to drop or move the pin")
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
                .padding(.top, 12)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomLocationCard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.brand.gradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "mappin")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Location Name", text: $placeName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        if isReverseGeocoding {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    if !placeAddress.isEmpty {
                        Text(placeAddress)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Text(String(format: "Lat: %.5f", pinCoordinate.latitude))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.secondaryInk)
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "Lon: %.5f", pinCoordinate.longitude))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Save Confirmation Button
            Button {
                saveAndDismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Set Location")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Actions & Location Logic

    private func initializeLocation() {
        if let lat = initialLatitude, let lon = initialLongitude,
           (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon),
           (abs(lat) > 0.0001 || abs(lon) > 0.0001) {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            pinCoordinate = coord
            hasDroppedPin = true
            placeName = initialName
            cameraPosition = .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            ))
            scheduleReverseGeocode(for: coord, preserveExistingName: !initialName.isEmpty)
        } else if !initialName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeName = initialName
            searchQuery = initialName
            hasDroppedPin = true
            performSearch()
        } else {
            hasDroppedPin = true
            cameraPosition = .region(MKCoordinateRegion(
                center: pinCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
            scheduleReverseGeocode(for: pinCoordinate, preserveExistingName: false)
        }
    }

    private func performSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        isSearching = true
        Task {
            let results = await LocationService.shared.searchPlaces(query: q)
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
                // Auto-center map to the first result if available
                if let first = results.first, let lat = first.latitude, let lon = first.longitude {
                    selectSearchResult(first)
                }
            }
        }
    }

    private func selectSearchResult(_ result: TransactionLocationData) {
        if let lat = result.latitude, let lon = result.longitude {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            pinCoordinate = coord
            hasDroppedPin = true
            placeName = result.name
            placeAddress = result.address ?? ""
            searchResults = [] // Close dropdown
            withAnimation(.easeInOut(duration: 0.35)) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                ))
            }
        }
    }

    private func movePin(to newCoordinate: CLLocationCoordinate2D) {
        pinCoordinate = newCoordinate
        hasDroppedPin = true
        scheduleReverseGeocode(for: newCoordinate, preserveExistingName: false)
    }

    private func scheduleReverseGeocode(for coord: CLLocationCoordinate2D, preserveExistingName: Bool) {
        reverseGeocodeTask?.cancel()
        isReverseGeocoding = true

        reverseGeocodeTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            let clLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let data = await LocationService.shared.reverseGeocode(location: clLoc, fallbackPlaceName: nil, maxWaitSeconds: 1.0)

            await MainActor.run {
                self.isReverseGeocoding = false
                if !preserveExistingName || self.placeName.isEmpty {
                    self.placeName = data.name
                }
                if let addr = data.address, !addr.isEmpty {
                    self.placeAddress = addr
                }
            }
        }
    }

    private func saveAndDismiss() {
        let cleanName = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "Selected Location" : cleanName
        let finalAddress = placeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : placeAddress

        onSelect(TransactionLocationData(
            name: finalName,
            address: finalAddress,
            latitude: pinCoordinate.latitude,
            longitude: pinCoordinate.longitude
        ))
        dismiss()
    }
}
