/// Project flow checkpoint for Booster app.
///
/// Purpose:
/// - Keep implemented product rules in source control.
/// - Prevent rework when iterating on screens and business logic.
///
/// This file is intentionally not wired to runtime code yet.
/// It serves as a stable in-repo reference for current behavior.
class ProjectFlowCheckpoint {
  static const String version = '2026-05-08';

  static const List<String> completedFlows = <String>[
    'Post-login Explainer screen before main screen',
    'Main hub with 3 services: Battery Boost, Tow, Mobile Mechanic',
    'Boost Step 1: vehicle type (Regular or Electric)',
    'Boost Step 1: EV plug type required for Electric',
    'Boost location sheet: current location preview address shown before save',
    'Tow Step 1: vehicle dropdown + manual vehicle fallback',
    'Tow Step 2: current location or manual address',
    'Tow Step 3: reason dropdown + optional notes',
    'Tow payment confirmation shown before order placement',
    'Provider acceptance updates include ETA + distance',
    'In-app logo lockup uses car mark + GET BOOSTED',
  ];

  static const List<String> evPlugTypes = <String>[
    'J1772 Type 1',
    'Type 2',
    'CHAdeMO',
    'CCS Combo',
    'Tesla / NACS',
  ];

  static const List<String> towReasons = <String>[
    'Mechanical breakdown',
    'Flat tire',
    'Accident',
    'Out of fuel',
    "Vehicle won't start",
    'Vehicle stuck',
    'Other',
  ];

  static const int towServiceCadCents = 2000; // $20.00
  static const int firstUseYearlySubscriptionCadCents = 900; // $9.00
  static const double canadianTaxRate = 0.13; // 13%

  static const String pricingRule =
      'Tow total = tow service + tax(13% for Canadian users) + first-use yearly subscription (\$9 once)';

  static const List<String> nextPlanned = <String>[
    'Tow final dispatch polish and provider queue UX',
    'Mobile Mechanic dedicated multi-step request flow',
    'Shared request lifecycle UI consistency across all services',
  ];
}
