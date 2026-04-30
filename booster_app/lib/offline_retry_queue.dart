import 'dart:async';

class OfflineRetryQueue {
  OfflineRetryQueue._();

  static final OfflineRetryQueue instance = OfflineRetryQueue._();

  final Map<String, Future<void> Function()> _pending =
      <String, Future<void> Function()>{};
  Timer? _retryTimer;
  bool _isDraining = false;

  int get pendingCount => _pending.length;

  void enqueue({
    required String key,
    required Future<void> Function() action,
  }) {
    _pending[key] = action;
    _ensureRetryTimer();
    unawaited(_drain());
  }

  void _ensureRetryTimer() {
    _retryTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (_pending.isNotEmpty) {
        unawaited(_drain());
      }
    });
  }

  Future<void> _drain() async {
    if (_isDraining || _pending.isEmpty) {
      return;
    }

    _isDraining = true;
    try {
      final keys = _pending.keys.toList(growable: false);
      for (final key in keys) {
        final action = _pending[key];
        if (action == null) {
          continue;
        }
        try {
          await action();
          _pending.remove(key);
        } catch (_) {
          // Keep the action queued for the next retry window.
        }
      }
    } finally {
      _isDraining = false;
      if (_pending.isEmpty) {
        _retryTimer?.cancel();
        _retryTimer = null;
      }
    }
  }
}
