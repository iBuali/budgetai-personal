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

    func captureCurrentLocation(fallbackPlaceName: String? = nil) async -> TransactionLocationData? {
        isFetching = true
        lastError = nil
        defer { isFetching = false }

        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let currentStatus = manager.authorizationStatus
        guard currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways else {
            lastError = "Location access is not enabled in Settings."
            return nil
        }

        let loc: CLLocation? = await withCheckedContinuation { cont in
            self.continuation?.resume(returning: nil)
            self.continuation = cont
            self.manager.requestLocation()
        }

        guard let loc else {
            lastError = "Unable to determine current location."
            return nil
        }

        let geocoder = CLGeocoder()
        var placeName = fallbackPlaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var addressParts: [String] = []

        if let placemarks = try? await geocoder.reverseGeocodeLocation(loc), let pm = placemarks.first {
            if placeName.isEmpty {
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
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude
        )
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
            self.continuation?.resume(returning: loc)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(returning: nil)
            self.continuation = nil
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

                if onCaptureCurrent != nil || onSearchPlace != nil || onRemove != nil {
                    Menu {
                        if let onSearchPlace {
                            Button {
                                onSearchPlace()
                            } label: {
                                Label("Change / Search Place", systemImage: "magnifyingglass")
                            }
                        }
                        if let onCaptureCurrent {
                            Button {
                                onCaptureCurrent()
                            } label: {
                                Label("Use Current GPS Location", systemImage: "location.fill")
                            }
                        }
                        Button {
                            openInAppleMaps()
                        } label: {
                            Label("Open in Apple Maps", systemImage: "map")
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

// MARK: - Location Picker Sheet

struct LocationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialName: String
    let onSelect: (TransactionLocationData) -> Void

    @State private var searchQuery: String = ""
    @State private var customPlaceName: String = ""
    @State private var customAddress: String = ""
    @State private var results: [TransactionLocationData] = []
    @State private var isSearching = false
    @State private var isCapturingGPS = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            isCapturingGPS = true
                            if let loc = await LocationService.shared.captureCurrentLocation(fallbackPlaceName: initialName.isEmpty ? nil : initialName) {
                                onSelect(loc)
                                dismiss()
                            }
                            isCapturingGPS = false
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "location.fill")
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use Current Location")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text("Capture GPS coordinates and place name now")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                            Spacer()
                            if isCapturingGPS {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isCapturingGPS)
                }

                Section("Search Place on Map") {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search store, restaurant, mall...", text: $searchQuery)
                            .submitLabel(.search)
                            .onSubmit {
                                runSearch()
                            }
                        if isSearching {
                            ProgressView()
                        } else if !searchQuery.isEmpty {
                            Button("Search") {
                                runSearch()
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }

                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        Button {
                            onSelect(item)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Theme.brand)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    if let addr = item.address {
                                        Text(addr)
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryInk)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Section("Or Enter Place Name") {
                    TextField("Place of purchase (e.g. City Centre Bahrain)", text: $customPlaceName)
                    TextField("Area / Address (optional)", text: $customAddress)
                    Button("Save Place Name") {
                        let cleanName = customPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanName.isEmpty else { return }
                        if let inferred = LocationService.inferLocation(from: "\(cleanName) \(customAddress)", merchant: cleanName) {
                            onSelect(TransactionLocationData(
                                name: cleanName,
                                address: customAddress.isEmpty ? inferred.address : customAddress,
                                latitude: inferred.latitude,
                                longitude: inferred.longitude
                            ))
                        } else {
                            onSelect(TransactionLocationData(
                                name: cleanName,
                                address: customAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                                latitude: 26.2235,
                                longitude: 50.5876
                            ))
                        }
                        dismiss()
                    }
                    .disabled(customPlaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .font(.subheadline.weight(.semibold))
                }
            }
            .navigationTitle("Transaction Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if !initialName.isEmpty {
                    customPlaceName = initialName
                    searchQuery = initialName
                    runSearch()
                }
            }
        }
    }

    private func runSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task {
            isSearching = true
            results = await LocationService.shared.searchPlaces(query: q)
            isSearching = false
        }
    }
}
