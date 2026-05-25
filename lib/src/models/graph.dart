import 'edge.dart';
import 'node.dart';
import 'dart:convert';
import 'dart:io';

class Graph {
  final Map<int, Node> nodes = {};
  final Map<int, List<Edge>> adjacencyList = {};

  bool _containsDirectedEdge(Edge edge) {
    final candidates = adjacencyList[edge.from];
    if (candidates == null) {
      return false;
    }

    return candidates.any(
      (candidate) =>
          candidate.to == edge.to &&
          candidate.weight == edge.weight &&
          candidate.originalSegmentId == edge.originalSegmentId,
    );
  }

  void addNode(Node node) {
    nodes[node.id] = node;
    adjacencyList[node.id] = [];
  }

  void addEdge(Edge edge) {
    if (!_containsDirectedEdge(edge)) {
      adjacencyList[edge.from]?.add(edge);
    }

    final reverse = Edge(
      edge.to,
      edge.from,
      edge.weight,
      originalSegmentId: edge.originalSegmentId,
    );
    if (!_containsDirectedEdge(reverse)) {
      adjacencyList[reverse.from]?.add(reverse);
    }
  }

  void removeNode(int nodeId) {
    // Remove node
    nodes.remove(nodeId);

    // Remove edges efficiently
    final edgesToRemove = adjacencyList.remove(nodeId) ?? [];
    for (final edge in edgesToRemove) {
      adjacencyList[edge.to]?.removeWhere((e) => e.to == nodeId);
    }
  }

  Future<Graph> loadGraph(filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      throw Exception('Graph file for $filePath not found.');
    }

    // Read and parse JSON
    final jsonString = await file.readAsString();
    final Map<String, dynamic> graphJson = jsonDecode(jsonString);

    // Reconstruct Graph
    final graph = Graph();
    final nodeMap = <int, Node>{};

    // Add nodes
    for (final nodeJson in graphJson['nodes']) {
      final node = Node(
        nodeJson['id'],
        nodeJson['lat'],
        nodeJson['lon'],
        nodeJson['isFootWay'],
      );
      graph.addNode(node);
      nodeMap[node.id] = node;
    }

    final serializedEdges = graphJson['edges'];
    if (serializedEdges is! List) {
      return graph;
    }

    final legacyGroups = <String, List<Map<String, dynamic>>>{};

    for (final edgeJson in serializedEdges) {
      if (edgeJson is! Map) {
        continue;
      }

      final typed = Map<String, dynamic>.from(edgeJson);
      final from = typed['from'];
      final to = typed['to'];
      final weight = typed['weight'];
      if (from is! int || to is! int || weight is! num) {
        continue;
      }

      final originalSegmentId = typed['originalSegmentId'];
      if (originalSegmentId is String && originalSegmentId.isNotEmpty) {
        graph.addEdge(
          Edge(
            from,
            to,
            weight.toDouble(),
            originalSegmentId: originalSegmentId,
          ),
        );
        continue;
      }

      final orderedFrom = from < to ? from : to;
      final orderedTo = from < to ? to : from;
      final legacyKey = '$orderedFrom-$orderedTo-${weight.toDouble()}';
      legacyGroups.putIfAbsent(legacyKey, () => []).add(typed);
    }

    for (final entry in legacyGroups.entries) {
      final first = entry.value.first;
      final from = first['from'] as int;
      final to = first['to'] as int;
      final weight = (first['weight'] as num).toDouble();
      graph.addEdge(
        Edge(
          from,
          to,
          weight,
          originalSegmentId: 'legacy:${entry.key}',
        ),
      );
    }

    return graph;
  }

  Graph clone() {
    final cloned = Graph();
    for (final node in nodes.values) {
      cloned.addNode(Node(node.id, node.lat, node.lon, node.isFootWay));
    }

    final added = <String>{};
    for (final entry in adjacencyList.entries) {
      for (final edge in entry.value) {
        final orderedFrom = edge.from < edge.to ? edge.from : edge.to;
        final orderedTo = edge.from < edge.to ? edge.to : edge.from;
        final key = '$orderedFrom-$orderedTo-${edge.originalSegmentId}-${edge.weight}';
        if (!added.add(key)) {
          continue;
        }
        cloned.addEdge(
          Edge(
            edge.from,
            edge.to,
            edge.weight,
            originalSegmentId: edge.originalSegmentId,
          ),
        );
      }
    }
    return cloned;
  }

  Future<void> saveGraph(String filePath) async {
    final file = File(filePath);

    // Serialize Graph to JSON
    final graphJson = {
      'nodes': nodes.values
          .map((node) => {
                'id': node.id,
                'lat': node.lat,
                'lon': node.lon,
                'isFootWay': node.isFootWay,
              })
          .toList(),
      'edges': () {
        final serialized = <Map<String, dynamic>>[];
        final written = <String>{};
        for (final entry in adjacencyList.entries) {
          for (final edge in entry.value) {
            final orderedFrom = edge.from < edge.to ? edge.from : edge.to;
            final orderedTo = edge.from < edge.to ? edge.to : edge.from;
            final key = '$orderedFrom-$orderedTo-${edge.originalSegmentId}-${edge.weight}';
            if (!written.add(key)) {
              continue;
            }
            serialized.add({
              'from': edge.from,
              'to': edge.to,
              'weight': edge.weight,
              if (edge.originalSegmentId != null)
                'originalSegmentId': edge.originalSegmentId,
            });
          }
        }
        return serialized;
      }(),
    };

    await file.writeAsString(jsonEncode(graphJson));
  }
}
