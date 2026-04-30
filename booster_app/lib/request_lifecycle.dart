import 'package:cloud_firestore/cloud_firestore.dart';

enum RequestStatus {
  awaitingPayment,
  paid,
  pending,
  searching,
  accepted,
  enRoute,
  arrived,
  completed,
  cancelled,
  noBoostersAvailable,
  unknown,
}

extension RequestStatusValue on RequestStatus {
  String get value {
    switch (this) {
      case RequestStatus.awaitingPayment:
        return 'awaiting_payment';
      case RequestStatus.paid:
        return 'paid';
      case RequestStatus.pending:
        return 'pending';
      case RequestStatus.searching:
        return 'searching';
      case RequestStatus.accepted:
        return 'accepted';
      case RequestStatus.enRoute:
        return 'en_route';
      case RequestStatus.arrived:
        return 'arrived';
      case RequestStatus.completed:
        return 'completed';
      case RequestStatus.cancelled:
        return 'cancelled';
      case RequestStatus.noBoostersAvailable:
        return 'no_boosters_available';
      case RequestStatus.unknown:
        return 'unknown';
    }
  }
}

RequestStatus requestStatusFromString(String value) {
  switch (value.toLowerCase()) {
    case 'awaiting_payment':
      return RequestStatus.awaitingPayment;
    case 'paid':
      return RequestStatus.paid;
    case 'pending':
      return RequestStatus.pending;
    case 'searching':
      return RequestStatus.searching;
    case 'accepted':
      return RequestStatus.accepted;
    case 'en_route':
      return RequestStatus.enRoute;
    case 'arrived':
      return RequestStatus.arrived;
    case 'completed':
      return RequestStatus.completed;
    case 'cancelled':
      return RequestStatus.cancelled;
    case 'no_boosters_available':
      return RequestStatus.noBoostersAvailable;
    default:
      return RequestStatus.unknown;
  }
}

bool canTransitionRequestStatus(RequestStatus from, RequestStatus to) {
  if (from == RequestStatus.unknown) {
    return to != RequestStatus.unknown;
  }
  if (from == to) {
    return true;
  }

  switch (from) {
    case RequestStatus.awaitingPayment:
      return to == RequestStatus.paid || to == RequestStatus.cancelled;
    case RequestStatus.paid:
      return to == RequestStatus.pending || to == RequestStatus.cancelled;
    case RequestStatus.pending:
      return to == RequestStatus.accepted ||
          to == RequestStatus.cancelled ||
          to == RequestStatus.noBoostersAvailable;
    case RequestStatus.searching:
      return to == RequestStatus.pending || to == RequestStatus.cancelled;
    case RequestStatus.accepted:
      return to == RequestStatus.enRoute || to == RequestStatus.cancelled;
    case RequestStatus.enRoute:
      return to == RequestStatus.arrived || to == RequestStatus.cancelled;
    case RequestStatus.arrived:
      return to == RequestStatus.completed || to == RequestStatus.cancelled;
    case RequestStatus.completed:
    case RequestStatus.cancelled:
      return false;
    case RequestStatus.noBoostersAvailable:
      return to == RequestStatus.pending || to == RequestStatus.cancelled;
    case RequestStatus.unknown:
      return false;
  }
}

Map<String, dynamic> buildStatusTransitionPatch({
  required RequestStatus to,
}) {
  final at = FieldValue.serverTimestamp();
  final statusKey = '${to.value}At';
  return {
    'status': to.value,
    'statusUpdatedAt': at,
    statusKey: at,
  };
}
