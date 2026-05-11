#!/usr/bin/env node

import admin from 'firebase-admin';

function parseArgs(argv) {
  const args = {
    days: 30,
    userId: null,
    projectId: process.env.FIREBASE_PROJECT_ID || process.env.GCLOUD_PROJECT || null,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '--days' && argv[i + 1]) {
      args.days = Number.parseInt(argv[i + 1], 10);
      i += 1;
      continue;
    }
    if (token === '--user' && argv[i + 1]) {
      args.userId = argv[i + 1];
      i += 1;
      continue;
    }
    if (token === '--project' && argv[i + 1]) {
      args.projectId = argv[i + 1];
      i += 1;
      continue;
    }
  }

  if (!Number.isFinite(args.days) || args.days <= 0) {
    throw new Error('--days must be a positive integer');
  }

  return args;
}

function ensureFirebaseInitialized(projectId) {
  if (admin.apps.length > 0) {
    return;
  }

  const usingEmulator = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
  if (usingEmulator) {
    admin.initializeApp({ projectId: projectId || 'demo-boosstter' });
    return;
  }

  admin.initializeApp();
}

function toDayKey(date) {
  return date.toISOString().slice(0, 10);
}

function percent(numerator, denominator) {
  if (!denominator) return '0.0%';
  return `${((numerator / denominator) * 100).toFixed(1)}%`;
}

function createEmptyDay() {
  return {
    providerSearchCompleted: 0,
    providerSearchNoProvider: 0,
    searchCycleTimeout: 0,
    resent: 0,
    resendFailed: 0,
    resendQueueEmpty: 0,
    resendNoProviders: 0,
    customerCancelled: 0,
    cancelFailed: 0,
    dispatchSuccess: 0,
    dispatchFailed: 0,
  };
}

function applyEvent(bucket, eventName, details) {
  switch (eventName) {
    case 'provider_search_completed': {
      bucket.providerSearchCompleted += 1;
      const providerCount = Number(details?.providerCount ?? 0);
      if (providerCount <= 0) {
        bucket.providerSearchNoProvider += 1;
      }
      break;
    }
    case 'search_cycle_timeout':
      bucket.searchCycleTimeout += 1;
      break;
    case 'request_resent':
      bucket.resent += 1;
      break;
    case 'request_resend_failed':
      bucket.resendFailed += 1;
      break;
    case 'resend_queue_empty':
      bucket.resendQueueEmpty += 1;
      break;
    case 'resend_search_no_providers':
      bucket.resendNoProviders += 1;
      break;
    case 'request_cancelled_by_customer':
      bucket.customerCancelled += 1;
      break;
    case 'request_cancel_failed':
      bucket.cancelFailed += 1;
      break;
    case 'boost_request_dispatched':
      bucket.dispatchSuccess += 1;
      break;
    case 'boost_request_dispatch_failed':
      bucket.dispatchFailed += 1;
      break;
    default:
      break;
  }
}

function printTable(title, rows) {
  console.log(`\n${title}`);
  if (rows.length === 0) {
    console.log('No rows');
    return;
  }

  const headers = Object.keys(rows[0]);
  const widths = headers.map((header) => {
    const longest = rows.reduce((max, row) => {
      const value = String(row[header] ?? '');
      return Math.max(max, value.length);
    }, header.length);
    return longest;
  });

  const line = headers
    .map((header, i) => String(header).padEnd(widths[i], ' '))
    .join(' | ');
  console.log(line);
  console.log(widths.map((w) => '-'.repeat(w)).join('-|-'));

  for (const row of rows) {
    const out = headers
      .map((header, i) => String(row[header] ?? '').padEnd(widths[i], ' '))
      .join(' | ');
    console.log(out);
  }
}

async function fetchEvents(args) {
  const db = admin.firestore();
  const startDate = new Date();
  startDate.setUTCDate(startDate.getUTCDate() - args.days);

  let query = db
    .collection('analytics_events')
    .where('serviceType', '==', 'boost')
    .where('createdAt', '>=', admin.firestore.Timestamp.fromDate(startDate))
    .orderBy('createdAt', 'asc');

  if (args.userId) {
    query = query.where('userId', '==', args.userId);
  }

  const snapshot = await query.get();
  return snapshot.docs.map((doc) => {
    const data = doc.data();
    return {
      id: doc.id,
      eventName: data.eventName,
      createdAt: data.createdAt?.toDate?.() ?? null,
      details: data.details ?? {},
    };
  });
}

function summarize(events, days) {
  const byDay = new Map();
  const totals = createEmptyDay();

  for (let i = days - 1; i >= 0; i -= 1) {
    const d = new Date();
    d.setUTCDate(d.getUTCDate() - i);
    byDay.set(toDayKey(d), createEmptyDay());
  }

  for (const event of events) {
    if (!event.createdAt) continue;
    const dayKey = toDayKey(event.createdAt);
    if (!byDay.has(dayKey)) {
      byDay.set(dayKey, createEmptyDay());
    }

    const bucket = byDay.get(dayKey);
    applyEvent(bucket, event.eventName, event.details);
    applyEvent(totals, event.eventName, event.details);
  }

  const dayRows = Array.from(byDay.entries()).map(([day, m]) => {
    const resendAttempts = m.resent + m.resendFailed + m.resendQueueEmpty + m.resendNoProviders;
    return {
      day,
      dispatch_ok: m.dispatchSuccess,
      dispatch_fail: m.dispatchFailed,
      search_timeout: m.searchCycleTimeout,
      resend_ok: m.resent,
      resend_attempts: resendAttempts,
      cancel_ok: m.customerCancelled,
      no_provider_searches: m.providerSearchNoProvider,
    };
  });

  const totalResendAttempts =
    totals.resent + totals.resendFailed + totals.resendQueueEmpty + totals.resendNoProviders;

  const overview = [
    { metric: 'Dispatch success', value: totals.dispatchSuccess },
    { metric: 'Dispatch failed', value: totals.dispatchFailed },
    { metric: 'Search cycle timeout', value: totals.searchCycleTimeout },
    { metric: 'Resend success', value: totals.resent },
    { metric: 'Resend attempts (all outcomes)', value: totalResendAttempts },
    { metric: 'Resend success rate', value: percent(totals.resent, totalResendAttempts) },
    { metric: 'Customer cancelled', value: totals.customerCancelled },
    { metric: 'Cancel failed', value: totals.cancelFailed },
    { metric: 'Provider searches with 0 providers', value: totals.providerSearchNoProvider },
  ];

  return { dayRows, overview };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  ensureFirebaseInitialized(args.projectId);

  const events = await fetchEvents(args);
  const { dayRows, overview } = summarize(events, args.days);

  console.log('Boost Flow Analytics Report');
  console.log(`Window: last ${args.days} days`);
  if (args.userId) {
    console.log(`Filter: userId=${args.userId}`);
  }
  if (args.projectId) {
    console.log(`Project: ${args.projectId}`);
  }
  console.log(`Events scanned: ${events.length}`);

  printTable('Overview', overview);
  printTable('Daily Funnel', dayRows);
}

main().catch((error) => {
  console.error('Failed to generate boost flow metrics report:');
  console.error(error.message);
  process.exit(1);
});
