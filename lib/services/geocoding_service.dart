import 'package:geocoding/geocoding.dart';

class GeocodingService {
  Future<(double, double)?> geocodeAddress(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return null;
    }

    final results = await locationFromAddress(normalized);
    if (results.isEmpty) {
      return null;
    }

    return (results.first.latitude, results.first.longitude);
  }
}
