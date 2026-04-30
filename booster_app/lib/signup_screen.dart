import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';
import 'app_shell.dart';
import 'auth_routing.dart';
import 'booster_logo.dart';
import 'verification_screen.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  static const double _kPrimaryButtonHeight = 52;
  static const double _kPrimaryButtonRadius = 12;
  static const double _kLogoToHeadingSpacing = 20;
  static const double _kHeadingToSubtitleSpacing = 8;
  static const double _kSubtitleToFormSpacing = 28;

  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  static const String _verificationType = 'phone';
  bool _isLoading = false;

  static final RegExp _emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  String get _normalizedEmail => _emailController.text.trim().toLowerCase();

  Future<void> _signup() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_passwordController.text != _confirmPasswordController.text) {
      _showErrorSnackBar('Passwords do not match', Icons.lock_outline);
      return;
    }
    setState(() => _isLoading = true);
    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
            email: _normalizedEmail,
            password: _passwordController.text,
          );

      final user = credential.user;
      if (user == null) {
        if (mounted) {
          _showErrorSnackBar(
            'Signup failed. Please try again.',
            Icons.error_outline,
          );
        }
        return;
      }

      // Generate verification code
      final verificationCode = _generateVerificationCode();

      // Save user profile with verification pending
      final saved = await _saveUserToFirestore(
        user,
        role: customerRole,
        verificationCode: verificationCode,
        isVerified: false,
      );
      if (!saved) {
        await _rollbackCreatedAccount(user);
        if (mounted) {
          _showErrorSnackBar(
            'Profile creation failed and the account was rolled back. Please try again.',
            Icons.cloud_off,
          );
        }
        return;
      }

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder:
                (_) => VerificationScreen(
                  verificationCode: verificationCode,
                  verificationType: _verificationType,
                  email: _normalizedEmail,
                  phone: _phoneController.text,
                  userId: user.uid,
                  fullName: _fullNameController.text,
                ),
          ),
          (route) => false,
        );
      }
    } on FirebaseAuthException catch (e) {
      String message;
      IconData icon;
      switch (e.code) {
        case 'weak-password':
          message = 'Password must be at least 6 characters';
          icon = Icons.lock;
          break;
        case 'email-already-in-use':
          message = 'An account already exists with this email';
          icon = Icons.mail;
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
          message = e.message ?? 'Signup failed (${e.code}). Please try again';
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

  String _generateVerificationCode() {
    return (100000 + Random().nextInt(900000)).toString();
  }

  String _normalizePhone(String value) {
    return value.replaceAll(RegExp(r'[^0-9+]'), '');
  }

  Future<bool> _saveUserToFirestore(
    User user, {
    required String role,
    required String verificationCode,
    required bool isVerified,
  }) async {
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'userId': user.uid,
        'fullName': _fullNameController.text.trim(),
        'address': _addressController.text.trim(),
        'phone': _normalizePhone(_phoneController.text.trim()),
        'email': user.email,
        'role': role,
        'isAvailable': false,
        'isVerified': isVerified,
        'verificationCode': verificationCode,
        'verificationType': _verificationType,
        'boostTypes': [], // Will be set after verification
        'latitude': 0.0,
        'longitude': 0.0,
        'isSubscribed': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    } on FirebaseException catch (e) {
      if (mounted)
        _showErrorSnackBar(
          'Failed to save your profile (${e.code}). Please try again.',
          Icons.cloud_off,
        );
    } catch (e) {
      if (mounted)
        _showErrorSnackBar(
          'Failed to save your profile. Please try again.',
          Icons.cloud_off,
        );
    }
    return false;
  }

  Future<void> _rollbackCreatedAccount(User user) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .delete();
    } catch (_) {
      // Ignore cleanup errors and continue rollback.
    }

    try {
      await user.delete();
    } catch (_) {
      await FirebaseAuth.instance.signOut();
    }
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
      body: BoosterPageBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
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
                            'Create Account',
                            style: Theme.of(context).textTheme.headlineMedium,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: _kHeadingToSubtitleSpacing),
                          Text(
                            'Join Booster',
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
                            controller: _fullNameController,
                            decoration: const InputDecoration(
                              labelText: 'Full Name',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            validator: (value) {
                              final name = value?.trim() ?? '';
                              if (name.isEmpty)
                                return 'Please enter your full name';
                              if (name.length < 2)
                                return 'Name looks too short';
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _addressController,
                            decoration: const InputDecoration(
                              labelText: 'Address',
                              prefixIcon: Icon(Icons.location_on_outlined),
                            ),
                            minLines: 2,
                            maxLines: 3,
                            validator: (value) {
                              final address = value?.trim() ?? '';
                              if (address.isEmpty)
                                return 'Please enter your address';
                              if (address.length < 8)
                                return 'Please enter a complete address';
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _phoneController,
                            decoration: const InputDecoration(
                              labelText: 'Phone Number',
                              prefixIcon: Icon(Icons.phone_outlined),
                            ),
                            keyboardType: TextInputType.phone,
                            validator: (value) {
                              final normalized = _normalizePhone(value ?? '');
                              if (normalized.isEmpty)
                                return 'Please enter your phone number';
                              final digitsOnly = normalized.replaceAll(
                                RegExp(r'[^0-9]'),
                                '',
                              );
                              if (digitsOnly.length < 10)
                                return 'Please enter a valid phone number';
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _emailController,
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.email_outlined),
                            ),
                            keyboardType: TextInputType.emailAddress,
                            validator: (value) {
                              final email = value?.trim() ?? '';
                              if (email.isEmpty)
                                return 'Please enter your email';
                              if (!_emailRegex.hasMatch(email))
                                return 'Please enter a valid email';
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _passwordController,
                            decoration: const InputDecoration(
                              labelText: 'Password',
                              prefixIcon: Icon(Icons.lock_outline),
                            ),
                            obscureText: true,
                            validator: (value) {
                              if (value == null || value.isEmpty)
                                return 'Please enter your password';
                              if (value.length < 6)
                                return 'Password must be at least 6 characters';
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _confirmPasswordController,
                            decoration: const InputDecoration(
                              labelText: 'Confirm Password',
                              prefixIcon: Icon(Icons.lock_outline),
                            ),
                            obscureText: true,
                            validator: (value) {
                              if (value == null || value.isEmpty)
                                return 'Please confirm your password';
                              return null;
                            },
                          ),
                          const SizedBox(height: 32),
                          _isLoading
                              ? const SizedBox(
                                height: 50,
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                              : ElevatedButton(
                                onPressed: _signup,
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
                                child: const Text('Sign Up'),
                              ),
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Already have an account? Login'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }
}
