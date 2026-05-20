import 'package:cloud_firestore/cloud_firestore.dart';

const String serviceTypeBoost = 'boost';
const String serviceTypeTow = 'tow';
const String serviceTypeMechanic = 'mobile_mechanic';

const String defaultPricingCurrency = 'CAD';
const String defaultPaymentProvider = 'stripe';
const List<String> supportedPaymentProviders = <String>[
  'stripe',
  'paystack',
  'card',
  'wallet',
];

const double canadianTaxRate = 0.13;
const double defaultAdminRate = 0.10;

const Map<String, int> defaultServicePriceCents = <String, int>{
  serviceTypeBoost: 2500,
  serviceTypeTow: 3000,
  serviceTypeMechanic: 3500,
};

const Map<String, String> countryToCurrency = <String, String>{
  'CA': 'CAD',
  'US': 'USD',
  'GB': 'GBP',
  'IE': 'EUR',
  'FR': 'EUR',
  'DE': 'EUR',
  'ES': 'EUR',
  'IT': 'EUR',
  'NL': 'EUR',
  'BE': 'EUR',
  'PT': 'EUR',
  'AT': 'EUR',
  'FI': 'EUR',
  'LU': 'EUR',
  'GR': 'EUR',
  'NG': 'NGN',
  'GH': 'GHS',
  'KE': 'KES',
  'ZA': 'ZAR',
};

const Map<String, String> currencySymbols = <String, String>{
  'CAD': r'$',
  'USD': r'$',
  'GBP': '£',
  'EUR': '€',
  'NGN': '₦',
  'GHS': '₵',
  'KES': 'KSh',
  'ZAR': 'R',
};

class ServicePricingBreakdown {
  const ServicePricingBreakdown({
    required this.serviceType,
    required this.serviceCents,
    required this.taxCents,
    required this.totalCents,
    required this.adminFeeCents,
    required this.providerPayoutCents,
    required this.taxRate,
    required this.adminRate,
    required this.currency,
    required this.countryCode,
    required this.paymentProvider,
  });

  final String serviceType;
  final int serviceCents;
  final int taxCents;
  final int totalCents;
  final int adminFeeCents;
  final int providerPayoutCents;
  final double taxRate;
  final double adminRate;
  final String currency;
  final String countryCode;
  final String paymentProvider;

  Map<String, dynamic> toRequestFields() {
    return <String, dynamic>{
      'serviceChargeCents': serviceCents,
      'taxCents': taxCents,
      'totalChargeCents': totalCents,
      'paymentAmount': totalCents,
      'adminFeeCents': adminFeeCents,
      'providerPayoutCents': providerPayoutCents,
      'taxRate': taxRate,
      'adminRate': adminRate,
      'currency': currency.toLowerCase(),
      'paymentCurrency': currency.toLowerCase(),
      'taxCountryCode': countryCode,
      'paymentProvider': paymentProvider,
      'supportedPaymentProviders': supportedPaymentProviders,
      'paySplit': <String, dynamic>{
        'adminPercent': (adminRate * 100).round(),
        'adminFeeCents': adminFeeCents,
        'providerPayoutCents': providerPayoutCents,
      },
    };
  }
}

String currencySymbolFor(String currency) {
  return currencySymbols[currency.toUpperCase()] ?? r'$';
}

String formatMoney(int cents, {String currency = defaultPricingCurrency}) {
  final symbol = currencySymbolFor(currency);
  return '$symbol${(cents / 100).toStringAsFixed(2)}';
}

String countryCodeFromAddress(String? address) {
  final value = (address ?? '').toLowerCase();
  if (value.contains('canada') ||
      value.contains(' ontario') ||
      value.contains(', on') ||
      value.contains(', qc') ||
      value.contains(', bc') ||
      value.contains(', ab') ||
      value.contains(', mb') ||
      value.contains(', sk') ||
      value.contains(', ns') ||
      value.contains(', nb') ||
      value.contains(', nl') ||
      value.contains(', pe')) {
    return 'CA';
  }
  if (value.contains('united states') || value.contains(' usa') || value.contains(', us')) {
    return 'US';
  }
  if (value.contains('nigeria')) return 'NG';
  if (value.contains('ghana')) return 'GH';
  if (value.contains('kenya')) return 'KE';
  if (value.contains('south africa')) return 'ZA';
  return 'CA';
}

String currencyForCountry(String countryCode) {
  return countryToCurrency[countryCode.toUpperCase()] ?? defaultPricingCurrency;
}

double taxRateForCountry(String countryCode) {
  return countryCode.toUpperCase() == 'CA' ? canadianTaxRate : 0;
}

int servicePriceFromProviderData(
  Map<String, dynamic>? providerData,
  String serviceType,
) {
  final pricing = (providerData?['providerPricingCents'] as Map<String, dynamic>?) ??
      (providerData?['providerPricingCadCents'] as Map<String, dynamic>?) ??
      <String, dynamic>{};
  return (pricing[serviceType] as num?)?.toInt() ??
      defaultServicePriceCents[serviceType] ??
      defaultServicePriceCents[serviceTypeBoost]!;
}

String providerCurrencyFromData(
  Map<String, dynamic>? providerData, {
  required String fallbackCountryCode,
}) {
  return (providerData?['providerPricingCurrency'] as String?)?.toUpperCase() ??
      currencyForCountry(fallbackCountryCode);
}

ServicePricingBreakdown buildServicePricing({
  required String serviceType,
  required int serviceCents,
  required String countryCode,
  required String currency,
  String paymentProvider = defaultPaymentProvider,
}) {
  final normalizedCurrency = currency.toUpperCase();
  final taxRate = taxRateForCountry(countryCode);
  final taxCents = (serviceCents * taxRate).round();
  final adminFeeCents = (serviceCents * defaultAdminRate).round();
  final providerPayoutCents = serviceCents - adminFeeCents;
  return ServicePricingBreakdown(
    serviceType: serviceType,
    serviceCents: serviceCents,
    taxCents: taxCents,
    totalCents: serviceCents + taxCents,
    adminFeeCents: adminFeeCents,
    providerPayoutCents: providerPayoutCents,
    taxRate: taxRate,
    adminRate: defaultAdminRate,
    currency: normalizedCurrency,
    countryCode: countryCode.toUpperCase(),
    paymentProvider: paymentProvider,
  );
}

Future<void> writeStageNotification({
  required String requestId,
  required String recipientId,
  required String audience,
  required String stage,
  required String title,
  required String body,
  Map<String, dynamic>? extra,
}) async {
  if (recipientId.isEmpty) return;
  await FirebaseFirestore.instance.collection('notifications').add({
    'requestId': requestId,
    'recipientId': recipientId,
    'audience': audience,
    'stage': stage,
    'title': title,
    'body': body,
    'isRead': false,
    'createdAt': FieldValue.serverTimestamp(),
    if (extra != null) ...extra,
  });
}
