class Edge {
  final int from;
  final int to;
  final double weight;
  final String? originalSegmentId;

  Edge(
    this.from,
    this.to,
    this.weight, {
    this.originalSegmentId,
  });

  @override
  String toString() {
    return 'from: $from, to: $to, weight: $weight, '
        'originalSegmentId: $originalSegmentId';
  }
}
