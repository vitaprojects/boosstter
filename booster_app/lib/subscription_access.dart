import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'paywall_screen.dart';
import 'region_policy.dart';

Future<bool> ensureSubscribedForAction(
  BuildContext context, {
  required String purpose,
}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    return false;
  }

  final snapshot = await FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .get();
  final data = snapshot.data() ?? <String, dynamic>{};

  final regionCode = data['regionCode']?.toString();
  final region = findSupportedRegion(regionCode);
  if (regionCode != null && region == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Booster is currently available only in Canada, United States, United Kingdom, and Nigeria.',
          ),
        ),
      );
    }
    return false;
  }

  final isSubscribed = data['isSubscribed'] == true;
  if (isSubscribed) {
    return true;
  }

  if (!context.mounted) {
    return false;
  }

  final result = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => PaywallScreen(purpose: purpose),
    ),
  );

  return result == true;
}
