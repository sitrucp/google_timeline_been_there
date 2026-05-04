import 'package:flutter/material.dart';

import 'views/geo_history_page.dart';

void main() {
  runApp(const GeoHistoryApp());
}

class GeoHistoryApp extends StatelessWidget {
  const GeoHistoryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoHistory',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1D4E89)),
      ),
      home: const GeoHistoryPage(),
    );
  }
}
