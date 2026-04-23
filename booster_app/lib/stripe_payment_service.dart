import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

const int boostPaymentTotalCadCents = 2500;
const String _stripeFunctionsRegion = String.fromEnvironment(
  'STRIPE_FUNCTIONS_REGION',
  defaultValue: 'northamerica-northeast1',
);

class BoostPaymentResult {
  const BoostPaymentResult({
    required this.paymentIntentId,
    required this.amount,
    required this.currency,
  });

  final String paymentIntentId;
  final int amount;
  final String currency;
}

class StripePaymentService {
  StripePaymentService._();

  static final StripePaymentService instance = StripePaymentService._();

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: _stripeFunctionsRegion);

  Future<BoostPaymentResult> payForBoostRequest({
    required String requestId,
    required int amountInCents,
  }) async {
    final callable = _functions.httpsCallable('createBoostPaymentSheet');
    final response = await callable.call(<String, dynamic>{
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