import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

class RouteMetrics {
  const RouteMetrics({
    required this.distanceKm,
    required this.etaMinutes,
  });

  final double distanceKm;
  final int etaMinutes;
}

class RouteMetricsService {
  RouteMetricsService._();

  static final RouteMetricsService instance = RouteMetricsService._();

  final Map<String, RouteMetrics?> _cache = <String, RouteMetrics?>{};
  final Map<String, Future<RouteMetrics?>> _inFlight =
      <String, Future<RouteMetrics?>>{};

  Future<RouteMetrics?> getDrivingRouteMetrics({
    required double originLatitude,
    required double originLongitude,
    required double destinationLatitude,
    required double destinationLongitude,
  }) {
    final cacheKey = _buildCacheKey(
      originLatitude: originLatitude,
      originLongitude: originLongitude,
      destinationLatitude: destinationLatitude,
      destinationLongitude: destinationLongitude,
    );

    final cached = _cache[cacheKey];
    if (cached != null || _cache.containsKey(cacheKey)) {
      return Future<RouteMetrics?>.value(cached);
    }

    final existing = _inFlight[cacheKey];
    if (existing != null) {
      return existing;
    }

    final future = _fetchDrivingRouteMetrics(
      originLatitude: originLatitude,
      originLongitude: originLongitude,
      destinationLatitude: destinationLatitude,
      destinationLongitude: destinationLongitude,
    ).then((metrics) {
      _cache[cacheKey] = metrics;
      _inFlight.remove(cacheKey);
      return metrics;
    });

    _inFlight[cacheKey] = future;
    return future;
  }

  String _buildCacheKey({
    required double originLatitude,
    required double originLongitude,
    required double destinationLatitude,
    required double destinationLongitude,
  }) {
    return '${originLatitude.toStringAsFixed(5)},${originLongitude.toStringAsFixed(5)}:'
        '${destinationLatitude.toStringAsFixed(5)},${destinationLongitude.toStringAsFixed(5)}';
  }

  Future<RouteMetrics?> _fetchDrivingRouteMetrics({
    required double originLatitude,
    required double originLongitude,
    required double destinationLatitude,
    required double destinationLongitude,
  }) async {
    try {
      final callable = FirebaseFunctions.instanceFor(
        region: 'northamerica-northeast1',
      ).httpsCallable('getRouteMetrics');
      final response = await callable.call(<String, dynamic>{
        'originLatitude': originLatitude,
        'originLongitude': originLongitude,
        'destinationLatitude': destinationLatitude,
        'destinationLongitude': destinationLongitude,
      });

      final data = Map<String, dynamic>.from(
        response.data as Map<dynamic, dynamic>,
      );
      final distanceKm = (data['distanceKm'] as num?)?.toDouble();
      final etaMinutes = (data['etaMinutes'] as num?)?.toInt();
      if (distanceKm == null || etaMinutes == null) {
        return null;
      }

      return RouteMetrics(
        distanceKm: distanceKm,
        etaMinutes: etaMinutes,
      );
    } catch (error) {
      debugPrint('Route metrics unavailable: $error');
      return null;
    }
  }
}