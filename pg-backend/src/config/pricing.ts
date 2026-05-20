export const ADMIN_RATE = 0.1;
export const CANADIAN_TAX_RATE = 0.13;

export function taxRateForCountry(countryCode = "CA") {
  return countryCode.toUpperCase() === "CA" ? CANADIAN_TAX_RATE : 0;
}

export function centsFromDecimal(value: unknown, fallback: number) {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return Math.round(value * 100);
  }

  if (typeof value === "string") {
    const parsed = Number(value.trim());
    if (Number.isFinite(parsed) && parsed > 0) {
      return Math.round(parsed * 100);
    }
  }

  return fallback;
}

export function buildChargeBreakdown(serviceCents: number, countryCode = "CA") {
  const taxRate = taxRateForCountry(countryCode);
  const taxCents = Math.round(serviceCents * taxRate);
  const adminFeeCents = Math.round(serviceCents * ADMIN_RATE);
  const providerPayoutCents = serviceCents - adminFeeCents;

  return {
    serviceChargeCents: serviceCents,
    taxCents,
    totalChargeCents: serviceCents + taxCents,
    adminFeeCents,
    providerPayoutCents,
    adminRate: ADMIN_RATE,
    taxRate,
  };
}
