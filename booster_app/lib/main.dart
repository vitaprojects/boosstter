import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'login_screen.dart';
import 'home_screen.dart';

const _firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
const _firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
const _firebaseMessagingSenderId = String.fromEnvironment(
  'FIREBASE_MESSAGING_SENDER_ID',
  defaultValue: '918678303158',
);
const _firebaseProjectId = String.fromEnvironment(
  'FIREBASE_PROJECT_ID',
  defaultValue: 'booster-da72c',
);
const _firebaseStorageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
const _firebaseAuthDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
const _firebaseMeasurementId = String.fromEnvironment('FIREBASE_MEASUREMENT_ID');
const _useFirebaseEmulators = bool.fromEnvironment(
  'USE_FIREBASE_EMULATORS',
  defaultValue: false,
);
const _firebaseEmulatorHost = String.fromEnvironment('FIREBASE_EMULATOR_HOST');

const _androidFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyC5HOwGtkU0L_PsPj3rKsjvomeZiGDNFQE',
  appId: '1:918678303158:android:d62bc793efefbd5b8f1117',
  messagingSenderId: '918678303158',
  projectId: 'booster-da72c',
  storageBucket: 'booster-da72c.appspot.com',
);

String _resolveEmulatorHost() {
  if (_firebaseEmulatorHost.isNotEmpty) {
    return _firebaseEmulatorHost;
  }

  if (!kIsWeb && Platform.isAndroid) {
    // Android emulator reaches host machine through this alias.
    return '10.0.2.2';
  }

  return '127.0.0.1';
}

Future<void> _configureFirebaseEmulators() async {
  if (!_useFirebaseEmulators) {
    return;
  }

  final host = _resolveEmulatorHost();
  FirebaseAuth.instance.useAuthEmulator(host, 9099);
  FirebaseFirestore.instance.useFirestoreEmulator(host, 8080);
  FirebaseDatabase.instance.useDatabaseEmulator(host, 9000);
  FirebaseFunctions.instance.useFunctionsEmulator(host, 5001);
}

FirebaseOptions? _firebaseOptionsFromEnv() {
  if (_firebaseApiKey.isEmpty ||
      _firebaseAppId.isEmpty ||
      _firebaseMessagingSenderId.isEmpty ||
      _firebaseProjectId.isEmpty) {
    return null;
  }

  return FirebaseOptions(
    apiKey: _firebaseApiKey,
    appId: _firebaseAppId,
    messagingSenderId: _firebaseMessagingSenderId,
    projectId: _firebaseProjectId,
    storageBucket: _firebaseStorageBucket.isEmpty
        ? '$_firebaseProjectId.appspot.com'
        : _firebaseStorageBucket,
    authDomain: _firebaseAuthDomain.isEmpty
        ? '$_firebaseProjectId.firebaseapp.com'
        : _firebaseAuthDomain,
    measurementId: _firebaseMeasurementId.isEmpty ? null : _firebaseMeasurementId,
  );
}

Future<void> _initializeFirebase() async {
  if (!kIsWeb && Platform.isAndroid) {
    await Firebase.initializeApp(options: _androidFirebaseOptions);
    return;
  }

  try {
    // Preferred path when platform config files exist.
    await Firebase.initializeApp();
    return;
  } catch (_) {
    final envOptions = _firebaseOptionsFromEnv();
    if (envOptions == null) {
      throw Exception(
        'Firebase config not found. Add platform config files or pass '
        'FIREBASE_API_KEY, FIREBASE_APP_ID, FIREBASE_MESSAGING_SENDER_ID, '
        'FIREBASE_PROJECT_ID via --dart-define.',
      );
    }

    await Firebase.initializeApp(options: envOptions);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initializeFirebase();
  _logFirebaseConfiguration();
  await _configureFirebaseEmulators();
  runApp(const MyApp());
}

void _logFirebaseConfiguration() {
  if (!kDebugMode) {
    return;
  }

  final app = Firebase.app();
  final options = app.options;
  debugPrint(
    '[Firebase] app=${app.name}, projectId=${options.projectId}, '
    'appId=${options.appId}, apiKeySuffix=${options.apiKey.length >= 6 ? options.apiKey.substring(options.apiKey.length - 6) : options.apiKey}',
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // Plum-inspired light theme palette
  static const Color primaryColor = Color(0xFF5500FF);   // Vibrant purple
  static const Color secondaryColor = Color(0xFF7B3FE4); // Soft violet
  static const Color accentColor = Color(0xFF5500FF);    // Same purple for accent
  static const Color highlightColor = Color(0xFF5500FF); // Purple highlights

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Booster',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'sans-serif',
        colorScheme: ColorScheme.light(
          primary: primaryColor,
          secondary: secondaryColor,
          tertiary: accentColor,
          surface: Colors.white,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onTertiary: Colors.white,
          onSurface: const Color(0xFF1A1A2E),
        ),
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF1A1A2E),
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
          ),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 1,
          shadowColor: Colors.black12,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            minimumSize: const Size(double.infinity, 50),
            elevation: 0,
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: primaryColor,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF2F2F7),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE0E0E8)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE0E0E8)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: primaryColor, width: 1.8),
          ),
          labelStyle: const TextStyle(color: Color(0xFF8A8A9A)),
          prefixIconColor: Color(0xFF8A8A9A),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.white,
          selectedItemColor: primaryColor,
          unselectedItemColor: Color(0xFFAAAAAA),
          elevation: 8,
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFF0F0F5),
          thickness: 1,
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1A1A2E),
          ),
          headlineMedium: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A2E),
          ),
          headlineSmall: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A2E),
          ),
          titleLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A2E),
          ),
          titleMedium: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w500,
            color: Color(0xFF1A1A2E),
          ),
          titleSmall: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Color(0xFF1A1A2E),
          ),
          bodyLarge: TextStyle(
            fontSize: 16,
            color: Color(0xFF1A1A2E),
          ),
          bodyMedium: TextStyle(
            fontSize: 14,
            color: Color(0xFF1A1A2E),
          ),
          bodySmall: TextStyle(
            fontSize: 12,
            color: Color(0xFF8A8A9A),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnapshot) {
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = authSnapshot.data;
        if (user == null) {
          return const LoginScreen();
        }

        return const HomeScreen();
      },
    );
  }
}

class SignedInFallbackScreen extends StatelessWidget {
  const SignedInFallbackScreen({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Booster')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.account_circle, size: 56),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (context) => const AuthGate()),
                  );
                },
                child: const Text('Retry'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  await FirebaseAuth.instance.signOut();
                },
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
