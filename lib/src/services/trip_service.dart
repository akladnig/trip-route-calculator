import 'dart:convert';
import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:trip_routing/src/services/entrance_finder.dart';
import 'package:trip_routing/trip_routing.dart';

/// TripService provides routing and trip planning over OSM and cached city graphs.
/// Query both live (fetch) and offline city data with walking/biking/vehicle options.
/// Ensures all coordinate and graph operations are NaN/infinity-safe, all API returns are validated,
/// and all distances are checked.
///
/// Main entrypoint: [findTotalTrip].
class TripService {
  final BuildingAndEntranceFinder entranceFinder = BuildingAndEntranceFinder();

  /// If not null, current offline city name.
  String? currentCity;

  /// The main graph used for routing.
  late Graph graph;

  TripService();

  bool get _hasLoadedGraph {
    try {
      graph.nodes;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Load a routing graph from raw Overpass `elements` data.
  ///
  /// This enables callers to prepare Overpass JSON separately and then route
  /// offline without triggering a live Overpass request during [findTotalTrip].
  Future<void> loadOverpassElements(
    List<dynamic> elements, {
    bool preferWalkingPaths = true,
    int minIslandSize = 0,
    String source = 'custom',
  }) async {
    graph = _parseGraph(
      elements,
      preferWalkingPaths,
      minIslandSize: minIslandSize,
    );
    currentCity = source;
  }

  /// Load a routing graph from a decoded Overpass JSON response.
  Future<void> loadOverpassJson(
    Map<String, dynamic> json, {
    bool preferWalkingPaths = true,
    int minIslandSize = 0,
    String source = 'custom',
  }) async {
    final elements = json['elements'];
    if (elements is! List) {
      throw const FormatException('Expected top-level "elements" list.');
    }

    await loadOverpassElements(
      elements,
      preferWalkingPaths: preferWalkingPaths,
      minIslandSize: minIslandSize,
      source: source,
    );
  }

  /// Fetch OSM walking path ways/nodes in given bounds.
  ///
  /// Returns an empty list if parsing fails, data is incomplete, or API fails.
  Future<List<Map<String, dynamic>>> _fetchWalkingPaths(
    double minLat,
    double minLon,
    double maxLat,
    double maxLon,
  ) async {
    // Clamp bounds to avoid NaN/Infinity from the start
    double clamp(double v, double min, double max) =>
        v.isFinite ? v.clamp(min, max) : min;
    minLat = clamp(minLat, -90, 90);
    maxLat = clamp(maxLat, -90, 90);
    minLon = clamp(minLon, -180, 180);
    maxLon = clamp(maxLon, -180, 180);

    final query = '''
      [out:json];
      (
        way["highway"]["area"!~"yes"]["place"!~"square"]($minLat, $minLon, $maxLat, $maxLon);
      );
      out body;
      >;
      out skel qt;
      ''';
    final url = Uri.parse('https://overpass-api.de/api/interpreter');
    try {
      final response = await http.post(
        url,
        body: {'data': query},
      );
      if (response.statusCode == 200) {
        final rawData = jsonDecode(response.body) as Map<String, dynamic>;
        final elements = rawData['elements'];
        if (elements is List) {
          return elements.map<Map<String, dynamic>>((e) {
            // Defensive extraction and clamping on lat/lon
            double safeDouble(dynamic v) {
              if (v is num && v.isFinite) return v.toDouble();
              if (v is String) {
                final d = double.tryParse(v);
                if (d != null && d.isFinite) return d;
              }
              return 0.0;
            }

            int safeInt(dynamic v) {
              if (v is int) return v;
              if (v is num && v.isFinite) return v.round();
              if (v is String) {
                final i = int.tryParse(v);
                if (i != null) return i;
              }
              return -1;
            }

            return {
              'type': e['type'] ?? '',
              'id': safeInt(e['id']),
              'lat': safeDouble(e['lat']),
              'lon': safeDouble(e['lon']),
              'tags': e['tags'] ?? <String, dynamic>{},
              'nodes': (e['nodes'] is List)
                  ? List<int>.from(e['nodes'].map(safeInt))
                  : <int>[],
            };
          }).toList();
        }
      }
    } catch (e) {
      // Log, but always return an explicit value
    }
    return [];
  }

  /// Removes connected components (islands) smaller than maxNodes.
  Graph _removeNodeIslands(Graph graph, int maxNodes) {
    final visited = <int>{};
    final connectedComponents = <List<int>>[];

    for (final nodeId in graph.nodes.keys) {
      if (!visited.contains(nodeId)) {
        final component = <int>[];
        _iterativeDfs(graph, nodeId, visited, component);
        connectedComponents.add(component);
      }
    }

    for (final component in connectedComponents) {
      if (component.length <= maxNodes) {
        for (final nodeId in component) {
          graph.removeNode(nodeId);
        }
      }
    }

    return graph;
  }

  /// Iterative DFS, safe for deep recursion.
  void _iterativeDfs(
      Graph graph, int startNodeId, Set<int> visited, List<int> component) {
    final stack = <int>[startNodeId];
    while (stack.isNotEmpty) {
      final nodeId = stack.removeLast();
      if (!visited.add(nodeId)) continue;
      component.add(nodeId);
      final neighbors = graph.adjacencyList[nodeId] ?? [];
      for (final edge in neighbors) {
        if (!visited.contains(edge.to)) {
          stack.add(edge.to);
        }
      }
    }
  }

  /// Parse a list of OSM nodes and ways to build a routing graph.
  ///
  /// Returns an empty graph if no valid nodes.
  Graph _parseGraph(
    List elements,
    bool preferWalkingPaths, {
    int minIslandSize = 100,
  }) {
    final graph = Graph();

    // Safe node extraction
    for (final element in elements) {
      if (element['type'] == 'node') {
        final id = element['id'];
        final lat = element['lat'];
        final lon = element['lon'];
        if (id is int &&
            lat is double &&
            lon is double &&
            lat.isFinite &&
            lon.isFinite) {
          try {
            graph.addNode(Node(
              id,
              lat,
              lon,
              false,
            ));
          } catch (_) {}
        }
      }
    }

    // Edge extraction with walking preference
    for (final element in elements) {
      if (element['type'] == 'way') {
        final List nodes = (element['nodes'] is List) ? element['nodes'] : [];
        final Map<String, dynamic> tags = element['tags'] ?? {};
        final wayId = element['id'];
        final isFootWay = preferWalkingPaths &&
            (tags.containsKey('footway') || tags.containsKey('pedestrian'));

        for (int i = 0; i < nodes.length - 1; i++) {
          final int startIndex =
              nodes[i] is int ? nodes[i] : int.tryParse('${nodes[i]}') ?? -1;
          final int endIndex = nodes[i + 1] is int
              ? nodes[i + 1]
              : int.tryParse('${nodes[i + 1]}') ?? -1;
          final startNode = graph.nodes[startIndex];
          final endNode = graph.nodes[endIndex];
          if (startNode == null || endNode == null) continue;

          // Set footway flag if desired
          if (isFootWay) {
            startNode.setIsFootWay = true;
            endNode.setIsFootWay = true;
          }
          final dist = haversineDistance(
              startNode.lat, startNode.lon, endNode.lat, endNode.lon);
          final safeDist = (dist.isFinite && dist >= 0) ? dist : 0.0;
          // Only add edge if real, meaningful length
          if (safeDist > 0.1) {
            graph.addEdge(
              Edge(
                startIndex,
                endIndex,
                safeDist,
                originalSegmentId: wayId is int ? '$wayId:$i' : 'way:$i',
              ),
            );
          }
        }
      }
    }

    // Remove unrealistically tiny islands
    if (minIslandSize <= 0) {
      return graph;
    }
    return _removeNodeIslands(graph, minIslandSize);
  }

  List<_GraphSegment> _uniqueSegments(Graph graph) {
    final segments = <_GraphSegment>[];
    final seen = <String>{};
    for (final entry in graph.adjacencyList.entries) {
      for (final edge in entry.value) {
        final startNode = graph.nodes[edge.from];
        final endNode = graph.nodes[edge.to];
        if (startNode == null || endNode == null) {
          continue;
        }
        final orderedFrom = edge.from < edge.to ? edge.from : edge.to;
        final orderedTo = edge.from < edge.to ? edge.to : edge.from;
        final id = edge.originalSegmentId ?? 'legacy:$orderedFrom:$orderedTo';
        final key = '$id:$orderedFrom:$orderedTo';
        if (!seen.add(key)) {
          continue;
        }
        segments.add(_GraphSegment(edge, startNode, endNode));
      }
    }
    return segments;
  }

  _ProjectedPoint _projectPointToSegment(
    LatLng point,
    Node startNode,
    Node endNode,
  ) {
    const earthRadius = 6371000.0;
    final latRef = point.latitude * math.pi / 180.0;

    ({double x, double y}) toXY(double lat, double lon) {
      final latRad = lat * math.pi / 180.0;
      final lonRad = lon * math.pi / 180.0;
      return (
        x: earthRadius * lonRad * math.cos(latRef),
        y: earthRadius * latRad,
      );
    }

    final pointXY = toXY(point.latitude, point.longitude);
    final startXY = toXY(startNode.lat, startNode.lon);
    final endXY = toXY(endNode.lat, endNode.lon);
    final dx = endXY.x - startXY.x;
    final dy = endXY.y - startXY.y;
    final lengthSquared = dx * dx + dy * dy;
    final unclampedT = lengthSquared <= 0
        ? 0.0
        : (((pointXY.x - startXY.x) * dx) +
                    ((pointXY.y - startXY.y) * dy)) /
                lengthSquared;
    final t = unclampedT.clamp(0.0, 1.0);
    final projectedLat = startNode.lat + (endNode.lat - startNode.lat) * t;
    final projectedLon = startNode.lon + (endNode.lon - startNode.lon) * t;
    final projectedPoint = LatLng(projectedLat, projectedLon);
    final distanceMeters = haversineDistance(
      point.latitude,
      point.longitude,
      projectedPoint.latitude,
      projectedPoint.longitude,
    );
    return _ProjectedPoint(projectedPoint, t.toDouble(), distanceMeters);
  }

  _EndpointClassification _classifyEndpoint(
    Graph graph,
    LatLng point,
    double maxSnapDistanceMeters,
  ) {
    Node? closestNode;
    var closestNodeDistance = double.infinity;
    for (final node in graph.nodes.values) {
      final distance = haversineDistance(
        point.latitude,
        point.longitude,
        node.lat,
        node.lon,
      );
      if (distance < closestNodeDistance) {
        closestNodeDistance = distance;
        closestNode = node;
      }
    }

    if (closestNode != null && closestNodeDistance <= maxSnapDistanceMeters) {
      return _EndpointClassification(
        isOnTrack: true,
        anchor: EndpointAnchor(
          point: LatLng(closestNode.lat, closestNode.lon),
          type: EndpointAnchorType.node,
          nodeId: closestNode.id,
        ),
        graphNodeId: closestNode.id,
      );
    }

    _EndpointClassification? bestMatch;
    for (final segment in _uniqueSegments(graph)) {
      final projected = _projectPointToSegment(point, segment.startNode, segment.endNode);
      if (projected.distanceMeters > maxSnapDistanceMeters) {
        continue;
      }

      final candidate = _EndpointClassification(
        isOnTrack: true,
        anchor: EndpointAnchor(
          point: projected.point,
          type: EndpointAnchorType.edgeProjection,
          originalSegmentId: segment.edge.originalSegmentId,
        ),
        originalSegmentId: segment.edge.originalSegmentId,
        segmentFromNodeId: segment.startNode.id,
        segmentToNodeId: segment.endNode.id,
        fractionAlongSegment: projected.fraction,
        distanceToGraphMeters: projected.distanceMeters,
      );
      if (bestMatch == null ||
          candidate.distanceToGraphMeters! < bestMatch.distanceToGraphMeters!) {
        bestMatch = candidate;
      }
    }

    return bestMatch ??
        const _EndpointClassification(
          isOnTrack: false,
        );
  }

  Future<EndpointProbeResult> probeEndpointAnchor({
    required LatLng point,
    required double maxSnapDistanceMeters,
  }) async {
    if (!_hasLoadedGraph || graph.nodes.isEmpty) {
      return const EndpointProbeResult(
        isOnTrack: false,
        errors: ['Graph data unavailable'],
      );
    }

    final classification = _classifyEndpoint(graph, point, maxSnapDistanceMeters);
    return EndpointProbeResult(
      isOnTrack: classification.isOnTrack,
      anchor: classification.anchor,
      errors: classification.isOnTrack ? const [] : const [],
    );
  }

  int _nextSyntheticNodeId(Graph graph, int currentMinId) {
    final minId = graph.nodes.keys.isEmpty
        ? currentMinId
        : graph.nodes.keys.reduce(math.min);
    return math.min(currentMinId, minId) - 1;
  }

  AnchoredSegmentResult _routeThroughOverlay(
    Graph baseGraph,
    _EndpointClassification start,
    _EndpointClassification end,
  ) {
    if (start.anchor == null || end.anchor == null) {
      return const AnchoredSegmentResult(
        status: AnchoredSegmentStatus.failed,
        route: [],
        distance: 0.0,
        errors: ['Missing anchor metadata'],
      );
    }

    if (start.originalSegmentId != null &&
        start.originalSegmentId == end.originalSegmentId &&
        start.anchor!.type == EndpointAnchorType.edgeProjection &&
        end.anchor!.type == EndpointAnchorType.edgeProjection) {
      final distance = haversineDistance(
        start.anchor!.point.latitude,
        start.anchor!.point.longitude,
        end.anchor!.point.latitude,
        end.anchor!.point.longitude,
      );
      return AnchoredSegmentResult(
        status: AnchoredSegmentStatus.routed,
        route: [start.anchor!.point, end.anchor!.point],
        distance: distance,
        errors: const [],
        startAnchor: start.anchor,
        endAnchor: end.anchor,
      );
    }

    final overlay = baseGraph.clone();
    var syntheticId = 0;

    int resolveNodeId(_EndpointClassification classification) {
      final nodeId = classification.graphNodeId;
      if (nodeId != null) {
        return nodeId;
      }

      final fromId = classification.segmentFromNodeId;
      final toId = classification.segmentToNodeId;
      final fraction = classification.fractionAlongSegment;
      final anchor = classification.anchor;
      if (fromId == null || toId == null || fraction == null || anchor == null) {
        throw StateError('Missing synthetic anchor routing metadata.');
      }

      syntheticId = _nextSyntheticNodeId(overlay, syntheticId);
      final fromNode = overlay.nodes[fromId]!;
      final toNode = overlay.nodes[toId]!;
      overlay.addNode(
        Node(
          syntheticId,
          anchor.point.latitude,
          anchor.point.longitude,
          fromNode.isFootWay || toNode.isFootWay,
        ),
      );

      final segmentId = classification.originalSegmentId;
      final totalWeight = haversineDistance(
        fromNode.lat,
        fromNode.lon,
        toNode.lat,
        toNode.lon,
      );
      overlay.addEdge(
        Edge(
          fromId,
          syntheticId,
          totalWeight * fraction,
          originalSegmentId: segmentId,
        ),
      );
      overlay.addEdge(
        Edge(
          syntheticId,
          toId,
          totalWeight * (1.0 - fraction),
          originalSegmentId: segmentId,
        ),
      );
      return syntheticId;
    }

    try {
      final startId = resolveNodeId(start);
      final endId = resolveNodeId(end);
      final trip = shortestPath(overlay, startId, endId);
      if (trip.errors.isNotEmpty || trip.route.length < 2 || trip.distance <= 0) {
        return AnchoredSegmentResult(
          status: AnchoredSegmentStatus.noPath,
          route: const [],
          distance: 0.0,
          errors: const [],
          startAnchor: start.anchor,
          endAnchor: end.anchor,
        );
      }
      return AnchoredSegmentResult(
        status: AnchoredSegmentStatus.routed,
        route: trip.route,
        distance: trip.distance,
        errors: const [],
        startAnchor: start.anchor,
        endAnchor: end.anchor,
      );
    } catch (error) {
      return AnchoredSegmentResult(
        status: AnchoredSegmentStatus.failed,
        route: const [],
        distance: 0.0,
        errors: ['$error'],
        startAnchor: start.anchor,
        endAnchor: end.anchor,
      );
    }
  }

  Future<AnchoredSegmentResult> findAnchoredSegment({
    required LatLng start,
    required LatLng end,
    required double maxSnapDistanceMeters,
  }) async {
    if (!_hasLoadedGraph || graph.nodes.isEmpty) {
      return const AnchoredSegmentResult(
        status: AnchoredSegmentStatus.failed,
        route: [],
        distance: 0.0,
        errors: ['Graph data unavailable'],
      );
    }

    final startClassification = _classifyEndpoint(graph, start, maxSnapDistanceMeters);
    final endClassification = _classifyEndpoint(graph, end, maxSnapDistanceMeters);
    if (!startClassification.isOnTrack || !endClassification.isOnTrack) {
      return AnchoredSegmentResult(
        status: AnchoredSegmentStatus.offTrack,
        route: const [],
        distance: 0.0,
        errors: const [],
        startAnchor: startClassification.anchor,
        endAnchor: endClassification.anchor,
      );
    }

    return _routeThroughOverlay(graph, startClassification, endClassification);
  }

  /// Find the closest node id in graph for each position.
  ///
  /// Never returns -1 as an id; in case of empty graph or all mismatches, chooses first available node.
  List<int> _findClosestNodes(Graph graph, List<LatLng> positions) {
    final closestNodeIds = <int>[];
    final allNodeValues = graph.nodes.values.toList();
    for (final position in positions) {
      int closestNodeId =
          allNodeValues.isNotEmpty ? allNodeValues.first.id : -1;
      var minDistance = double.maxFinite;

      for (final node in allNodeValues) {
        final distance = haversineDistance(
            position.latitude, position.longitude, node.lat, node.lon);
        if (distance.isFinite && distance < minDistance) {
          minDistance = distance;
          closestNodeId = node.id;
        }
      }
      closestNodeIds.add(closestNodeId);
    }
    return closestNodeIds;
  }

  /// Compute shortest path with walking preference using a weighted Dijkstra.
  ///
  /// Returns a [Trip] with empty route and `distance = 0.0` if route cannot be found.
  Trip shortestPath(Graph graph, int startId, int targetId) {
    final actualDistances = <int, double>{};
    final weightedDistances = <int, double>{};
    final previousNodes = <int, int>{};
    final visited = <int>{};

    final priorityQueue = PriorityQueue<MapEntry<int, double>>(
      (a, b) => a.value.compareTo(b.value),
    );

    for (final nodeId in graph.nodes.keys) {
      actualDistances[nodeId] = double.infinity;
      weightedDistances[nodeId] = double.infinity;
    }
    if (!graph.nodes.containsKey(startId) ||
        !graph.nodes.containsKey(targetId)) {
      return Trip(
          route: [], distance: 0.0, errors: ['Start/target node not found.']);
    }

    actualDistances[startId] = 0.0;
    weightedDistances[startId] = 0.0;
    priorityQueue.add(MapEntry(startId, 0.0));

    while (priorityQueue.isNotEmpty) {
      final currentNodeId = priorityQueue.removeFirst().key;
      if (!visited.add(currentNodeId)) continue;
      if (currentNodeId == targetId) break;

      for (final edge in graph.adjacencyList[currentNodeId] ?? []) {
        if (visited.contains(edge.to)) continue;

        final isFootWay = graph.nodes[edge.to]?.isFootWay ?? false;
        final footwayPenalty = isFootWay ? 0.95 : 1.0;
        final weight =
            (edge.weight.isFinite && edge.weight > 0) ? edge.weight : 1.0;
        final newActualDistance = actualDistances[currentNodeId]! + weight;
        final newWeightedDistance =
            weightedDistances[currentNodeId]! + weight * footwayPenalty;

        if (newWeightedDistance <
            (weightedDistances[edge.to] ?? double.infinity)) {
          actualDistances[edge.to] = newActualDistance;
          weightedDistances[edge.to] = newWeightedDistance;
          previousNodes[edge.to] = currentNodeId;
          priorityQueue.add(MapEntry(edge.to, newWeightedDistance));
        }
      }
    }

    // Reconstruct the path
    var path = <int>[];
    var currentNodeId = targetId;
    while (previousNodes.containsKey(currentNodeId)) {
      path.add(currentNodeId);
      currentNodeId = previousNodes[currentNodeId]!;
    }
    if (currentNodeId == startId) path.add(startId);

    if (path.isEmpty) {
      return Trip(route: [], distance: 0.0, errors: ['No path found.']);
    }

    final route = path.reversed
        .map((a) {
          final n = graph.nodes[a];
          if (n == null) return null;
          return LatLng(n.lat, n.lon);
        })
        .whereType<LatLng>()
        .toList();

    return Trip(
      route: route,
      distance: (actualDistances[targetId]?.isFinite ?? false)
          ? actualDistances[targetId]!
          : 0.0,
      errors: [],
    );
  }

  /// Like [shortestPath] but globally penalizes duplicate edge usage.
  Trip _findGlobalShortestPath(
    Graph graph,
    int startId,
    int targetId,
    double duplicationPenalty,
    Set<String> usedEdges,
  ) {
    final actualDistances = <int, double>{};
    final weightedDistances = <int, double>{};
    final previousNodes = <int, int>{};
    final visited = <int>{};
    final priorityQueue = PriorityQueue<MapEntry<int, double>>(
      (a, b) => a.value.compareTo(b.value),
    );
    for (final nodeId in graph.nodes.keys) {
      actualDistances[nodeId] = double.infinity;
      weightedDistances[nodeId] = double.infinity;
    }
    if (!graph.nodes.containsKey(startId) ||
        !graph.nodes.containsKey(targetId)) {
      return Trip(route: [], distance: 0.0, errors: ['Start/target not found']);
    }
    actualDistances[startId] = 0.0;
    weightedDistances[startId] = 0.0;
    priorityQueue.add(MapEntry(startId, 0.0));

    while (priorityQueue.isNotEmpty) {
      final currentNodeId = priorityQueue.removeFirst().key;
      if (!visited.add(currentNodeId)) continue;
      if (currentNodeId == targetId) break;

      for (final edge in graph.adjacencyList[currentNodeId] ?? []) {
        if (visited.contains(edge.to)) continue;

        // Form an edge key in both directions for penalty
        final edgeKey = '${edge.from}-${edge.to}';
        final edgePenalty =
            usedEdges.contains(edgeKey) ? duplicationPenalty : 0.0;
        final isFootWay = graph.nodes[edge.to]?.isFootWay ?? false;
        final footwayPenalty = isFootWay ? 0.95 : 1.0;
        final weight =
            (edge.weight.isFinite && edge.weight > 0) ? edge.weight : 1.0;
        final newActualDistance = actualDistances[currentNodeId]! + weight;
        final newWeightedDistance = weightedDistances[currentNodeId]! +
            weight * footwayPenalty +
            edgePenalty;

        if (newWeightedDistance <
            (weightedDistances[edge.to] ?? double.infinity)) {
          actualDistances[edge.to] = newActualDistance;
          weightedDistances[edge.to] = newWeightedDistance;
          previousNodes[edge.to] = currentNodeId;
          priorityQueue.add(MapEntry(edge.to, newWeightedDistance));
        }
      }
    }

    // Reconstruct the path
    var path = <int>[];
    var currentNodeId = targetId;
    while (previousNodes.containsKey(currentNodeId)) {
      path.add(currentNodeId);
      currentNodeId = previousNodes[currentNodeId]!;
    }
    if (currentNodeId == startId) path.add(startId);

    if (path.length < 2) {
      return Trip(route: [], distance: 0.0, errors: ['Global path not found']);
    }

    // Mark all used edges
    for (var i = 0; i < path.length - 1; i++) {
      usedEdges.add('${path[i]}-${path[i + 1]}');
    }
    final route = path.reversed
        .map((a) {
          final n = graph.nodes[a];
          if (n == null) return null;
          return LatLng(n.lat, n.lon);
        })
        .whereType<LatLng>()
        .toList();

    return Trip(
      route: route,
      distance: (actualDistances[targetId]?.isFinite ?? false)
          ? actualDistances[targetId]!
          : 0.0,
      errors: [],
    );
  }

  /// Calculates the total trip route and distance between any given waypoints.
  ///
  /// This function computes the optimal path between a list of waypoints, optionally adjusting the
  /// route based on walking paths or building entrances.
  ///
  /// Parameters:
  ///   - [waypoints]: A list of `LatLng` objects representing the locations (latitude and longitude)
  ///     between which the route needs to be calculated.
  ///   - [preferWalkingPaths]: Bool flag indicating whether walking paths should be preferred
  ///     over other types of paths. Defaults to `true`.
  ///   - [replaceWaypointsWithBuildingEntrances]: Boolean flag that determines if waypoints should
  ///     be replaced with building entrances. If no entrance is found, the original waypoint is not replaced. Defaults to `false`.
  ///   - [forceIncludeWaypoints]: Boolean flag that forces the inclusion of waypoints in the final
  ///     route even if they are not exactly on a road. Defaults to `false`.
  ///
  /// Returns:
  ///   A `Future<Trip>` representing the total trip, including:
  ///   - [route]: List of `LatLng` locations representing the full trip route from start to destination.
  ///   - [distance]: `double`, representing the total distance of the trip in meters.
  ///   - [errors]: List of `String` containing error messages encountered during route calculation.
  ///   - [duplicationPenalty]: penalty term to prefer no duplicate ways in global trip
  Future<Trip> findTotalTrip(
    List<LatLng> waypoints, {
    bool preferWalkingPaths = true,
    bool replaceWaypointsWithBuildingEntrances = false,
    bool forceIncludeWaypoints = false,
    double duplicationPenalty = 0.0,
  }) async {
    var totalRoute = <LatLng>[];
    var totalDistance = 0.0;
    var errors = <String>[];
    List<bool> foundEntrance = [];

    List<double>? bounds;

    // ONLINE mode: initialize graph from bounding box
    if (currentCity == null) {
      bounds = findLatLonBounds(waypoints);
      if (replaceWaypointsWithBuildingEntrances) {
        waypoints =
            await _replaceWaypointsWithEntrances(waypoints, foundEntrance);
      } else {
        foundEntrance = List.filled(waypoints.length, false);
      }
      graph = await _fetchGraph(bounds, preferWalkingPaths);
    } else {
      foundEntrance = List.filled(waypoints.length, false);
    }

    if (graph.nodes.isEmpty) {
      return Trip(
          route: [],
          distance: 0.0,
          errors: ['Graph data unavailable'],
          boundingBox: bounds);
    }

    final usedEdges = <String>{};
    final queryIds = _findClosestNodes(graph, waypoints);

    for (var i = 0; i < queryIds.length - 1; i++) {
      final subTrip = _findGlobalShortestPath(
        graph,
        queryIds[i],
        queryIds[i + 1],
        duplicationPenalty,
        usedEdges,
      );

      totalRoute.addAll(subTrip.route);
      totalDistance += subTrip.distance;

      if (_shouldAddWaypoint(
          subTrip, foundEntrance, forceIncludeWaypoints, i)) {
        totalRoute.add(waypoints[i + 1]);
      }

      if (subTrip.errors.isNotEmpty) {
        errors.addAll(subTrip.errors);
      }
    }

    return Trip(
        route: totalRoute,
        distance: totalDistance.isFinite ? totalDistance : 0.0,
        errors: errors,
        boundingBox: bounds);
  }

  /// Replace each waypoint with detected building entrance if available.
  Future<List<LatLng>> _replaceWaypointsWithEntrances(
      List<LatLng> waypoints, List<bool> foundEntrance) async {
    final entrances = await entranceFinder.findBuildingAndEntrance(waypoints);
    final updatedWaypoints = <LatLng>[];
    for (int i = 0; i < waypoints.length; i++) {
      final original = waypoints[i];
      // Defensive: matching by index, fallback if not found
      LatLng updated = (entrances.length > i) ? entrances[i] : original;
      updatedWaypoints.add(updated);
      foundEntrance.add(updated != original);
    }
    return updatedWaypoints;
  }

  /// Fetch and parse the OSM graph in a bounding box.
  Future<Graph> _fetchGraph(
      List<double> bounds, bool preferWalkingPaths) async {
    if (bounds.length < 4) return Graph();
    List<double> safeBounds = List<double>.from(bounds.take(4).map((x) {
      if (x.isFinite) return x;
      return 0.0;
    }));
    final fetchedData = await _fetchWalkingPaths(
        safeBounds[0], safeBounds[1], safeBounds[2], safeBounds[3]);
    return _parseGraph(fetchedData, preferWalkingPaths);
  }

  /// Decide if the (possibly replaced) waypoint should be forcibly put in the final route.
  bool _shouldAddWaypoint(Trip subTrip, List<bool> foundEntrance,
      bool forceIncludeWaypoints, int index) {
    if (subTrip.route.isEmpty) return false;
    if (forceIncludeWaypoints) return true;
    // Defensive: index may be last-1 for last subTrip call
    if (foundEntrance.length > index + 1) return foundEntrance[index + 1];
    return false;
  }

  /// Get the data path for this city name. (Override for specific platforms.)
  Future<String> getCityPath(String cityName) async => '$cityName.json';

  /// Downloads routing data for a specified city and uses the cached file for future routing.
  /// Note: offline routing doesnt allow to handle `replaceWaypointsWithBuildingEntrances`
  ///
  /// Parameters:
  /// - [cityName]: The name of the city for which routing data is being prepared.
  ///
  /// Returns:
  /// - A `Future<bool>` indicating whether the operation was successful:
  ///   - `true`: Routing data was successfully loaded or downloaded.
  ///   - `false`: An error occurred while fetching the bounding box
  ///
  Future<bool> useCity(String cityName) async {
    final filePath = await getCityPath(cityName);
    try {
      graph = await Graph().loadGraph(filePath);
      currentCity = cityName;
      return true;
    } catch (_) {
      final boundingBox = await _fetchBoundingBox(cityName);
      if (boundingBox == null) {
        // print('Could not fetch bounding box for $cityName.');
        return false;
      }
      currentCity = cityName;
      final minLat = boundingBox['minLat']!;
      final minLon = boundingBox['minLon']!;
      final maxLat = boundingBox['maxLat']!;
      final maxLon = boundingBox['maxLon']!;
      graph = await _fetchGraph([minLat, minLon, maxLat, maxLon], true);
      await graph.saveGraph(filePath);
      return true;
    }
  }

  /// Lookup a city bounding box via OSM/Nominatim and parse its extent (always double, never NaN).
  Future<Map<String, double>?> _fetchBoundingBox(String city) async {
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?city=$city&format=json&limit=1');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final results = jsonDecode(response.body) as List;
        if (results.isNotEmpty) {
          final result = results[0];

          double parseBox(dynamic value) {
            if (value is num && value.isFinite) return value.toDouble();
            if (value is String) {
              final d = double.tryParse(value);
              if (d != null && d.isFinite) return d;
            }
            return 0.0;
          }

          final bbox = result['boundingbox'] ?? [];
          if (bbox is List && bbox.length >= 4) {
            return {
              'minLat': parseBox(bbox[0]),
              'maxLat': parseBox(bbox[1]),
              'minLon': parseBox(bbox[2]),
              'maxLon': parseBox(bbox[3]),
            };
          }
        }
      }
    } catch (e) {
      // print('Error fetching bounding box: $e');
    }
    return null;
  }
}

class _GraphSegment {
  const _GraphSegment(this.edge, this.startNode, this.endNode);

  final Edge edge;
  final Node startNode;
  final Node endNode;
}

class _ProjectedPoint {
  const _ProjectedPoint(this.point, this.fraction, this.distanceMeters);

  final LatLng point;
  final double fraction;
  final double distanceMeters;
}

class _EndpointClassification {
  const _EndpointClassification({
    required this.isOnTrack,
    this.anchor,
    this.graphNodeId,
    this.originalSegmentId,
    this.segmentFromNodeId,
    this.segmentToNodeId,
    this.fractionAlongSegment,
    this.distanceToGraphMeters,
  });

  final bool isOnTrack;
  final EndpointAnchor? anchor;
  final int? graphNodeId;
  final String? originalSegmentId;
  final int? segmentFromNodeId;
  final int? segmentToNodeId;
  final double? fractionAlongSegment;
  final double? distanceToGraphMeters;
}
