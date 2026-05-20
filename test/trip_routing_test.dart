import 'package:flutter_test/flutter_test.dart';
import 'package:trip_routing/trip_routing.dart';
import 'package:latlong2/latlong.dart';

void main() {
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
    final waypoints = [
      const LatLng(50.77437074991441, 6.075419266272186),
      const LatLng(50.774717242584515, 6.083980842518867),
    ];

    final routing = TripService();

    setUpAll(() async {
      // Make routing available offline
      await routing.useCity('Aachen');
    });

    test('findTotalTrip returns a route with distance', () async {
      final trip = await routing.findTotalTrip(
        waypoints,
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
      //unreachable waypoints
      final invalidWaypoints = [
        const LatLng(0, 0),
        const LatLng(0, 0),
      ];

      try {
        final trip = await routing.findTotalTrip(
          invalidWaypoints,
          preferWalkingPaths: true,
          replaceWaypointsWithBuildingEntrances: true,
        );

        // If no exception is thrown, check for errors in the result
        expect(trip.errors.isNotEmpty, true);
      } catch (e) {
        // If an exception is thrown, it's also acceptable
        expect(e, isNotNull);
      }
    });
  });
}
