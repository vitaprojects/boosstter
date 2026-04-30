import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'app_shell.dart';
import 'booster_logo.dart';
import 'signup_screen.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const double _kPrimaryButtonHeight = 52;
  static const double _kPrimaryButtonRadius = 12;
  static const double _kLogoToHeadingSpacing = 20;
  static const double _kHeadingToSubtitleSpacing = 8;
  static const double _kSubtitleToFormSpacing = 28;

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  String get _normalizedEmail => _emailController.text.trim().toLowerCase();

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);
    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _normalizedEmail,
        password: _passwordController.text,
      );
      if (mounted) {
        await _routeSignedInUser(credential.user);
      }
    } on FirebaseAuthException catch (e) {
      String message;
      IconData icon;
      switch (e.code) {
        case 'user-not-found':
          message = 'No account found with this email';
          icon = Icons.person_off;
          break;
        case 'wrong-password':
          message = 'Incorrect password';
          icon = Icons.lock_open;
          break;
        case 'invalid-credential':
        case 'invalid-login-credentials':
          message = 'Incorrect email or password';
          icon = Icons.lock_outline;
          break;
        case 'invalid-email':
          message = 'Please enter a valid email address';
          icon = Icons.mail_outline;
          break;
        case 'network-request-failed':
          message = 'Network error. Please check your connection';
          icon = Icons.wifi_off;
          break;
        default:
          message = e.message ?? 'Login failed (${e.code}). Please try again';
          icon = Icons.error_outline;
      }
      if (mounted) _showErrorSnackBar(message, icon);
    } catch (e) {
      if (mounted)
        _showErrorSnackBar(
          'Network error. Please check your connection',
          Icons.cloud_off,
        );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _routeSignedInUser(User? user) async {
    if (user == null) {
      _showErrorSnackBar(
        'Login failed. Please try again.',
        Icons.error_outline,
      );
      return;
    }

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  void _showErrorSnackBar(String message, IconData icon) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.red[700],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Booster')),
      resizeToAvoidBottomInset: true,
      body: BoosterPageBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder:
                (context, constraints) => SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    24,
                    24,
                    24 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 48,
                    ),
                    child: Form(
                      key: _formKey,
                      child: BoosterSurfaceCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Center(
                              child: BoosterLogo(
                                size: 98,
                                compact: true,
                                showWordmark: true,
                              ),
                            ),
                            const SizedBox(height: _kLogoToHeadingSpacing),
                            Text(
                              'Welcome Back',
                              style: Theme.of(context).textTheme.headlineMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: _kHeadingToSubtitleSpacing),
                            Text(
                              'Sign in to continue',
                              style: Theme.of(
                                context,
                              ).textTheme.bodyLarge?.copyWith(
                                color: Colors.grey[100],
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: _kSubtitleToFormSpacing),
                            TextFormField(
                              controller: _emailController,
                              decoration: const InputDecoration(
                                labelText: 'Email',
                                prefixIcon: Icon(Icons.email_outlined),
                              ),
                              keyboardType: TextInputType.emailAddress,
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Please enter your email';
                                }
                                final email = value.trim();
                                final emailRegex = RegExp(
                                  r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                );
                                if (!emailRegex.hasMatch(email)) {
                                  return 'Please enter a valid email';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _passwordController,
                              decoration: const InputDecoration(
                                labelText: 'Password',
                                prefixIcon: Icon(Icons.lock_outline),
                              ),
                              obscureText: true,
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Please enter your password';
                                }
                                if (value.length < 6) {
                                  return 'Password must be at least 6 characters';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 24),
                            _isLoading
                                ? const SizedBox(
                                  height: 50,
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                                : ElevatedButton(
                                  onPressed: _login,
                                  style: ElevatedButton.styleFrom(
                                    minimumSize: const Size(
                                      double.infinity,
                                      _kPrimaryButtonHeight,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        _kPrimaryButtonRadius,
                                      ),
                                    ),
                                  ),
                                  child: const Text('Login'),
                                ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed:
                                  () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const SignupScreen(),
                                    ),
                                  ),
                              child: const Text(
                                "Don't have an account? Sign up",
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
