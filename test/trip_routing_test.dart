import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trip_routing/trip_routing.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('Anchored segment routing', () {
    late TripService routing;

    setUp(() async {
      routing = TripService();
      await routing.loadOverpassJson(_lineGraphFixture(), source: 'fixture');
    });

    test('snaps a near-node endpoint to that node', () async {
      final result = await routing.findAnchoredSegment(
        start: const LatLng(50.0, 6.00003),
        end: const LatLng(50.0, 6.00997),
        maxSnapDistanceMeters: 50,
      );

      expect(result.status, AnchoredSegmentStatus.routed);
      expect(result.startAnchor?.type, EndpointAnchorType.node);
      expect(result.startAnchor?.nodeId, 1);
    });

    test('anchors an on-track point to the nearest edge projection', () async {
      final probe = await routing.probeEndpointAnchor(
        point: const LatLng(50.00009, 6.005),
        maxSnapDistanceMeters: 50,
      );

      expect(probe.isOnTrack, isTrue);
      expect(probe.anchor?.type, EndpointAnchorType.edgeProjection);
      expect(probe.anchor?.originalSegmentId, '100:0');
    });

    test('returns offTrack when endpoint is beyond threshold', () async {
      final result = await routing.findAnchoredSegment(
        start: const LatLng(50.002, 6.005),
        end: const LatLng(50.0, 6.01),
        maxSnapDistanceMeters: 50,
      );

      expect(result.status, AnchoredSegmentStatus.offTrack);
      expect(result.route, isEmpty);
      expect(result.distance, 0);
    });

    test('returns noPath when both endpoints are on-track but disconnected', () async {
      final disconnected = TripService();
      await disconnected.loadOverpassJson(_disconnectedFixture(), source: 'fixture');

      final result = await disconnected.findAnchoredSegment(
        start: const LatLng(50.0, 6.005),
        end: const LatLng(50.01, 6.025),
        maxSnapDistanceMeters: 50,
      );

      expect(result.status, AnchoredSegmentStatus.noPath);
      expect(result.route, isEmpty);
      expect(result.distance, 0);
      expect(result.startAnchor, isNotNull);
      expect(result.endAnchor, isNotNull);
    });

    test('routes directly along the same projected edge', () async {
      final result = await routing.findAnchoredSegment(
        start: const LatLng(50.00009, 6.003),
        end: const LatLng(50.00009, 6.007),
        maxSnapDistanceMeters: 50,
      );

      expect(result.status, AnchoredSegmentStatus.routed);
      expect(result.route, hasLength(2));
      expect(result.startAnchor?.type, EndpointAnchorType.edgeProjection);
      expect(result.endAnchor?.type, EndpointAnchorType.edgeProjection);
      expect(result.distance, greaterThan(0));
    });

    test('request-local overlay does not mutate base graph', () async {
      final initialNodeCount = routing.graph.nodes.length;
      final initialEdgeCount = routing.graph.adjacencyList.values.fold<int>(
        0,
        (sum, edges) => sum + edges.length,
      );

      final first = await routing.findAnchoredSegment(
        start: const LatLng(50.00009, 6.0025),
        end: const LatLng(50.00009, 6.0075),
        maxSnapDistanceMeters: 50,
      );
      final second = await routing.findAnchoredSegment(
        start: const LatLng(50.00009, 6.0025),
        end: const LatLng(50.00009, 6.0075),
        maxSnapDistanceMeters: 50,
      );

      expect(first.status, AnchoredSegmentStatus.routed);
      expect(second.status, AnchoredSegmentStatus.routed);
      expect(routing.graph.nodes.length, initialNodeCount);
      expect(
        routing.graph.adjacencyList.values.fold<int>(
          0,
          (sum, edges) => sum + edges.length,
        ),
        initialEdgeCount,
      );
      expect(routing.graph.nodes.keys.where((id) => id < 0), isEmpty);
    });
  });

  group('Graph JSON compatibility', () {
    test('backward-reads legacy graph JSON without provenance fields', () async {
      final tempDir = await Directory.systemTemp.createTemp('trip-routing-graph');
      addTearDown(() => tempDir.delete(recursive: true));
      final graphFile = File('${tempDir.path}/graph.json');
      await graphFile.writeAsString('''
{
  "nodes": [
    {"id": 1, "lat": 50.0, "lon": 6.0, "isFootWay": false},
    {"id": 2, "lat": 50.0, "lon": 6.01, "isFootWay": false}
  ],
  "edges": [
    {"from": 1, "to": 2, "weight": 10.0},
    {"from": 2, "to": 1, "weight": 10.0}
  ]
}
''');

      final graph = await Graph().loadGraph(graphFile.path);
      final forward = graph.adjacencyList[1]!;
      final reverse = graph.adjacencyList[2]!;

      expect(forward, hasLength(1));
      expect(reverse, hasLength(1));
      expect(forward.single.originalSegmentId, isNotNull);
      expect(forward.single.originalSegmentId, reverse.single.originalSegmentId);
    });
  });

  group('TripService local Overpass loaders', () {
    test('loadOverpassJson builds an offline graph', () async {
      final routing = TripService();

      await routing.loadOverpassJson({
        'elements': [
          {
            'type': 'node',
            'id': 1,
            'lat': 50.0,
            'lon': 6.0,
          },
          {
            'type': 'node',
            'id': 2,
            'lat': 50.0,
            'lon': 6.001,
          },
          {
            'type': 'way',
            'id': 10,
            'nodes': [1, 2],
            'tags': {'highway': 'path', 'footway': 'sidewalk'},
          },
        ],
      }, source: 'fixture');

      expect(routing.currentCity, 'fixture');
      expect(routing.graph.nodes.keys, containsAll([1, 2]));
      expect(routing.graph.adjacencyList[1], isNotEmpty);

      final trip = await routing.findTotalTrip([
        const LatLng(50.0, 6.0),
        const LatLng(50.0, 6.001),
      ]);

      expect(trip.errors, isEmpty);
      expect(trip.route.length, greaterThanOrEqualTo(2));
      expect(trip.distance, greaterThan(0));
    });

    test('loadOverpassJson rejects missing elements list', () async {
      final routing = TripService();

      expect(
        () => routing.loadOverpassJson(const {}),
        throwsFormatException,
      );
    });
  });

  group('TripService', () {
    late TripService routing;

    setUp(() async {
      routing = TripService();
      await routing.loadOverpassJson(_lineGraphFixture(), source: 'fixture');
    });

    test('findTotalTrip returns a route with distance', () async {
      final trip = await routing.findTotalTrip(
        const [LatLng(50.0, 6.0), LatLng(50.0, 6.01)],
        preferWalkingPaths: true,
        replaceWaypointsWithBuildingEntrances: true,
      );

      // Ensure the route is not empty
      expect(trip.route.isNotEmpty, true);

      // Check if distance is greater than zero
      expect(trip.distance, greaterThan(0));

      // There should be no errors
      expect(trip.errors, isEmpty);
    });

    test('findTotalTrip handles errors gracefully', () async {
      final invalidWaypoints = [
        const LatLng(50.01, 6.02),
        const LatLng(50.01, 6.03),
      ];

      final trip = await routing.findTotalTrip(
        invalidWaypoints,
        preferWalkingPaths: true,
        replaceWaypointsWithBuildingEntrances: true,
      );

      expect(trip.errors, isNotEmpty);
    });
  });
}

Map<String, dynamic> _lineGraphFixture() {
  return {
    'elements': [
      {'type': 'node', 'id': 1, 'lat': 50.0, 'lon': 6.0},
      {'type': 'node', 'id': 2, 'lat': 50.0, 'lon': 6.01},
      {'type': 'way', 'id': 100, 'nodes': [1, 2], 'tags': {'highway': 'path'}},
    ],
  };
}

Map<String, dynamic> _disconnectedFixture() {
  return {
    'elements': [
      {'type': 'node', 'id': 1, 'lat': 50.0, 'lon': 6.0},
      {'type': 'node', 'id': 2, 'lat': 50.0, 'lon': 6.01},
      {'type': 'node', 'id': 3, 'lat': 50.01, 'lon': 6.02},
      {'type': 'node', 'id': 4, 'lat': 50.01, 'lon': 6.03},
      {'type': 'way', 'id': 100, 'nodes': [1, 2], 'tags': {'highway': 'path'}},
      {'type': 'way', 'id': 200, 'nodes': [3, 4], 'tags': {'highway': 'path'}},
    ],
  };
}
