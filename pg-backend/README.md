# Boosstter Demo PostgreSQL Backend

Demo Express + PostgreSQL backend for managing Boosstter app data during testing.

## Temporary test login

Use HTTP Basic Auth for all `/admin/*` routes:

- Username: `demo_admin`
- Password: `BoosterDemo2026!`

These credentials are for demo testing only. Change them in `.env` before using the
backend outside a temporary test environment.

## Setup

```bash
cd pg-backend
cp .env.example .env
npm install
npm run dev
```

The backend auto-creates demo tables on startup.

Default local database URL:

```text
postgres://postgres:postgres@localhost:5432/booster_demo
```

## Health check

```bash
curl http://localhost:4000/health
```

## Example admin calls

```bash
AUTH="demo_admin:BoosterDemo2026!"

curl -u "$AUTH" http://localhost:4000/admin/dashboard

curl -u "$AUTH" -H "Content-Type: application/json" \
  -d '{"email":"customer1@boosstter.test","fullName":"Demo Customer","role":"customer","phoneNumber":"+15550001001"}' \
  http://localhost:4000/admin/users

curl -u "$AUTH" -H "Content-Type: application/json" \
  -d '{"email":"provider1@boosstter.test","fullName":"Demo Provider","role":"driver","phoneNumber":"+15550001002","isAvailable":true}' \
  http://localhost:4000/admin/users
```

Provider settings:

```bash
curl -u "$AUTH" -X PUT -H "Content-Type: application/json" \
  -d '{"providesBoost":true,"providesTow":true,"providesMechanic":true,"boostPrice":"25.00","towPrice":"75.00","mechanicPrice":"65.00","currency":"CAD","preferredPaymentProvider":"stripe"}' \
  http://localhost:4000/admin/users/PROVIDER_USER_ID/provider-settings
```

Create a request:

```bash
curl -u "$AUTH" -H "Content-Type: application/json" \
  -d '{"customerId":"CUSTOMER_USER_ID","providerId":"PROVIDER_USER_ID","serviceType":"boost","vehicleMake":"Toyota","vehicleModel":"Corolla","vehicleLabel":"Toyota Corolla","vehicleType":"regular","vehicleLocationAddress":"123 Demo St, Toronto, Canada"}' \
  http://localhost:4000/admin/requests
```

Update lifecycle stage:

```bash
curl -u "$AUTH" -X PATCH -H "Content-Type: application/json" \
  -d '{"status":"accepted"}' \
  http://localhost:4000/admin/requests/REQUEST_ID/stage
```

## Routes

- `GET /health`
- `GET /admin/dashboard`
- `GET /admin/users`
- `POST /admin/users`
- `PUT /admin/users/:userId/provider-settings`
- `GET /admin/requests`
- `POST /admin/requests`
- `PATCH /admin/requests/:id/stage`
- `GET /admin/requests/:requestId/messages`
- `POST /admin/requests/:requestId/messages`
- `POST /admin/requests/:requestId/reviews`
