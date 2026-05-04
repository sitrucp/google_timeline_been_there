import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/location_point.dart';
import '../services/database_service.dart';
import '../services/geocoding_service.dart';
import '../services/timeline_import_service.dart';

class GeoHistoryPage extends StatefulWidget {
  const GeoHistoryPage({super.key});

  @override
  State<GeoHistoryPage> createState() => _GeoHistoryPageState();
}

class _GeoHistoryPageState extends State<GeoHistoryPage> {
  final _databaseService = DatabaseService.instance;
  final _geocodingService = GeocodingService();
  final _mapController = MapController();
  final _distance = const Distance();
  final _addressController = TextEditingController();
  final _coordinateController = TextEditingController();

  late final TimelineImportService _timelineImportService;

  bool _isImporting = false;
  String _status = 'Import timeline.json to begin.';

  LatLng _queryCenter = const LatLng(37.7749, -122.4194);
  List<LocationPoint> _viewportPoints = const [];
  Map<String, int> _typeCounts = const {};
  List<_TraceFragment> _traceFragments = const [];
  double _currentZoom = 10;
  Timer? _mapDebounce;

  bool _isLegendExpanded = true;
  bool _isFullscreenMap = false;

  @override
  void initState() {
    super.initState();
    _timelineImportService = TimelineImportService(_databaseService);
    _loadRecent();
  }

  @override
  void dispose() {
    _mapDebounce?.cancel();
    _addressController.dispose();
    _coordinateController.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final points = await _databaseService.getRecentPoints(limit: 8000);
    if (!mounted) {
      return;
    }

    setState(() {
      if (points.isNotEmpty) {
        _queryCenter = LatLng(points.first.lat, points.first.lon);
        _status = 'Loaded ${points.length} recent points from local cache.';
      }
    });

    if (points.isNotEmpty) {
      _mapController.move(_queryCenter, 13);
      _scheduleViewportRefresh();
    }
  }

  Future<void> _importTimeline() async {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );

    final path = picked?.files.single.path;
    if (path == null) {
      return;
    }

    setState(() {
      _isImporting = true;
      _status = 'Import in progress...';
    });

    try {
      final stats = await _timelineImportService.importTimelineFile(path);
      final recent = await _databaseService.getRecentPoints(limit: 8000);

      if (!mounted) {
        return;
      }

      setState(() {
        if (recent.isNotEmpty) {
          _queryCenter = LatLng(recent.first.lat, recent.first.lon);
          _mapController.move(_queryCenter, 12);
        }
        _status =
            'Import complete. Inserted ${stats.insertedCount} points, skipped ${stats.skippedCount}.';
      });

      _scheduleViewportRefresh();
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Import failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
      }
    }
  }

  Future<void> _handleGoButton() async {
    final addressQuery = _addressController.text.trim();
    final coordQuery = _coordinateController.text.trim();

    if (addressQuery.isEmpty && coordQuery.isEmpty) {
      // No input: use current location (recent points)
      final recent = await _databaseService.getRecentPoints(limit: 1);
      if (recent.isEmpty) {
        setState(() {
          _status = 'No location history available. Import timeline first.';
        });
        return;
      }
      setState(() {
        _queryCenter = LatLng(recent.first.lat, recent.first.lon);
        _status = 'Using most recent location from history.';
      });
      _mapController.move(_queryCenter, 13);
      _scheduleViewportRefresh();
      return;
    }

    if (addressQuery.isNotEmpty) {
      // Geocode address
      setState(() {
        _status = 'Resolving address...';
      });
      try {
        final result = await _geocodingService.geocodeAddress(addressQuery);
        if (result == null) {
          setState(() {
            _status = 'No geocoding result found.';
          });
          return;
        }
        setState(() {
          _queryCenter = LatLng(result.$1, result.$2);
          _status =
              'Address resolved to ${result.$1.toStringAsFixed(5)}, ${result.$2.toStringAsFixed(5)}.';
        });
        _mapController.move(_queryCenter, 13);
        _scheduleViewportRefresh();
      } catch (e) {
        setState(() {
          _status = 'Geocoding failed: $e';
        });
      }
      return;
    }

    if (coordQuery.isNotEmpty) {
      // Parse coordinates
      final parts = coordQuery.split(',');
      if (parts.length != 2) {
        setState(() {
          _status = 'Invalid coordinates. Use lat,lon format.';
        });
        return;
      }

      final lat = double.tryParse(parts[0].trim());
      final lon = double.tryParse(parts[1].trim());
      if (lat == null || lon == null) {
        setState(() {
          _status = 'Invalid coordinates. Use decimal numbers.';
        });
        return;
      }

      setState(() {
        _queryCenter = LatLng(lat, lon);
        _status =
            'Map centered to ${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}.';
      });
      _mapController.move(_queryCenter, 13);
      _scheduleViewportRefresh();
    }
  }

  void _clearAddressField() {
    _addressController.clear();
    setState(() {
      _status = 'Address field cleared.';
    });
  }

  void _clearCoordinateField() {
    _coordinateController.clear();
    setState(() {
      _status = 'Coordinate field cleared.';
    });
  }

  void _scheduleViewportRefresh() {
    _mapDebounce?.cancel();
    _mapDebounce = Timer(const Duration(milliseconds: 320), () {
      _refreshViewportPoints();
    });
  }

  Future<void> _refreshViewportPoints() async {
    final visibleBounds = _mapController.camera.visibleBounds;
    final minLat = visibleBounds.south;
    final maxLat = visibleBounds.north;
    final minLon = visibleBounds.west;
    final maxLon = visibleBounds.east;

    const padFactor = 0.1;
    final latPad = (maxLat - minLat) * padFactor;
    final lonPad = (maxLon - minLon) * padFactor;

    // Load all available data (always use high limit)
    const pointLimit = 2000000;

    final points = await _databaseService.queryWithinBounds(
      minLat: minLat - latPad,
      maxLat: maxLat + latPad,
      minLon: minLon - lonPad,
      maxLon: maxLon + lonPad,
      limit: pointLimit,
    );

    if (!mounted) {
      return;
    }

    final fragments = _buildFragments(points);
    final typeCounts = <String, int>{};
    for (final point in points) {
      final type = point.type.toLowerCase();
      typeCounts.update(type, (value) => value + 1, ifAbsent: () => 1);
    }

    setState(() {
      _viewportPoints = points;
      _traceFragments = fragments;
      _typeCounts = typeCounts;
      final capState = points.length >= pointLimit ? 'CAP HIT' : 'UNDER CAP';
      _status =
          'Viewport has ${points.length} points ($capState), ${fragments.length} directional traces.';
    });
  }

  List<_TraceFragment> _buildFragments(List<LocationPoint> source) {
    if (source.length < 2) {
      return const [];
    }

    final ordered = [...source]..sort((a, b) {
      final byTs = a.timestamp.compareTo(b.timestamp);
      if (byTs != 0) {
        return byTs;
      }
      return (a.id ?? 0).compareTo(b.id ?? 0);
    });

    final fragments = <_TraceFragment>[];
    var currentType = '';
    var current = <LocationPoint>[];

    for (final point in ordered) {
      final nextType = point.type.toLowerCase();
      if (nextType == 'visit') {
        continue;
      }

      if (current.isEmpty) {
        currentType = nextType;
        current.add(point);
        continue;
      }

      final previous = current.last;
      final gapMs = point.timestamp - previous.timestamp;
      final jumpMeters = _distance(
        LatLng(previous.lat, previous.lon),
        LatLng(point.lat, point.lon),
      );

      final gapMinutes = gapMs / 60000.0;
      final speedMps = gapMs > 0 ? jumpMeters / (gapMs / 1000.0) : 0.0;
      final speedKmh = speedMps * 3.6;

      final isWalkLike =
          currentType.contains('walk') ||
          currentType.contains('foot') ||
          currentType.contains('run') ||
          currentType.contains('cycle') ||
          currentType.contains('bicycle');
      final isRoadLike =
          currentType.contains('drive') ||
          currentType.contains('car') ||
          currentType.contains('taxi') ||
          currentType.contains('vehicle');
      final isTransitLike =
          currentType.contains('bus') ||
          currentType.contains('train') ||
          currentType.contains('subway') ||
          currentType.contains('ferry');

      final maxGapMinutes =
          isWalkLike
              ? 20.0
              : isRoadLike
              ? 45.0
              : isTransitLike
              ? 70.0
              : 35.0;

      final maxSpeedKmh =
          isWalkLike
              ? 45.0
              : isRoadLike
              ? 190.0
              : isTransitLike
              ? 260.0
              : 170.0;

      final shouldBreak =
          nextType != currentType ||
          gapMinutes > maxGapMinutes ||
          (speedKmh > maxSpeedKmh && jumpMeters > 400) ||
          (jumpMeters > 15000 && gapMinutes < 8) ||
          (jumpMeters > 50000 && gapMinutes < 60);

      if (shouldBreak) {
        if (current.length > 1) {
          fragments.add(
            _TraceFragment(type: currentType, points: [...current]),
          );
        }
        current = [point];
        currentType = nextType;
      } else {
        current.add(point);
      }
    }

    if (current.length > 1) {
      fragments.add(_TraceFragment(type: currentType, points: [...current]));
    }

    return fragments;
  }

  List<Polyline> _buildTracePolylines() {
    const stride = 1;

    return _traceFragments
        .map((fragment) {
          final sampled = <LatLng>[];
          for (var i = 0; i < fragment.points.length; i += stride) {
            final p = fragment.points[i];
            sampled.add(LatLng(p.lat, p.lon));
          }

          final last = fragment.points.last;
          final lastLatLng = LatLng(last.lat, last.lon);
          if (sampled.isEmpty || sampled.last != lastLatLng) {
            sampled.add(lastLatLng);
          }

          return Polyline(
            points: sampled,
            strokeWidth: _currentZoom >= 14 ? 3.5 : 3,
            color: _colorForType(fragment.type),
          );
        })
        .toList(growable: false);
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    final visitPoints = _viewportPoints
        .where((p) => p.type == 'visit')
        .take(500);
    for (final point in visitPoints) {
      markers.add(
        Marker(
          width: 22,
          height: 22,
          point: LatLng(point.lat, point.lon),
          child: const Icon(Icons.place, color: Colors.red, size: 14),
        ),
      );
    }

    markers.addAll(_buildDirectionMarkers());

    markers.add(
      Marker(
        width: 28,
        height: 28,
        point: _queryCenter,
        child: const Icon(Icons.my_location, color: Colors.black, size: 20),
      ),
    );

    return markers;
  }

  List<Marker> _buildDirectionMarkers() {
    final markers = <Marker>[];
    var budget = 420;

    final spacing =
        _currentZoom >= 14
            ? 5
            : _currentZoom >= 12
            ? 9
            : 16;

    for (final fragment in _traceFragments) {
      if (fragment.points.length < 2 || budget <= 0) {
        continue;
      }

      final color = _colorForType(fragment.type);
      final points = fragment.points;

      markers.add(_arrowMarker(points[0], points[1], color));
      budget--;

      for (var i = spacing; i < points.length - 1 && budget > 1; i += spacing) {
        markers.add(_arrowMarker(points[i], points[i + 1], color));
        budget--;
      }

      if (budget > 0) {
        markers.add(
          _arrowMarker(points[points.length - 2], points.last, color),
        );
        budget--;
      }
    }

    return markers;
  }

  Marker _arrowMarker(LocationPoint a, LocationPoint b, Color color) {
    final rotationRadians = _bearingRadians(a.lat, a.lon, b.lat, b.lon);
    return Marker(
      width: 16,
      height: 16,
      point: LatLng(a.lat, a.lon),
      child: Transform.rotate(
        angle: rotationRadians,
        child: Icon(Icons.navigation, color: color, size: 14),
      ),
    );
  }

  double _bearingRadians(double lat1, double lon1, double lat2, double lon2) {
    final phi1 = lat1 * math.pi / 180.0;
    final phi2 = lat2 * math.pi / 180.0;
    final dLon = (lon2 - lon1) * math.pi / 180.0;
    final y = math.sin(dLon) * math.cos(phi2);
    final x =
        math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
    return math.atan2(y, x);
  }

  Color _colorForType(String type) {
    final normalized = type.toLowerCase();
    return switch (normalized) {
      'walk' || 'walking' || 'on_foot' => const Color(0xFF00B050), // Lime green
      'drive' ||
      'in_car' ||
      'driving' ||
      'in_vehicle' => const Color(0xFF0070C0), // Royal blue
      'in_bus' || 'bus' => const Color(0xFFFF8C00), // Dark orange
      'in_train' ||
      'train' ||
      'subway' => const Color(0xFFC55A11), // Rust orange-brown
      'in_taxi' => const Color(0xFF8B00FF), // Purple
      'in_ferry' => const Color(0xFF00B8E6), // Light blue
      'cycling' || 'in_bicycle' || 'cycle' => const Color(0xFFD32F2F), // Red
      'running' => const Color(0xFFFF1493), // Deep pink
      _ => const Color(0xFF808080), // Dark gray
    };
  }

  Widget _buildTypeLegend() {
    if (_typeCounts.isEmpty) {
      return const SizedBox.shrink();
    }

    final sortedTypes =
        _typeCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(blurRadius: 6, color: Colors.black26, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Movement',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontSize: 12),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _isLegendExpanded = !_isLegendExpanded;
                  });
                },
                child: Icon(
                  _isLegendExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                ),
              ),
            ],
          ),
          if (_isLegendExpanded) ...[
            const SizedBox(height: 6),
            for (final item in sortedTypes.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _colorForType(item.key),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${item.key}: ${item.value}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GeoHistory Local Timeline Explorer'),
        actions: [
          PopupMenuButton(
            itemBuilder:
                (context) => [
                  PopupMenuItem(
                    onTap: _isImporting ? null : () => _importTimeline(),
                    child: const Text('Import timeline.json'),
                  ),
                ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child:
                    _isImporting
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.menu),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_isFullscreenMap) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // First row: Address field with clear button
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _addressController,
                          decoration: InputDecoration(
                            labelText: 'Search address',
                            border: const OutlineInputBorder(),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            suffixIcon:
                                _addressController.text.isNotEmpty
                                    ? IconButton(
                                      icon: const Icon(Icons.clear, size: 16),
                                      onPressed: _clearAddressField,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    )
                                    : null,
                          ),
                          style: const TextStyle(fontSize: 13),
                          onChanged: (value) {
                            setState(() {});
                          },
                          onSubmitted: (_) => _handleGoButton(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Second row: Coordinates with clear button, Go button, and controls
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _coordinateController,
                          decoration: InputDecoration(
                            labelText: 'lat,lon',
                            border: const OutlineInputBorder(),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            suffixIcon:
                                _coordinateController.text.isNotEmpty
                                    ? IconButton(
                                      icon: const Icon(Icons.clear, size: 16),
                                      onPressed: _clearCoordinateField,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    )
                                    : null,
                          ),
                          style: const TextStyle(fontSize: 13),
                          onChanged: (value) {
                            setState(() {});
                          },
                          onSubmitted: (_) => _handleGoButton(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        height: 40,
                        child: FilledButton.icon(
                          onPressed: _handleGoButton,
                          icon: const Icon(Icons.search, size: 16),
                          label: const Text('Go'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Third row: Utility buttons
                  Row(
                    children: [
                      SizedBox(
                        height: 36,
                        child: FilledButton.icon(
                          onPressed: _scheduleViewportRefresh,
                          icon: const Icon(Icons.refresh, size: 14),
                          label: const Text(
                            'Refresh',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        height: 36,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            setState(() {
                              _isFullscreenMap = true;
                            });
                          },
                          icon: const Icon(Icons.fullscreen, size: 14),
                          label: const Text(
                            'Expand',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _status,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _queryCenter,
                    initialZoom: 13,
                    onMapReady: _scheduleViewportRefresh,
                    onPositionChanged: (position, _) {
                      _currentZoom = position.zoom;
                      _scheduleViewportRefresh();
                    },
                    onLongPress: (_, latLng) {
                      setState(() {
                        _queryCenter = latLng;
                        _status =
                            'Query center set by map long-press: ${latLng.latitude.toStringAsFixed(5)}, ${latLng.longitude.toStringAsFixed(5)}';
                      });
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'dev.bb.geohistory',
                    ),
                    PolylineLayer(polylines: _buildTracePolylines()),
                    MarkerLayer(markers: _buildMarkers()),
                  ],
                ),
                Positioned(top: 8, right: 8, child: _buildTypeLegend()),
                if (_isFullscreenMap)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: FloatingActionButton.small(
                      onPressed: () {
                        setState(() {
                          _isFullscreenMap = false;
                        });
                      },
                      tooltip: 'Exit fullscreen',
                      child: const Icon(Icons.fullscreen_exit),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TraceFragment {
  const _TraceFragment({required this.type, required this.points});

  final String type;
  final List<LocationPoint> points;
}
