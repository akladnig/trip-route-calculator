import 'package:latlong2/latlong.dart';

enum EndpointAnchorType { raw, node, edgeProjection }

enum AnchoredSegmentStatus { routed, offTrack, noPath, failed }

class EndpointAnchor {
  const EndpointAnchor({
    required this.point,
    required this.type,
    this.nodeId,
    this.originalSegmentId,
  });

  final LatLng point;
  final EndpointAnchorType type;
  final int? nodeId;
  final String? originalSegmentId;
}

class AnchoredSegmentResult {
  const AnchoredSegmentResult({
    required this.status,
    required this.route,
    required this.distance,
    required this.errors,
    this.startAnchor,
    this.endAnchor,
  });

  final AnchoredSegmentStatus status;
  final List<LatLng> route;
  final double distance;
  final List<String> errors;
  final EndpointAnchor? startAnchor;
  final EndpointAnchor? endAnchor;
}

class EndpointProbeResult {
  const EndpointProbeResult({
    required this.isOnTrack,
    this.anchor,
    this.errors = const [],
  });

  final bool isOnTrack;
  final EndpointAnchor? anchor;
  final List<String> errors;
}
