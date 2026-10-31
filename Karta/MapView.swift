import SwiftUI
import MapLibre
import RouteBuilderCore

/// SwiftUI wrapper around MapLibre's `MLNMapView`.
///
/// The map owns its own gesture handling and tile loading, so this stays a
/// thin bridge: SwiftUI state in, taps and drags out. Anything that needs to
/// think goes through `AppModel`.
struct MapView: UIViewRepresentable {
    /// Declared as stored properties rather than read off the model inside
    /// `updateUIView`. A representable with no stored state looks unchanged to
    /// SwiftUI, so `updateUIView` is never called again and the map silently
    /// stops tracking the route — the stats keep updating, the line does not.
    let route: RouteState
    let basemap: Basemap
    let hillshade: Bool
    let terrainOverlay: TerrainOverlay?
    /// The spot being scrubbed on the elevation profile, or nil.
    let cursor: Coordinate?
    /// A discovered candidate drawn faintly before it is committed.
    let preview: [Coordinate]?
    /// Coordinates to frame once, after a Discover search. Cleared by the
    /// coordinator so a later redraw does not yank the camera back.
    let fit: [Coordinate]?
    /// Handed a closure that reads the map's current centre, so Discover can
    /// fall back to it when there is no location fix.
    @Binding var centerProvider: () -> Coordinate

    /// Still needed for the callbacks, which write back rather than read.
    @Environment(AppModel.self) private var model

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(
            frame: .zero,
            styleURL: MapStyle.url(for: basemap, includeDEM: hillshade)
        )
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        mapView.attributionButtonPosition = .bottomLeft
        // Terrain is worth leaning into; the stock limit flattens ridgelines.
        mapView.maximumPitch = 80
        mapView.setCenter(
            CLLocationCoordinate2D(latitude: 39.995, longitude: -105.28),  // Chautauqua-ish
            zoomLevel: 12,
            animated: false
        )

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // Let MapLibre's own double-tap-to-zoom win before we treat it as a tap.
        for recognizer in mapView.gestureRecognizers ?? [] {
            if let double = recognizer as? UITapGestureRecognizer,
               double.numberOfTapsRequired == 2 {
                tap.require(toFail: double)
            }
        }
        mapView.addGestureRecognizer(tap)

        context.coordinator.model = model
        context.coordinator.mapView = mapView
        context.coordinator.route = route
        context.coordinator.terrainOverlay = terrainOverlay
        context.coordinator.cursor = cursor
        context.coordinator.preview = preview
        context.coordinator.styleDescriptor = StyleDescriptor(basemap: basemap, hillshade: hillshade)

        // Built here so the only reference it keeps to the map is weak. Doing
        // it inside the async block below would also capture `mapView`
        // strongly in the outer closure, which outlives the view.
        let readCenter: () -> Coordinate = { [weak mapView] in
            let center = mapView?.centerCoordinate
                ?? CLLocationCoordinate2D(latitude: 39.995, longitude: -105.28)
            return Coordinate(longitude: center.longitude, latitude: center.latitude)
        }
        // Published on the next runloop turn: handing a @Binding a new value
        // from inside makeUIView is a state write during view construction.
        DispatchQueue.main.async { centerProvider = readCenter }
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.model = model

        // Hand over the route first. SwiftUI coalesces changes, so a single
        // update can carry both a new route and a new basemap — and the style
        // swap below returns early, leaving didFinishLoading to redraw from
        // whatever the coordinator holds.
        context.coordinator.route = route
        context.coordinator.terrainOverlay = terrainOverlay
        context.coordinator.cursor = cursor
        context.coordinator.preview = preview

        // Compare what the style was built from, not the file URL: the URL is
        // stable across basemap switches because the filename encodes the
        // choice, and re-setting it would drop every layer we added.
        let descriptor = StyleDescriptor(basemap: basemap, hillshade: hillshade)
        if context.coordinator.styleDescriptor != descriptor {
            context.coordinator.styleDescriptor = descriptor
            context.coordinator.overlayController.styleWasReplaced()
            mapView.styleURL = MapStyle.url(for: basemap, includeDEM: hillshade)
            return  // layers, route and overlay are restored in didFinishLoading
        }

        context.coordinator.syncRoute(on: mapView)
        context.coordinator.syncCursor(on: mapView)
        context.coordinator.syncPreview(on: mapView)
        context.coordinator.overlayController.update(
            mapView: mapView, overlay: terrainOverlay)
        context.coordinator.frameIfNeeded(fit, on: mapView, model: model)
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var model: AppModel?
        weak var mapView: MLNMapView?
        /// The route the map should be showing. Held here so `didFinishLoading`
        /// can redraw after a style swap without reaching back into SwiftUI.
        var route = RouteState()
        var terrainOverlay: TerrainOverlay?
        var cursor: Coordinate?
        var preview: [Coordinate]?
        var styleDescriptor = StyleDescriptor(basemap: .openTopo, hillshade: false)
        let overlayController = SlopeOverlayController()

        static let hillshadeLayerID = "karta-hillshade"
        private static let routeSourceID = "karta-route"
        private static let routeLayerID = "karta-route-line"
        private static let routeCasingLayerID = "karta-route-casing"
        private static let cursorSourceID = "karta-cursor"
        private static let cursorLayerID = "karta-cursor-dot"
        private static let previewSourceID = "karta-preview"
        private static let previewLayerID = "karta-preview-line"

        // ---------- taps ----------

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView, let model else { return }
            let point = gesture.location(in: mapView)
            let location = mapView.convert(point, toCoordinateFrom: mapView)
            let coordinate = Coordinate(
                longitude: location.longitude,
                latitude: location.latitude
            )
            Task { await model.addWaypoint(coordinate) }
        }

        // ---------- style lifecycle ----------

        /// Switching basemaps replaces the whole style, which drops every
        /// source and layer we added. They get rebuilt here rather than
        /// tracked, because the style is the source of truth.
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            installHillshade(on: style)
            installRouteLayers(on: style)
            installPreviewLayer(on: style)
            installCursorLayer(on: style)
            syncRoute(on: mapView)
            syncCursor(on: mapView)
            syncPreview(on: mapView)
            overlayController.styleWasReplaced()
            overlayController.update(mapView: mapView, overlay: terrainOverlay)
        }

        /// The overlay covers whatever is on screen, so it is rebuilt once the
        /// map settles. Re-rendering mid-gesture would fetch tiles for views
        /// the user is already panning past.
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            overlayController.update(mapView: mapView, overlay: terrainOverlay)
        }

        /// Shaded relief from the Terrarium DEM already declared in the style.
        ///
        /// This is the honest substitute for the web app's 3D terrain, which
        /// MapLibre Native cannot do: no tilt, but the relief reads.
        private func installHillshade(on style: MLNStyle) {
            guard style.layer(withIdentifier: Self.hillshadeLayerID) == nil,
                  let dem = style.source(withIdentifier: "dem")
            else { return }

            let layer = MLNHillshadeStyleLayer(
                identifier: Self.hillshadeLayerID, source: dem)

            // Igor's method is the one that "tries to minimise effects on
            // other map features beneath" — which is the whole problem over a
            // topo sheet full of contour lines and labels.
            layer.hillshadeMethod = NSExpression(forConstantValue: "igor")
            layer.hillshadeExaggeration =
                NSExpression(forConstantValue: MapStyle.hillshadeExaggeration)
            // An array, not a scalar: the multidirectional method takes
            // several light sources, so the property is typed for a list even
            // when there is only one. Passing a bare number crashes inside
            // MapLibre with "-[__NSCFNumber count]".
            layer.hillshadeIlluminationDirection =
                NSExpression(forConstantValue: [MapStyle.hillshadeIlluminationDirection])
            layer.hillshadeIlluminationAnchor =
                NSExpression(forConstantValue: "map")
            // Shadow and highlight are arrays — one entry per light source,
            // for the multidirectional method — while accent stays a single
            // colour. The split is inconsistent and only the headers say so.
            //
            // A cool slate rather than black: neutral shadow greys out the
            // basemap's own colours, which on a topo are carrying meaning.
            layer.hillshadeShadowColor = NSExpression(
                forConstantValue: [UIColor(red: 0.16, green: 0.19, blue: 0.24, alpha: 1)])
            layer.hillshadeHighlightColor = NSExpression(
                forConstantValue: [UIColor.white.withAlphaComponent(0.10)])
            layer.hillshadeAccentColor = NSExpression(
                forConstantValue: UIColor.clear)

            // Directly above the basemap, so the slope overlay and the route
            // both still sit on top of it.
            if let base = style.layer(withIdentifier: "base") {
                style.insertLayer(layer, above: base)
            } else {
                style.addLayer(layer)
            }
        }

        private func installRouteLayers(on style: MLNStyle) {
            guard style.source(withIdentifier: Self.routeSourceID) == nil else { return }

            let source = MLNShapeSource(identifier: Self.routeSourceID, shape: nil, options: nil)
            style.addSource(source)

            // A dark casing under a bright line, so the route stays legible
            // over both the tan of a topo map and the white of a snowfield.
            let casing = MLNLineStyleLayer(identifier: Self.routeCasingLayerID, source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.45))
            casing.lineWidth = NSExpression(forConstantValue: 8)
            casing.lineCap = NSExpression(forConstantValue: "round")
            casing.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(casing)

            let line = MLNLineStyleLayer(identifier: Self.routeLayerID, source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor(red: 0.98, green: 0.45,
                                                                    blue: 0.18, alpha: 1))
            line.lineWidth = NSExpression(forConstantValue: 4)
            line.lineCap = NSExpression(forConstantValue: "round")
            line.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(line)
        }

        /// A discovered candidate, shown before the user commits to it.
        ///
        /// Dashed and cool-toned so it never reads as the real route, which
        /// is solid orange over a dark casing. Installed below the route
        /// layers so an existing route still wins the overlap.
        private func installPreviewLayer(on style: MLNStyle) {
            guard style.source(withIdentifier: Self.previewSourceID) == nil else { return }

            let source = MLNShapeSource(identifier: Self.previewSourceID, shape: nil, options: nil)
            style.addSource(source)

            let line = MLNLineStyleLayer(identifier: Self.previewLayerID, source: source)
            line.lineColor = NSExpression(
                forConstantValue: UIColor(red: 0.16, green: 0.42, blue: 0.68, alpha: 0.9))
            line.lineWidth = NSExpression(forConstantValue: 3)
            line.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
            line.lineCap = NSExpression(forConstantValue: "round")
            style.addLayer(line)
        }

        func syncPreview(on mapView: MLNMapView) {
            guard let style = mapView.style,
                  let source = style.source(withIdentifier: Self.previewSourceID)
                    as? MLNShapeSource
            else { return }

            guard let preview, preview.count >= 2 else { return source.shape = nil }
            source.shape = MLNPolylineFeature(
                coordinates: preview.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                },
                count: UInt(preview.count))
        }

        /// Frames a set of coordinates once, then clears the request.
        ///
        /// Consuming it here rather than leaving it set is what stops the
        /// camera being yanked back to the search results every time an
        /// unrelated redraw happens.
        func frameIfNeeded(_ coordinates: [Coordinate]?, on mapView: MLNMapView, model: AppModel?) {
            guard let coordinates, coordinates.count >= 2 else { return }
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(
                    latitude: coordinates.map(\.latitude).min() ?? 0,
                    longitude: coordinates.map(\.longitude).min() ?? 0),
                ne: CLLocationCoordinate2D(
                    latitude: coordinates.map(\.latitude).max() ?? 0,
                    longitude: coordinates.map(\.longitude).max() ?? 0))
            mapView.setVisibleCoordinateBounds(
                bounds,
                edgePadding: UIEdgeInsets(top: 70, left: 50, bottom: 70, right: 50),
                animated: true,
                completionHandler: nil)
            model?.pendingFit = nil
        }

        /// The scrub marker, drawn as a style layer rather than an annotation.
        ///
        /// A drag moves this on every frame. Annotations go through view
        /// recycling and callout bookkeeping for each change; a point in a
        /// shape source is just a new geometry.
        private func installCursorLayer(on style: MLNStyle) {
            guard style.source(withIdentifier: Self.cursorSourceID) == nil else { return }

            let source = MLNShapeSource(identifier: Self.cursorSourceID, shape: nil, options: nil)
            style.addSource(source)

            let dot = MLNCircleStyleLayer(identifier: Self.cursorLayerID, source: source)
            dot.circleRadius = NSExpression(forConstantValue: 6)
            dot.circleColor = NSExpression(forConstantValue: UIColor.white)
            dot.circleStrokeWidth = NSExpression(forConstantValue: 3)
            dot.circleStrokeColor = NSExpression(
                forConstantValue: UIColor(red: 0.98, green: 0.45, blue: 0.18, alpha: 1))
            // On top of the route line, which it is meant to sit on.
            style.addLayer(dot)
        }

        func syncCursor(on mapView: MLNMapView) {
            guard let style = mapView.style,
                  let source = style.source(withIdentifier: Self.cursorSourceID)
                    as? MLNShapeSource
            else { return }

            source.shape = cursor.map {
                // MLNPointFeature inherits its coordinate as a settable
                // property; there is no initialiser that takes one.
                let feature = MLNPointFeature()
                feature.coordinate = CLLocationCoordinate2D(
                    latitude: $0.latitude, longitude: $0.longitude)
                return feature
            }
        }

        // ---------- route rendering ----------

        func syncRoute(on mapView: MLNMapView) {
            guard let style = mapView.style,
                  let source = style.source(withIdentifier: Self.routeSourceID)
                    as? MLNShapeSource
            else { return }

            let track = route.track
            source.shape = track.count >= 2
                ? MLNPolylineFeature(coordinates: track.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                  }, count: UInt(track.count))
                : nil

            syncWaypoints(on: mapView, waypoints: route.waypoints)
        }

        private func syncWaypoints(on mapView: MLNMapView, waypoints: [Coordinate]) {
            let existing = mapView.annotations?.compactMap { $0 as? WaypointAnnotation } ?? []

            // Rebuild only when the count changed; otherwise move in place so
            // a drag does not flicker the whole set.
            if existing.count == waypoints.count {
                for (annotation, waypoint) in zip(existing.sorted(by: { $0.index < $1.index }),
                                                  waypoints) {
                    annotation.coordinate = CLLocationCoordinate2D(
                        latitude: waypoint.latitude, longitude: waypoint.longitude)
                }
                return
            }

            if !existing.isEmpty { mapView.removeAnnotations(existing) }
            guard !waypoints.isEmpty else { return }

            let fresh = waypoints.enumerated().map { index, waypoint in
                let annotation = WaypointAnnotation()
                annotation.index = index
                annotation.coordinate = CLLocationCoordinate2D(
                    latitude: waypoint.latitude, longitude: waypoint.longitude)
                annotation.title = index == 0
                    ? "Start"
                    : (index == waypoints.count - 1 ? "End" : "Waypoint \(index + 1)")
                return annotation
            }
            mapView.addAnnotations(fresh)
        }

        // ---------- annotation views ----------

        func mapView(
            _ mapView: MLNMapView,
            viewFor annotation: MLNAnnotation
        ) -> MLNAnnotationView? {
            guard let waypoint = annotation as? WaypointAnnotation else { return nil }

            let reuseID = "karta-waypoint"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                as? WaypointView ?? WaypointView(reuseIdentifier: reuseID)
            view.apply(isFirst: waypoint.index == 0)
            view.onDragEnd = { [weak self] coordinate in
                guard let model = self?.model else { return }
                Task {
                    await model.moveWaypoint(
                        at: waypoint.index,
                        to: Coordinate(longitude: coordinate.longitude,
                                       latitude: coordinate.latitude)
                    )
                }
            }
            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            true
        }
    }
}

/// A waypoint, carrying its index so a drag knows which one moved.
///
/// `nonisolated` because the module defaults to main-actor isolation but
/// MapLibre's annotation initialisers are not isolated, and an override
/// cannot be more isolated than what it overrides.
nonisolated final class WaypointAnnotation: MLNPointAnnotation {
    var index: Int = 0
}

/// Draggable marker. MapLibre handles the drag gesture itself once
/// `isDraggable` is set; the callback reports where it landed.
final class WaypointView: MLNAnnotationView {
    var onDragEnd: ((CLLocationCoordinate2D) -> Void)?

    init(reuseIdentifier: String) {
        super.init(reuseIdentifier: reuseIdentifier)
        isDraggable = true
        frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        layer.cornerRadius = 9
        layer.borderWidth = 2.5
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(isFirst: Bool) {
        backgroundColor = isFirst
            ? UIColor(red: 0.36, green: 0.78, blue: 0.47, alpha: 1)
            : UIColor(red: 0.98, green: 0.45, blue: 0.18, alpha: 1)
    }

    override func setDragState(
        _ dragState: MLNAnnotationViewDragState,
        animated: Bool
    ) {
        super.setDragState(dragState, animated: animated)
        switch dragState {
        case .starting:
            UIView.animate(withDuration: 0.15) { self.transform = .init(scaleX: 1.4, y: 1.4) }
        case .ending, .canceling:
            UIView.animate(withDuration: 0.15) { self.transform = .identity }
            if dragState == .ending, let annotation {
                onDragEnd?(annotation.coordinate)
            }
        default:
            break
        }
    }
}
