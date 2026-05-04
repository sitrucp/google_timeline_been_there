// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:google_timeline_been_there/models/location_point.dart';

void main() {
  test('LocationPoint serializes to/from map', () {
    const point = LocationPoint(
      id: 42,
      timestamp: 1710000000,
      lat: 40.7128,
      lon: -74.006,
      type: 'visit',
      activityName: 'Walking',
    );

    final map = point.toMap();
    final decoded = LocationPoint.fromMap(map);

    expect(decoded.id, 42);
    expect(decoded.timestamp, 1710000000);
    expect(decoded.lat, 40.7128);
    expect(decoded.lon, -74.006);
    expect(decoded.type, 'visit');
    expect(decoded.activityName, 'Walking');
  });
}
