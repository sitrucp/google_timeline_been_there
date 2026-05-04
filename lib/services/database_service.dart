import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/location_point.dart';

class DatabaseService {
  DatabaseService._();

  static final DatabaseService instance = DatabaseService._();

  static const _dbName = 'geohistory.db';
  static const _tableName = 'locations';

  Database? _db;

  Future<Database> get database async {
    if (_db != null) {
      return _db!;
    }

    final documentsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documentsDir.path, _dbName);
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE $_tableName(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp INTEGER NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            type TEXT NOT NULL,
            activity_name TEXT
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_locations_lat_lon ON $_tableName(lat, lon)',
        );
        await db.execute(
          'CREATE INDEX idx_locations_timestamp ON $_tableName(timestamp DESC)',
        );
      },
    );
    return _db!;
  }

  Future<void> clearLocations() async {
    final db = await database;
    await db.delete(_tableName);
  }

  Future<void> insertBatch(List<LocationPoint> points) async {
    if (points.isEmpty) {
      return;
    }

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final point in points) {
        batch.insert(
          _tableName,
          point.toMap()..remove('id'),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<LocationPoint>> queryByBoundingBox({
    required double centerLat,
    required double centerLon,
    required double radiusKm,
  }) async {
    final latDelta = 0.009 * radiusKm;
    final cosLat = math.cos(centerLat * math.pi / 180.0).abs();
    final safeCosLat = cosLat < 0.0001 ? 0.0001 : cosLat;
    final lonDelta = (0.009 / safeCosLat) * radiusKm;

    return queryByRadiusDegrees(
      centerLat: centerLat,
      centerLon: centerLon,
      latDelta: latDelta,
      lonDelta: lonDelta,
    );
  }

  Future<List<LocationPoint>> queryByRadiusDegrees({
    required double centerLat,
    required double centerLon,
    required double latDelta,
    required double lonDelta,
  }) async {
    final db = await database;
    final minLat = centerLat - latDelta;
    final maxLat = centerLat + latDelta;
    final minLon = centerLon - lonDelta;
    final maxLon = centerLon + lonDelta;

    final rows = await db.rawQuery(
      '''
      SELECT * FROM $_tableName
      WHERE lat BETWEEN ? AND ?
      AND lon BETWEEN ? AND ?
      ORDER BY timestamp DESC
      ''',
      [minLat, maxLat, minLon, maxLon],
    );

    return rows.map(LocationPoint.fromMap).toList(growable: false);
  }

  Future<List<LocationPoint>> queryWithinBounds({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
    int limit = 40000,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT * FROM $_tableName
      WHERE lat BETWEEN ? AND ?
      AND lon BETWEEN ? AND ?
      ORDER BY timestamp ASC
      LIMIT ?
      ''',
      [minLat, maxLat, minLon, maxLon, limit],
    );

    return rows.map(LocationPoint.fromMap).toList(growable: false);
  }

  Future<List<LocationPoint>> getRecentPoints({int limit = 5000}) async {
    final db = await database;
    final rows = await db.query(
      _tableName,
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows.map(LocationPoint.fromMap).toList(growable: false);
  }
}
