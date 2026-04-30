const admin = require('firebase-admin');
const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {defineSecret} = require('firebase-functions/params');
const Stripe = require('stripe');

admin.initializeApp();

const stripeSecretKey = defineSecret('STRIPE_SECRET_KEY');
const stripePublishableKey = defineSecret('STRIPE_PUBLISHABLE_KEY');
const googleMapsRoutesApiKey = defineSecret('GOOGLE_MAPS_ROUTES_API_KEY');

function parseDurationSeconds(value) {
  if (typeof value !== 'string') {
    return null;
  }

  const match = /^([0-9]+(?:\.[0-9]+)?)s$/.exec(value.trim());
  if (!match) {
    return null;
  }

  const seconds = Number(match[1]);
  return Number.isFinite(seconds) ? Math.ceil(seconds) : null;
}

exports.createBoostPaymentSheet = onCall(
  {
    region: 'northamerica-northeast1',
    secrets: [stripeSecretKey, stripePublishableKey],
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Sign in before making a payment.');
    }

    const amount = Number(request.data?.amount);
    const currency = String(request.data?.currency || 'cad').toLowerCase();
    const requestId = String(request.data?.requestId || '');
    const email = String(request.data?.email || '');

    if (!Number.isFinite(amount) || amount < 100) {
      throw new HttpsError('invalid-argument', 'Payment amount is invalid.');
    }

    if (!requestId) {
      throw new HttpsError('invalid-argument', 'Request id is required.');
    }

    const stripe = new Stripe(stripeSecretKey.value(), {
      apiVersion: '2024-06-20',
    });

    const requestRef = admin.firestore().collection('requests').doc(requestId);
    const requestSnap = await requestRef.get();
    if (!requestSnap.exists) {
      throw new HttpsError('not-found', 'Boost request was not found.');
    }

    const boostRequest = requestSnap.data() || {};
    if (boostRequest.customerId !== request.auth.uid) {
      throw new HttpsError('permission-denied', 'You can only pay for your own request.');
    }

    if (boostRequest.status !== 'awaiting_payment') {
      throw new HttpsError('failed-precondition', 'This request is not ready for payment.');
    }

    const userRef = admin.firestore().collection('users').doc(request.auth.uid);
    const userSnap = await userRef.get();
    const userData = userSnap.data() || {};

    let customerId = userData.stripeCustomerId;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: email || undefined,
        metadata: {
          firebaseUid: request.auth.uid,
        },
      });
      customerId = customer.id;
      await userRef.set(
        {
          stripeCustomerId: customerId,
        },
        {merge: true},
      );
    }

    const ephemeralKey = await stripe.ephemeralKeys.create(
      {customer: customerId},
      {apiVersion: '2024-06-20'},
    );

    const paymentIntent = await stripe.paymentIntents.create({
      amount,
      currency,
      customer: customerId,
      automatic_payment_methods: {
        enabled: true,
        allow_redirects: 'never',
      },
      metadata: {
        requestId,
        customerId: request.auth.uid,
        driverId: String(boostRequest.driverId || ''),
      },
    });

    await requestRef.set(
      {
        paymentAmount: amount,
        paymentCurrency: currency,
        paymentIntentId: paymentIntent.id,
        paymentProvider: 'stripe',
        paymentStatus: 'requires_payment_method',
      },
      {merge: true},
    );

    return {
      publishableKey: stripePublishableKey.value(),
      paymentIntentClientSecret: paymentIntent.client_secret,
      customerId,
      customerEphemeralKeySecret: ephemeralKey.secret,
      paymentIntentId: paymentIntent.id,
      currency,
    };
  },
);

function haversineKm(lat1, lon1, lat2, lon2) {
  const toRad = (v) => (v * Math.PI) / 180;
  const earthRadiusKm = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) *
      Math.cos(toRad(lat2)) *
      Math.sin(dLon / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return earthRadiusKm * c;
}

exports.getRouteMetrics = onCall(
  {
    region: 'northamerica-northeast1',
    secrets: [googleMapsRoutesApiKey],
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Sign in before requesting route metrics.');
    }

    const originLatitude = Number(request.data?.originLatitude);
    const originLongitude = Number(request.data?.originLongitude);
    const destinationLatitude = Number(request.data?.destinationLatitude);
    const destinationLongitude = Number(request.data?.destinationLongitude);

    if (!Number.isFinite(originLatitude) || !Number.isFinite(originLongitude)) {
      throw new HttpsError('invalid-argument', 'Origin coordinates are required.');
    }

    if (!Number.isFinite(destinationLatitude) || !Number.isFinite(destinationLongitude)) {
      throw new HttpsError('invalid-argument', 'Destination coordinates are required.');
    }

    const response = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': googleMapsRoutesApiKey.value(),
        'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters',
      },
      body: JSON.stringify({
        origin: {
          location: {
            latLng: {
              latitude: originLatitude,
              longitude: originLongitude,
            },
          },
        },
        destination: {
          location: {
            latLng: {
              latitude: destinationLatitude,
              longitude: destinationLongitude,
            },
          },
        },
        travelMode: 'DRIVE',
        routingPreference: 'TRAFFIC_AWARE',
        computeAlternativeRoutes: false,
        languageCode: 'en-US',
        units: 'METRIC',
      }),
    });

    if (!response.ok) {
      const errorBody = await response.text();
      console.error('Routes API failed', errorBody);
      throw new HttpsError('internal', 'Could not compute route metrics.');
    }

    const payload = await response.json();
    const route = Array.isArray(payload.routes) ? payload.routes[0] : null;
    const distanceMeters = Number(route?.distanceMeters);
    const durationSeconds = parseDurationSeconds(route?.duration);

    if (!route || !Number.isFinite(distanceMeters) || durationSeconds == null) {
      throw new HttpsError('failed-precondition', 'No route was available for this trip.');
    }

    return {
      distanceKm: distanceMeters / 1000,
      etaMinutes: Math.max(1, Math.ceil(durationSeconds / 60)),
    };
  },
);

exports.dispatchBoosterNotifications = onCall(
  {
    region: 'northamerica-northeast1',
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'Sign in before dispatching requests.');
    }

    const requestId = String(request.data?.requestId || '');
    if (!requestId) {
      throw new HttpsError('invalid-argument', 'Request id is required.');
    }

    const requestRef = admin.firestore().collection('requests').doc(requestId);
    const requestSnap = await requestRef.get();
    if (!requestSnap.exists) {
      throw new HttpsError('not-found', 'Boost request was not found.');
    }

    const boostRequest = requestSnap.data() || {};
    if (boostRequest.customerId !== request.auth.uid) {
      throw new HttpsError('permission-denied', 'You can only dispatch your own request.');
    }

    if (boostRequest.status !== 'paid') {
      throw new HttpsError('failed-precondition', 'Payment must be completed before dispatch.');
    }

    const pickupLat = Number(boostRequest.pickupLatitude);
    const pickupLng = Number(boostRequest.pickupLongitude);
    const serviceType = String(boostRequest.serviceType || 'boost');
    const vehicleType = String(boostRequest.vehicleType || '');
    const plugType = boostRequest.plugType ? String(boostRequest.plugType) : null;
    const towType = boostRequest.towType ? String(boostRequest.towType) : null;

    if (!Number.isFinite(pickupLat) || !Number.isFinite(pickupLng)) {
      throw new HttpsError('failed-precondition', 'Pickup location is missing.');
    }

    if (serviceType === 'boost' && !vehicleType) {
      throw new HttpsError('failed-precondition', 'Boost vehicle details are missing.');
    }

    if (serviceType === 'tow' && !towType) {
      throw new HttpsError('failed-precondition', 'Tow service details are missing.');
    }

    const driversSnap = await admin.firestore()
      .collection('users')
      .where('role', '==', 'driver')
      .where('isAvailable', '==', true)
      .get();

    const eligibleDrivers = [];
    for (const doc of driversSnap.docs) {
      const data = doc.data() || {};
      const offeredServiceTypes = Array.isArray(data.offeredServiceTypes) && data.offeredServiceTypes.length > 0
        ? data.offeredServiceTypes.map((item) => String(item))
        : ['boost'];
      const offeredVehicleType = String(data.offeredVehicleType || '');
      const offeredPlugType = data.offeredPlugType ? String(data.offeredPlugType) : null;
      const offeredTowTypes = Array.isArray(data.offeredTowTypes)
        ? data.offeredTowTypes.map((item) => String(item))
        : [];
      const token = String(data.fcmToken || '');
      const lat = Number(data.latitude);
      const lng = Number(data.longitude);

      if (!token || !Number.isFinite(lat) || !Number.isFinite(lng)) {
        continue;
      }

      if (!offeredServiceTypes.includes(serviceType)) {
        continue;
      }

      if (serviceType === 'boost') {
        if (offeredVehicleType !== vehicleType) {
          continue;
        }

        if (vehicleType === 'electric' && offeredPlugType !== plugType) {
          continue;
        }
      }

      if (serviceType === 'tow' && !offeredTowTypes.includes(towType)) {
        continue;
      }

      const distanceKm = haversineKm(pickupLat, pickupLng, lat, lng);
      const etaMinutes = Math.max(1, Math.ceil((distanceKm / 40) * 60));

      eligibleDrivers.push({
        uid: doc.id,
        token,
        distanceKm,
        etaMinutes,
      });
    }

    eligibleDrivers.sort((a, b) => a.distanceKm - b.distanceKm);
    const targets = eligibleDrivers.slice(0, 20);

    if (targets.length === 0) {
      await requestRef.set(
        {
          status: 'no_boosters_available',
          notifiedDriverIds: [],
          dispatchAttemptedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        {merge: true},
      );
      return {
        notifiedCount: 0,
      };
    }

    let notifiedCount = 0;
    const notifiedDriverIds = [];
    const failedErrorCodes = [];
    const invalidTokenDriverIds = [];
    for (const driver of targets) {
      try {
        await admin.messaging().send({
          token: driver.token,
          notification: {
            title: serviceType === 'tow' ? 'New Tow Request' : 'New Booster Request',
            body: serviceType === 'tow'
              ? `Tow request ${driver.distanceKm.toFixed(1)} km away.`
              : `Customer needs help ${driver.distanceKm.toFixed(1)} km away.`,
          },
          android: {
            priority: 'high',
            notification: {
              sound: 'default',
            },
          },
          apns: {
            payload: {
              aps: {
                sound: 'default',
              },
            },
          },
          data: {
            type: 'booster_request',
            requestId,
            serviceType,
            towType: towType || '',
            vehicleType,
            etaMinutes: String(driver.etaMinutes),
          },
        });
        notifiedCount += 1;
        notifiedDriverIds.push(driver.uid);
      } catch (error) {
        const errorCode = String(error?.code || 'unknown');
        failedErrorCodes.push(errorCode);
        if (
          errorCode === 'messaging/registration-token-not-registered' ||
          errorCode === 'messaging/invalid-registration-token'
        ) {
          invalidTokenDriverIds.push(driver.uid);
        }
      }
    }

    if (invalidTokenDriverIds.length > 0) {
      const db = admin.firestore();
      const batch = db.batch();
      for (const uid of invalidTokenDriverIds) {
        const userRef = db.collection('users').doc(uid);
        batch.set(
          userRef,
          {
            fcmToken: admin.firestore.FieldValue.delete(),
            fcmTokenInvalidAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          {merge: true},
        );
      }
      await batch.commit();
    }

    await requestRef.set(
      {
        status: notifiedCount > 0 ? 'pending' : 'no_boosters_available',
        notifiedDriverIds,
        notifiedAt: admin.firestore.FieldValue.serverTimestamp(),
        dispatchAttemptedAt: admin.firestore.FieldValue.serverTimestamp(),
        notificationStats: {
          eligibleCount: eligibleDrivers.length,
          targetCount: targets.length,
          notifiedCount,
          failedCount: targets.length - notifiedCount,
          invalidTokenCount: invalidTokenDriverIds.length,
          sampleErrorCodes: failedErrorCodes.slice(0, 5),
        },
      },
      {merge: true},
    );

    return {
      notifiedCount,
      nearestDistanceKm: targets[0].distanceKm,
      nearestEtaMinutes: targets[0].etaMinutes,
      failedCount: targets.length - notifiedCount,
      invalidTokenCount: invalidTokenDriverIds.length,
    };
  },
);