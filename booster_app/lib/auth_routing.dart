import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'customer_screen.dart';
import 'driver_screen.dart';

const String customerRole = 'customer';
const String driverRole = 'driver';

String? normalizeRole(dynamic rawRole) {
  if (rawRole is! String) {
    return null;
  }

  final role = rawRole.trim().toLowerCase();
  if (role.isEmpty) {
    return null;
  }

  return role;
}

bool isSupportedRole(String? role) {
  return role == customerRole || role == driverRole;
}

Widget destinationForRole(String role) {
  switch (role) {
    case customerRole:
      return const CustomerScreen();
    case driverRole:
      return const DriverScreen();
    default:
      return const CustomerScreen();
  }
}

Future<String?> fetchUserRole(String uid) async {
  final snapshot =
      await FirebaseFirestore.instance.collection('users').doc(uid).get();
  if (!snapshot.exists) {
    return null;
  }

  final data = snapshot.data();
  return normalizeRole(data?['role']);
}
