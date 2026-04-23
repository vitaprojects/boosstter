const admin = require('firebase-admin');
const {onCall, HttpsError} = require('firebase-functions/v2/https');
const {defineSecret} = require('firebase-functions/params');
const Stripe = require('stripe');

admin.initializeApp();

const stripeSecretKey = defineSecret('STRIPE_SECRET_KEY');
const stripePublishableKey = defineSecret('STRIPE_PUBLISHABLE_KEY');

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