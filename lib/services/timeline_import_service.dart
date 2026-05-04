import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import '../models/location_point.dart';
import 'database_service.dart';

class ImportStats {
  const ImportStats({required this.insertedCount, required this.skippedCount});

  final int insertedCount;
  final int skippedCount;
}

class TimelineImportService {
  TimelineImportService(this._databaseService);

  final DatabaseService _databaseService;

  Future<ImportStats> importTimelineFile(String filePath) async {
    await _databaseService.clearLocations();

    final parsed = await Isolate.run(() => _parseTimelineFile(filePath));

    const chunkSize = 2000;
    for (var i = 0; i < parsed.points.length; i += chunkSize) {
      final end =
          (i + chunkSize < parsed.points.length)
              ? i + chunkSize
              : parsed.points.length;
      await _databaseService.insertBatch(parsed.points.sublist(i, end));
    }

    return ImportStats(
      insertedCount: parsed.points.length,
      skippedCount: parsed.skippedCount,
    );
  }
}

class _ParsedTimeline {
  const _ParsedTimeline({required this.points, required this.skippedCount});

  final List<LocationPoint> points;
  final int skippedCount;
}

_ParsedTimeline _parseTimelineFile(String filePath) {
  final file = File(filePath);
  final bytes = file.readAsBytesSync();
  final decoded = jsonDecode(utf8.decode(bytes));

  final rawEntries = _collectEntries(decoded);
  if (rawEntries.isEmpty) {
    throw const FormatException(
      'Could not find any supported timeline entries. Expected one of: locations, timelineObjects, semanticSegments.',
    );
  }

  final points = <LocationPoint>[];
  var skipped = 0;

  for (final entry in rawEntries) {
    if (entry is! Map<String, dynamic>) {
      skipped++;
      continue;
    }

    final parsedPoints = _toLocationPoints(entry);
    if (parsedPoints.isEmpty) {
      skipped++;
      continue;
    }

    points.addAll(parsedPoints);
  }

  return _ParsedTimeline(points: points, skippedCount: skipped);
}

List<Object?> _collectEntries(Object? decoded) {
  if (decoded is List) {
    return decoded;
  }
  if (decoded is! Map<String, dynamic>) {
    return const [];
  }

  final locations = decoded['locations'];
  if (locations is List) {
    return locations;
  }

  final timelineObjects = decoded['timelineObjects'];
  if (timelineObjects is List) {
    return timelineObjects;
  }

  final semanticSegments = decoded['semanticSegments'];
  if (semanticSegments is List) {
    return semanticSegments;
  }

  return const [];
}

List<LocationPoint> _toLocationPoints(Map<String, dynamic> entry) {
  final timelineObjectPoints = _fromTimelineObject(entry);
  if (timelineObjectPoints.isNotEmpty) {
    return timelineObjectPoints;
  }

  final semanticSegmentPoints = _fromSemanticSegment(entry);
  if (semanticSegmentPoints.isNotEmpty) {
    return semanticSegmentPoints;
  }

  final directPoint = _toDirectLocationPoint(entry);
  if (directPoint != null) {
    return [directPoint];
  }

  return const [];
}

LocationPoint? _toDirectLocationPoint(Map<String, dynamic> entry) {
  final latLon = _extractLatLon(entry);
  if (latLon == null) {
    return null;
  }

  final timestamp = _extractTimestamp(entry);
  if (timestamp == null) {
    return null;
  }

  final type = _extractType(entry);
  final activityName = _extractActivityName(entry);

  return LocationPoint(
    timestamp: timestamp,
    lat: latLon.$1,
    lon: latLon.$2,
    type: type,
    activityName: activityName,
  );
}

List<LocationPoint> _fromTimelineObject(Map<String, dynamic> entry) {
  final placeVisit = entry['placeVisit'];
  if (placeVisit is Map<String, dynamic>) {
    final location = placeVisit['location'];
    final duration = placeVisit['duration'];
    final timestamp = _extractTimestamp({
      'timestampMs': placeVisit['startTimestampMs'],
      'startTimestampMs':
          duration is Map<String, dynamic>
              ? duration['startTimestampMs']
              : null,
      'timestamp':
          duration is Map<String, dynamic> ? duration['startTimestamp'] : null,
    });
    final latLon = _extractLatLon(location);
    if (latLon != null && timestamp != null) {
      return [
        LocationPoint(
          timestamp: timestamp,
          lat: latLon.$1,
          lon: latLon.$2,
          type: 'visit',
          activityName: _extractActivityName(placeVisit),
        ),
      ];
    }
  }

  final activitySegment = entry['activitySegment'];
  if (activitySegment is Map<String, dynamic>) {
    final timestamp = _extractTimestamp({
      'timestampMs': activitySegment['startTimestampMs'],
      'startTimestampMs': activitySegment['startTimestampMs'],
      'timestamp': activitySegment['startTimestamp'],
    });
    if (timestamp == null) {
      return const [];
    }

    final activityType = _extractType(activitySegment);
    final activityName = _extractActivityName(activitySegment);
    final points = <LocationPoint>[];

    final startLatLon = _extractLatLon(activitySegment['startLocation']);
    if (startLatLon != null) {
      points.add(
        LocationPoint(
          timestamp: timestamp,
          lat: startLatLon.$1,
          lon: startLatLon.$2,
          type: activityType,
          activityName: activityName,
        ),
      );
    }

    final endLatLon = _extractLatLon(activitySegment['endLocation']);
    if (endLatLon != null) {
      points.add(
        LocationPoint(
          timestamp: timestamp,
          lat: endLatLon.$1,
          lon: endLatLon.$2,
          type: activityType,
          activityName: activityName,
        ),
      );
    }

    final waypoints =
        (activitySegment['waypointPath']
            as Map<String, dynamic>?)?['waypoints'];
    if (waypoints is List) {
      for (final waypoint in waypoints) {
        final latLon = _extractLatLon(waypoint);
        if (latLon == null) {
          continue;
        }
        points.add(
          LocationPoint(
            timestamp: timestamp,
            lat: latLon.$1,
            lon: latLon.$2,
            type: activityType,
            activityName: activityName,
          ),
        );
      }
    }

    return points;
  }

  return const [];
}

List<LocationPoint> _fromSemanticSegment(Map<String, dynamic> entry) {
  final startTime = _extractTimestamp({
    'timestamp': entry['startTime'] ?? entry['startTimeMs'],
  });
  if (startTime == null) {
    return const [];
  }

  final points = <LocationPoint>[];

  final visit = entry['visit'];
  if (visit is Map<String, dynamic>) {
    final topCandidate = visit['topCandidate'];
    final latLon = _extractLatLon(topCandidate);
    if (latLon != null) {
      points.add(
        LocationPoint(
          timestamp: startTime,
          lat: latLon.$1,
          lon: latLon.$2,
          type: 'visit',
          activityName: _extractActivityName(visit),
        ),
      );
    }
  }

  final activity = entry['activity'];
  if (activity is Map<String, dynamic>) {
    final activityType = _extractType(activity);
    final activityName = _extractActivityName(activity);

    final startLatLon = _extractLatLon(activity['start']);
    if (startLatLon != null) {
      points.add(
        LocationPoint(
          timestamp: startTime,
          lat: startLatLon.$1,
          lon: startLatLon.$2,
          type: activityType,
          activityName: activityName,
        ),
      );
    }

    final endLatLon = _extractLatLon(activity['end']);
    if (endLatLon != null) {
      points.add(
        LocationPoint(
          timestamp: startTime,
          lat: endLatLon.$1,
          lon: endLatLon.$2,
          type: activityType,
          activityName: activityName,
        ),
      );
    }

    final waypoints =
        (activity['waypointPath'] as Map<String, dynamic>?)?['waypoints'];
    if (waypoints is List) {
      for (final waypoint in waypoints) {
        final latLon = _extractLatLon(waypoint);
        if (latLon == null) {
          continue;
        }
        points.add(
          LocationPoint(
            timestamp: startTime,
            lat: latLon.$1,
            lon: latLon.$2,
            type: activityType,
            activityName: activityName,
          ),
        );
      }
    }
  }

  final timelinePath = entry['timelinePath'];
  if (timelinePath is List) {
    for (final pathEntry in timelinePath) {
      if (pathEntry is! Map<String, dynamic>) {
        continue;
      }

      final latLon = _extractLatLon(pathEntry);
      final pointTime = _extractTimestamp({
        'timestamp': pathEntry['time'] ?? pathEntry['timestamp'],
      });

      if (latLon == null || pointTime == null) {
        continue;
      }

      points.add(
        LocationPoint(
          timestamp: pointTime,
          lat: latLon.$1,
          lon: latLon.$2,
          type: 'trace',
          activityName: null,
        ),
      );
    }
  }

  return points;
}

(int, int)? _extractTimestampRange(Map<String, dynamic> entry) {
  final start = _tryParseTimestampMs(
    entry['timestampMs'] ?? entry['timestamp'] ?? entry['startTimestampMs'],
  );
  final end = _tryParseTimestampMs(
    entry['endTimestampMs'] ?? entry['endTimestamp'],
  );
  if (start == null) {
    return null;
  }
  return (start, end ?? start);
}

int? _extractTimestamp(Map<String, dynamic> entry) {
  final range = _extractTimestampRange(entry);
  return range?.$1;
}

(double, double)? _extractLatLon(Object? value) {
  if (value is! Map<String, dynamic>) {
    return null;
  }

  final entry = value;
  final latE7 = _tryParseInt(entry['latitudeE7'] ?? entry['latE7']);
  final lonE7 = _tryParseInt(entry['longitudeE7'] ?? entry['lngE7']);
  if (latE7 != null && lonE7 != null) {
    return (latE7 / 1e7, lonE7 / 1e7);
  }

  final lat = _tryParseDouble(entry['latitude'] ?? entry['lat']);
  final lon = _tryParseDouble(
    entry['longitude'] ?? entry['lon'] ?? entry['lng'],
  );
  if (lat != null && lon != null) {
    return (lat, lon);
  }

  final location = entry['location'];
  if (location is Map<String, dynamic>) {
    final nested = _extractLatLon(location);
    if (nested != null) {
      return nested;
    }
  }

  final placeLocation = entry['placeLocation'];
  if (placeLocation is Map<String, dynamic>) {
    final parsed = _extractLatLon(placeLocation);
    if (parsed != null) {
      return parsed;
    }
  }
  if (placeLocation is String) {
    final parsed = _parseLatLonText(placeLocation);
    if (parsed != null) {
      return parsed;
    }
  }

  final latLng = entry['latLng'];
  if (latLng is String) {
    final parsed = _parseLatLonText(latLng);
    if (parsed != null) {
      return parsed;
    }
  }

  final point = entry['point'];
  if (point is String) {
    final parsed = _parseLatLonText(point);
    if (parsed != null) {
      return parsed;
    }
  }

  return null;
}

String _extractType(Map<String, dynamic> entry) {
  final rawType =
      entry['type'] ??
      entry['activityType'] ??
      (entry['topCandidate'] as Map<String, dynamic>?)?['type'];
  if (rawType is String && rawType.trim().isNotEmpty) {
    return rawType.trim().toLowerCase();
  }

  return 'trace';
}

String? _extractActivityName(Map<String, dynamic> entry) {
  final raw =
      entry['activity_name'] ?? entry['activityName'] ?? entry['activity'];
  if (raw is String && raw.trim().isNotEmpty) {
    return raw.trim();
  }
  return null;
}

int? _tryParseInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

int? _tryParseTimestampMs(Object? value) {
  final fromInt = _tryParseInt(value);
  if (fromInt != null) {
    return fromInt;
  }
  if (value is String) {
    return _parseDateToEpochMs(value);
  }
  return null;
}

(double, double)? _parseLatLonText(String value) {
  final normalized = value.trim();

  final degreeNormalized = normalized.replaceAll('°', '');
  final degreeParts = degreeNormalized.split(',');
  if (degreeParts.length >= 2) {
    final lat = double.tryParse(degreeParts[0].trim());
    final lon = double.tryParse(degreeParts[1].trim());
    if (lat != null && lon != null) {
      return (lat, lon);
    }
  }

  if (normalized.startsWith('geo:')) {
    final coords = normalized.substring(4).split(',');
    if (coords.length >= 2) {
      final lat = double.tryParse(coords[0].trim());
      final lon = double.tryParse(coords[1].trim());
      if (lat != null && lon != null) {
        return (lat, lon);
      }
    }
  }
  return null;
}

double? _tryParseDouble(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

int? _parseDateToEpochMs(String value) {
  final trimmed = value.trim();
  final dt = DateTime.tryParse(trimmed);
  if (dt == null) {
    return null;
  }
  return dt.millisecondsSinceEpoch;
}
