class SupportedRegion {
  const SupportedRegion({
    required this.code,
    required this.name,
    required this.currencyCode,
    required this.taxRate,
  });

  final String code;
  final String name;
  final String currencyCode;
  final double taxRate;
}

const List<SupportedRegion> supportedRegions = <SupportedRegion>[
  SupportedRegion(
    code: 'CA',
    name: 'Canada',
    currencyCode: 'CAD',
    taxRate: 0.13,
  ),
  SupportedRegion(
    code: 'US',
    name: 'United States',
    currencyCode: 'USD',
    taxRate: 0.07,
  ),
  SupportedRegion(
    code: 'UK',
    name: 'United Kingdom',
    currencyCode: 'GBP',
    taxRate: 0.20,
  ),
  SupportedRegion(
    code: 'NG',
    name: 'Nigeria',
    currencyCode: 'NGN',
    taxRate: 0.075,
  ),
];

const SupportedRegion defaultSupportedRegion = SupportedRegion(
  code: 'CA',
  name: 'Canada',
  currencyCode: 'CAD',
  taxRate: 0.13,
);

SupportedRegion? findSupportedRegion(String? code) {
  if (code == null || code.trim().isEmpty) {
    return null;
  }
  final normalized = code.trim().toUpperCase();
  for (final region in supportedRegions) {
    if (region.code == normalized) {
      return region;
    }
  }
  return null;
}

SupportedRegion resolveSupportedRegion(String? code) {
  return findSupportedRegion(code) ?? defaultSupportedRegion;
}

int taxAmountForRegion(int baseAmountCents, SupportedRegion region) {
  return (baseAmountCents * region.taxRate).round();
}
