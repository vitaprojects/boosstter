import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'boost_service_options.dart';

const String _stripeFunctionsRegion = String.fromEnvironment(
  'STRIPE_FUNCTIONS_REGION',
  defaultValue: 'northamerica-northeast1',
);
const String _boostPaymentModeRaw = String.fromEnvironment(
  'BOOST_PAYMENT_MODE',
  defaultValue: 'mock',
);

enum BoostPaymentMode {
  stripe,
  mock,
  manual,
}

class BoostPaymentResult {
  const BoostPaymentResult({
    required this.paymentIntentId,
    required this.amount,
    required this.currency,
    required this.paymentProvider,
  });

  final String paymentIntentId;
  final int amount;
  final String currency;
  final String paymentProvider;
}

class StripePaymentService {
  StripePaymentService._();

  static final StripePaymentService instance = StripePaymentService._();

  BoostPaymentMode get paymentMode {
    switch (_boostPaymentModeRaw.toLowerCase()) {
      case 'stripe':
        return BoostPaymentMode.stripe;
      case 'manual':
        return BoostPaymentMode.manual;
      case 'mock':
      default:
        return BoostPaymentMode.mock;
    }
  }

  String get paymentModeLabel {
    switch (paymentMode) {
      case BoostPaymentMode.stripe:
        return 'Stripe';
      case BoostPaymentMode.mock:
        return 'Test Payment (No Charge)';
      case BoostPaymentMode.manual:
        return 'Manual Confirmation';
    }
  }

  String get checkoutButtonLabel {
    switch (paymentMode) {
      case BoostPaymentMode.stripe:
        return 'Continue to Stripe';
      case BoostPaymentMode.mock:
        return 'Confirm Test Payment';
      case BoostPaymentMode.manual:
        return 'Confirm Manual Payment';
    }
  }

  String get paymentInfoText {
    switch (paymentMode) {
      case BoostPaymentMode.stripe:
        return 'Secure Stripe checkout. Card entry happens in Stripe PaymentSheet.';
      case BoostPaymentMode.mock:
        return 'Test mode: no real card charge. Order will be marked paid instantly.';
      case BoostPaymentMode.manual:
        return 'Manual mode: confirm this order as paid for in-person/offline testing.';
    }
  }

  String _mockIntentId(String prefix) {
    final randomSuffix = Random().nextInt(90000) + 10000;
    return '${prefix}_${DateTime.now().millisecondsSinceEpoch}_$randomSuffix';
  }

  List<String> get _candidateRegions {
    final regions = <String>{
      _stripeFunctionsRegion,
      'us-central1',
    };
    return regions.toList(growable: false);
  }

  Future<HttpsCallableResult<dynamic>> _callCreateBoostPaymentSheet(
    Map<String, dynamic> payload,
  ) async {
    FirebaseFunctionsException? lastNotFound;

    for (final region in _candidateRegions) {
      try {
        final callable = FirebaseFunctions.instanceFor(region: region)
            .httpsCallable('createBoostPaymentSheet');
        return await callable.call(payload);
      } on FirebaseFunctionsException catch (error) {
        if (error.code == 'not-found') {
          lastNotFound = error;
          continue;
        }
        throw Exception(
          'Payment backend error (${error.code}): '
          '${error.message ?? 'Please try again.'}',
        );
      }
    }

    if (lastNotFound != null) {
      throw Exception(
        'Payment backend is not deployed yet (createBoostPaymentSheet). '
        'Please deploy Firebase Functions and try again.',
      );
    }

    throw Exception('Payment backend is unavailable. Please try again.');
  }

  Future<BoostPaymentResult> payForBoostRequest({
    required String requestId,
    required int amountInCents,
  }) async {
    switch (paymentMode) {
      case BoostPaymentMode.mock:
        return BoostPaymentResult(
          paymentIntentId: _mockIntentId('mock_pi'),
          amount: amountInCents,
          currency: 'cad',
          paymentProvider: 'mock',
        );
      case BoostPaymentMode.manual:
        return BoostPaymentResult(
          paymentIntentId: _mockIntentId('manual_pi'),
          amount: amountInCents,
          currency: 'cad',
          paymentProvider: 'manual',
        );
      case BoostPaymentMode.stripe:
        break;
    }

    final response = await _callCreateBoostPaymentSheet(<String, dynamic>{
      'requestId': requestId,
      'amount': amountInCents,
      'currency': 'cad',
      'email': FirebaseAuth.instance.currentUser?.email,
    });

    final data = Map<String, dynamic>.from(response.data as Map<dynamic, dynamic>);
    final publishableKey = data['publishableKey'] as String? ?? '';
    final paymentIntentClientSecret =
        data['paymentIntentClientSecret'] as String? ?? '';
    final customerId = data['customerId'] as String? ?? '';
    final customerEphemeralKeySecret =
        data['customerEphemeralKeySecret'] as String? ?? '';
    final paymentIntentId = data['paymentIntentId'] as String? ?? '';
    final currency = (data['currency'] as String? ?? 'cad').toLowerCase();

    if (publishableKey.isEmpty ||
        paymentIntentClientSecret.isEmpty ||
        customerId.isEmpty ||
        customerEphemeralKeySecret.isEmpty ||
        paymentIntentId.isEmpty) {
      throw Exception('Stripe checkout is not fully configured yet.');
    }

    Stripe.publishableKey = publishableKey;
    await Stripe.instance.applySettings();

    try {
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          merchantDisplayName: 'Booster',
          customerId: customerId,
          customerEphemeralKeySecret: customerEphemeralKeySecret,
          paymentIntentClientSecret: paymentIntentClientSecret,
          style: ThemeMode.dark,
          allowsDelayedPaymentMethods: false,
          billingDetails: BillingDetails(
            email: FirebaseAuth.instance.currentUser?.email,
          ),
        ),
      );

      await Stripe.instance.presentPaymentSheet();
      return BoostPaymentResult(
        paymentIntentId: paymentIntentId,
        amount: amountInCents,
        currency: currency,
        paymentProvider: 'stripe',
      );
    } on StripeException catch (error) {
      final localizedMessage = error.error.localizedMessage;
      if (localizedMessage == null || localizedMessage.isEmpty) {
        throw Exception('Stripe checkout was cancelled.');
      }
      throw Exception(localizedMessage);
    }
  }
}