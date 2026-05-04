class LocationPoint {
  const LocationPoint({
    this.id,
    required this.timestamp,
    required this.lat,
    required this.lon,
    required this.type,
    this.activityName,
  });

  final int? id;
  final int timestamp;
  final double lat;
  final double lon;
  final String type;
  final String? activityName;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'timestamp': timestamp,
      'lat': lat,
      'lon': lon,
      'type': type,
      'activity_name': activityName,
    };
  }

  factory LocationPoint.fromMap(Map<String, Object?> map) {
    return LocationPoint(
      id: map['id'] as int?,
      timestamp: (map['timestamp'] as num).toInt(),
      lat: (map['lat'] as num).toDouble(),
      lon: (map['lon'] as num).toDouble(),
      type: (map['type'] as String?) ?? 'trace',
      activityName: map['activity_name'] as String?,
    );
  }
}
