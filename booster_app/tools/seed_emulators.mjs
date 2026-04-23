#!/usr/bin/env node

const projectId = process.env.FIREBASE_PROJECT_ID || 'booster-da72c';
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST || '127.0.0.1:9099';
const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const dbHost = process.env.FIREBASE_DATABASE_EMULATOR_HOST || '127.0.0.1:9000';

const authBase = `http://${authHost}`;
const firestoreBase = `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents`;
const dbBase = `http://${dbHost}`;

const users = [
  {
    email: 'customer1@booster.local',
    password: 'password123',
    role: 'customer',
    isAvailable: false,
    latitude: 37.7749,
    longitude: -122.4194,
    isSubscribed: true,
  },
  {
    email: 'driver1@booster.local',
    password: 'password123',
    role: 'driver',
    isAvailable: true,
    latitude: 37.7765,
    longitude: -122.417,
    isSubscribed: false,
  },
];

function assertOk(response, context) {
  if (!response.ok) {
    throw new Error(`${context} failed (${response.status}): ${response.statusText}`);
  }
}

async function createAuthUser(email, password) {
  const response = await fetch(
    `${authBase}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    }
  );
  const data = await response.json();
  if (!response.ok) {
    throw new Error(`Create auth user ${email} failed: ${JSON.stringify(data)}`);
  }
  return { localId: data.localId, idToken: data.idToken };
}

async function signInAuthUser(email, password) {
  const response = await fetch(
    `${authBase}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=fake-api-key`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    }
  );
  const data = await response.json();
  if (!response.ok) {
    throw new Error(`Sign in auth user ${email} failed: ${JSON.stringify(data)}`);
  }
  return { localId: data.localId, idToken: data.idToken };
}

async function getOrCreateUserId(email, password) {
  try {
    return await createAuthUser(email, password);
  } catch (error) {
    if (!String(error.message).includes('EMAIL_EXISTS')) {
      throw error;
    }
    return signInAuthUser(email, password);
  }
}

function firestoreFields(data) {
  const fields = {};
  for (const [key, value] of Object.entries(data)) {
    if (typeof value === 'string') fields[key] = { stringValue: value };
    else if (typeof value === 'boolean') fields[key] = { booleanValue: value };
    else if (typeof value === 'number') fields[key] = { doubleValue: value };
    else if (value instanceof Date) fields[key] = { timestampValue: value.toISOString() };
  }
  return { fields };
}

async function upsertUserDoc(uid, idToken, userData) {
  const payload = firestoreFields({
    userId: uid,
    email: userData.email,
    role: userData.role,
    isAvailable: userData.isAvailable,
    latitude: userData.latitude,
    longitude: userData.longitude,
    isSubscribed: userData.isSubscribed,
  });

  const url = `${firestoreBase}/users/${uid}`;
  const response = await fetch(url, {
    method: 'PATCH',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${idToken}`,
    },
    body: JSON.stringify(payload),
  });
  assertOk(response, `Upsert Firestore users/${uid}`);
}

async function createPendingRequest(customerId, driverId, idToken) {
  const payload = firestoreFields({
    customerId,
    driverId,
    status: 'pending',
    timestamp: new Date(),
  });

  const response = await fetch(`${firestoreBase}/requests`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${idToken}`,
    },
    body: JSON.stringify(payload),
  });
  assertOk(response, 'Create pending request');
}

async function seedRealtimeDatabase(summary, idToken) {
  const response = await fetch(`${dbBase}/seed/meta.json?auth=${encodeURIComponent(idToken)}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(summary),
  });
  assertOk(response, 'Seed Realtime Database');
}

async function main() {
  const seededUsers = [];
  for (const user of users) {
    const authUser = await getOrCreateUserId(user.email, user.password);
    await upsertUserDoc(authUser.localId, authUser.idToken, user);
    seededUsers.push({ uid: authUser.localId, idToken: authUser.idToken, ...user });
  }

  const customer = seededUsers.find((u) => u.role === 'customer');
  const driver = seededUsers.find((u) => u.role === 'driver');
  if (!customer || !driver) {
    throw new Error('Missing seeded customer or driver user.');
  }

  await createPendingRequest(customer.uid, driver.uid, customer.idToken);

  await seedRealtimeDatabase({
    seededAt: new Date().toISOString(),
    projectId,
    users: seededUsers.map((u) => ({ uid: u.uid, email: u.email, role: u.role })),
  }, customer.idToken);

  console.log('\nSeed complete. Test accounts:');
  console.log('Customer: customer1@booster.local / password123');
  console.log('Driver:   driver1@booster.local / password123');
  console.log(`Project:  ${projectId}`);
}

main().catch((error) => {
  console.error('\nSeed failed:', error.message);
  process.exit(1);
});
