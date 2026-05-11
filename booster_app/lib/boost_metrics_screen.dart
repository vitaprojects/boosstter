import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class BoostMetricsScreen extends StatefulWidget {
  const BoostMetricsScreen({super.key});

  @override
  State<BoostMetricsScreen> createState() => _BoostMetricsScreenState();
}

class _BoostMetricsScreenState extends State<BoostMetricsScreen> {
  static const List<int> _dayOptions = <int>[7, 30, 90];

  int _selectedDays = 30;
  bool _isLoading = true;
  String? _error;

  _BoostMetricsSummary _summary = _BoostMetricsSummary.empty();
  List<_BoostMetricsDayRow> _dailyRows = <_BoostMetricsDayRow>[];

  @override
  void initState() {
    super.initState();
    _loadMetrics();
  }

  Future<void> _loadMetrics() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final startDate = DateTime.now().toUtc().subtract(Duration(days: _selectedDays));
      final snapshot = await FirebaseFirestore.instance
          .collection('analytics_events')
          .where('serviceType', isEqualTo: 'boost')
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate))
          .orderBy('createdAt', descending: false)
          .get();

      final dayBuckets = <String, _BoostMetricsCounter>{};
      final totals = _BoostMetricsCounter.empty();

      for (var i = _selectedDays - 1; i >= 0; i--) {
        final day = DateTime.now().toUtc().subtract(Duration(days: i));
        final key = _toDayKey(day);
        dayBuckets[key] = _BoostMetricsCounter.empty();
      }

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final createdAtTimestamp = data['createdAt'] as Timestamp?;
        final createdAt = createdAtTimestamp?.toDate().toUtc();
        if (createdAt == null) {
          continue;
        }

        final eventName = (data['eventName'] ?? '').toString();
        final details = (data['details'] as Map<String, dynamic>?) ?? <String, dynamic>{};

        final key = _toDayKey(createdAt);
        dayBuckets.putIfAbsent(key, _BoostMetricsCounter.empty);

        _applyEvent(dayBuckets[key]!, eventName, details);
        _applyEvent(totals, eventName, details);
      }

      final rows = dayBuckets.entries
          .map((entry) => _BoostMetricsDayRow.fromCounter(entry.key, entry.value))
          .toList();

      if (!mounted) return;
      setState(() {
        _summary = _BoostMetricsSummary.fromCounter(
          totals,
          totalEventsScanned: snapshot.docs.length,
        );
        _dailyRows = rows;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  String _toDayKey(DateTime date) {
    final d = date.toUtc();
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$month-$day';
  }

  void _applyEvent(
    _BoostMetricsCounter counter,
    String eventName,
    Map<String, dynamic> details,
  ) {
    switch (eventName) {
      case 'provider_search_completed':
        counter.providerSearchCompleted += 1;
        final providerCount = (details['providerCount'] as num?)?.toInt() ?? 0;
        if (providerCount <= 0) {
          counter.providerSearchNoProvider += 1;
        }
        break;
      case 'search_cycle_timeout':
        counter.searchCycleTimeout += 1;
        break;
      case 'request_resent':
        counter.resendSuccess += 1;
        break;
      case 'request_resend_failed':
        counter.resendFailed += 1;
        break;
      case 'resend_queue_empty':
        counter.resendQueueEmpty += 1;
        break;
      case 'resend_search_no_providers':
        counter.resendNoProviders += 1;
        break;
      case 'request_cancelled_by_customer':
        counter.cancelledByCustomer += 1;
        break;
      case 'request_cancel_failed':
        counter.cancelFailed += 1;
        break;
      case 'boost_request_dispatched':
        counter.dispatchSuccess += 1;
        break;
      case 'boost_request_dispatch_failed':
        counter.dispatchFailed += 1;
        break;
      default:
        break;
    }
  }

  String _percent(int numerator, int denominator) {
    if (denominator == 0) {
      return '0.0%';
    }
    return '${((numerator / denominator) * 100).toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final resendAttempts = summary.resendAttempts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Boost Metrics'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : _loadMetrics,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'Could not load metrics:\n$_error',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadMetrics,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Wrap(
                          spacing: 8,
                          children: _dayOptions.map((days) {
                            return ChoiceChip(
                              label: Text('Last $days days'),
                              selected: _selectedDays == days,
                              onSelected: (selected) {
                                if (!selected) return;
                                setState(() => _selectedDays = days);
                                _loadMetrics();
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 14),
                        _MetricCard(
                          title: 'Dispatch Success',
                          value: summary.dispatchSuccess.toString(),
                          subtitle: 'Failed: ${summary.dispatchFailed}',
                          accent: const Color(0xFF16A34A),
                        ),
                        _MetricCard(
                          title: 'Search Timeouts',
                          value: summary.searchCycleTimeout.toString(),
                          subtitle: 'No-provider searches: ${summary.providerSearchNoProvider}',
                          accent: const Color(0xFFEA580C),
                        ),
                        _MetricCard(
                          title: 'Resend Success',
                          value: summary.resendSuccess.toString(),
                          subtitle:
                              'Attempts: $resendAttempts • Rate: ${_percent(summary.resendSuccess, resendAttempts)}',
                          accent: const Color(0xFF2563EB),
                        ),
                        _MetricCard(
                          title: 'Customer Cancellations',
                          value: summary.cancelledByCustomer.toString(),
                          subtitle: 'Cancel failed writes: ${summary.cancelFailed}',
                          accent: const Color(0xFF7C3AED),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Daily Funnel',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        ..._dailyRows.map((row) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFE2E4ED)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  row.day,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Dispatch ${row.dispatchSuccess} | Timeout ${row.searchCycleTimeout} | Resend ${row.resendSuccess}/${row.resendAttempts} | Cancel ${row.cancelledByCustomer}',
                                  style: const TextStyle(color: Color(0xFF475569)),
                                ),
                              ],
                            ),
                          );
                        }),
                        const SizedBox(height: 8),
                        Text(
                          'Events scanned: ${summary.totalEventsScanned}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: const Color(0xFF6B7280)),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.accent,
  });

  final String title;
  final String value;
  final String subtitle;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.analytics_outlined, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 24,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BoostMetricsSummary {
  const _BoostMetricsSummary({
    required this.dispatchSuccess,
    required this.dispatchFailed,
    required this.searchCycleTimeout,
    required this.resendSuccess,
    required this.resendFailed,
    required this.resendQueueEmpty,
    required this.resendNoProviders,
    required this.cancelledByCustomer,
    required this.cancelFailed,
    required this.providerSearchNoProvider,
    required this.totalEventsScanned,
  });

  final int dispatchSuccess;
  final int dispatchFailed;
  final int searchCycleTimeout;
  final int resendSuccess;
  final int resendFailed;
  final int resendQueueEmpty;
  final int resendNoProviders;
  final int cancelledByCustomer;
  final int cancelFailed;
  final int providerSearchNoProvider;
  final int totalEventsScanned;

  int get resendAttempts =>
      resendSuccess + resendFailed + resendQueueEmpty + resendNoProviders;

  factory _BoostMetricsSummary.empty() {
    return const _BoostMetricsSummary(
      dispatchSuccess: 0,
      dispatchFailed: 0,
      searchCycleTimeout: 0,
      resendSuccess: 0,
      resendFailed: 0,
      resendQueueEmpty: 0,
      resendNoProviders: 0,
      cancelledByCustomer: 0,
      cancelFailed: 0,
      providerSearchNoProvider: 0,
      totalEventsScanned: 0,
    );
  }

  factory _BoostMetricsSummary.fromCounter(
    _BoostMetricsCounter c, {
    required int totalEventsScanned,
  }) {
    return _BoostMetricsSummary(
      dispatchSuccess: c.dispatchSuccess,
      dispatchFailed: c.dispatchFailed,
      searchCycleTimeout: c.searchCycleTimeout,
      resendSuccess: c.resendSuccess,
      resendFailed: c.resendFailed,
      resendQueueEmpty: c.resendQueueEmpty,
      resendNoProviders: c.resendNoProviders,
      cancelledByCustomer: c.cancelledByCustomer,
      cancelFailed: c.cancelFailed,
      providerSearchNoProvider: c.providerSearchNoProvider,
      totalEventsScanned: totalEventsScanned,
    );
  }
}

class _BoostMetricsCounter {
  _BoostMetricsCounter({
    required this.providerSearchCompleted,
    required this.providerSearchNoProvider,
    required this.searchCycleTimeout,
    required this.resendSuccess,
    required this.resendFailed,
    required this.resendQueueEmpty,
    required this.resendNoProviders,
    required this.cancelledByCustomer,
    required this.cancelFailed,
    required this.dispatchSuccess,
    required this.dispatchFailed,
  });

  int providerSearchCompleted;
  int providerSearchNoProvider;
  int searchCycleTimeout;
  int resendSuccess;
  int resendFailed;
  int resendQueueEmpty;
  int resendNoProviders;
  int cancelledByCustomer;
  int cancelFailed;
  int dispatchSuccess;
  int dispatchFailed;

  factory _BoostMetricsCounter.empty() {
    return _BoostMetricsCounter(
      providerSearchCompleted: 0,
      providerSearchNoProvider: 0,
      searchCycleTimeout: 0,
      resendSuccess: 0,
      resendFailed: 0,
      resendQueueEmpty: 0,
      resendNoProviders: 0,
      cancelledByCustomer: 0,
      cancelFailed: 0,
      dispatchSuccess: 0,
      dispatchFailed: 0,
    );
  }
}

class _BoostMetricsDayRow {
  const _BoostMetricsDayRow({
    required this.day,
    required this.dispatchSuccess,
    required this.searchCycleTimeout,
    required this.resendSuccess,
    required this.resendAttempts,
    required this.cancelledByCustomer,
  });

  final String day;
  final int dispatchSuccess;
  final int searchCycleTimeout;
  final int resendSuccess;
  final int resendAttempts;
  final int cancelledByCustomer;

  factory _BoostMetricsDayRow.fromCounter(String day, _BoostMetricsCounter c) {
    return _BoostMetricsDayRow(
      day: day,
      dispatchSuccess: c.dispatchSuccess,
      searchCycleTimeout: c.searchCycleTimeout,
      resendSuccess: c.resendSuccess,
      resendAttempts:
          c.resendSuccess + c.resendFailed + c.resendQueueEmpty + c.resendNoProviders,
      cancelledByCustomer: c.cancelledByCustomer,
    );
  }
}
