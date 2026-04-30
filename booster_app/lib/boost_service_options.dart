const String serviceTypeBoost = 'boost';
const String serviceTypeTow = 'tow';

const String regularVehicleType = 'regular';
const String electricVehicleType = 'electric';

const List<String> boostPlugTypes = <String>[
  'J1772 Type 1',
  'Type 2',
  'CHAdeMO',
  'CCS Combo',
  'Tesla / NACS',
];

const String towTypeCar = 'car_tow';
const String towTypePickupVan = 'pickup_van_tow';
const String towTypeSuv = 'suv_tow';

const List<String> towServiceTypes = <String>[
  towTypeCar,
  towTypePickupVan,
  towTypeSuv,
];

const int boostServiceBaseCadCents = 2000;
const int boostServiceTaxCadCents = 260;
const int boostPaymentTotalCadCents =
    boostServiceBaseCadCents + boostServiceTaxCadCents;

const int towCarBaseCadCents = 13500;
const int towPickupVanBaseCadCents = 25000;
const int towSuvBaseCadCents = 18500;
const double defaultTaxRate = 0.13;

String towTypeLabel(String towType) {
  switch (towType) {
    case towTypeCar:
      return 'Car Tow';
    case towTypePickupVan:
      return 'Pickup Tow & Van';
    case towTypeSuv:
      return 'SUV Tow';
    default:
      return 'Tow Service';
  }
}

int towBaseAmountForType(String towType) {
  switch (towType) {
    case towTypeCar:
      return towCarBaseCadCents;
    case towTypePickupVan:
      return towPickupVanBaseCadCents;
    case towTypeSuv:
      return towSuvBaseCadCents;
    default:
      return towCarBaseCadCents;
  }
}

int taxAmountForBase(int baseAmountCents, {double taxRate = defaultTaxRate}) {
  return (baseAmountCents * taxRate).round();
}
