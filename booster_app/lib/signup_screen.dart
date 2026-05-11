import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'booster_logo.dart';
import 'auth_routing.dart';
import 'home_screen.dart';
import 'terms_policy_screen.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  String _selectedRole = customerRole;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _agreedToTerms = false;

  Future<void> _signup() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_passwordController.text != _confirmPasswordController.text) {
      _showErrorSnackBar('Passwords do not match', Icons.lock_outline);
      return;
    }

    if (!_agreedToTerms) {
      _showErrorSnackBar(
        'Please read and agree to the User Agreement & Privacy Policy to continue.',
        Icons.gavel,
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      final user = credential.user;
      if (user == null) {
        if (mounted) {
          _showErrorSnackBar('Signup failed. Please try again.', Icons.error_outline);
        }
        return;
      }

      final saved = await _saveUserToFirestore(user, role: _selectedRole);
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
        _showSuccessSnackBar('Account created successfully!');
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
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
      if (mounted) _showErrorSnackBar('Network error. Please check your connection', Icons.cloud_off);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool> _saveUserToFirestore(User user, {required String role}) async {
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'userId': user.uid,
        'email': user.email,
        'role': role,
        'isAvailable': false,
        'latitude': 0.0,
        'longitude': 0.0,
        'isSubscribed': false,
        'agreementAccepted': true,
        'privacyPolicyAccepted': true,
        'agreementVersion': kBoosterAgreementVersion,
        'agreementAcceptedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    } on FirebaseException catch (e) {
      if (mounted) _showErrorSnackBar('Failed to save your profile (${e.code}). Please try again.', Icons.cloud_off);
    } catch (e) {
      if (mounted) _showErrorSnackBar('Failed to save your profile. Please try again.', Icons.cloud_off);
    }
    return false;
  }

  Future<void> _rollbackCreatedAccount(User user) async {
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).delete();
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(icon, color: Colors.white),
        const SizedBox(width: 12),
        Expanded(child: Text(message, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500))),
      ]),
      backgroundColor: Colors.red[700],
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 4),
    ));
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle, color: Colors.white),
        const SizedBox(width: 12),
        Expanded(child: Text(message, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500))),
      ]),
      backgroundColor: Colors.green[700],
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Booster')),
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: BoosterLogo(size: 84, compact: true)),
                    const SizedBox(height: 32),
                    Text('Create Account', style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text('Join Booster', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.grey[400]), textAlign: TextAlign.center),
                    const SizedBox(height: 40),
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email)),
                      keyboardType: TextInputType.emailAddress,
                      validator: (value) {
                        if (value == null || value.isEmpty) return 'Please enter your email';
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _passwordController,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                          onPressed: () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                        ),
                      ),
                      obscureText: _obscurePassword,
                      validator: (value) {
                        if (value == null || value.isEmpty) return 'Please enter your password';
                        if (value.length < 6) return 'Password must be at least 6 characters';
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _confirmPasswordController,
                      decoration: InputDecoration(
                        labelText: 'Confirm Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscureConfirmPassword ? Icons.visibility_off : Icons.visibility),
                          onPressed: () {
                            setState(() {
                              _obscureConfirmPassword = !_obscureConfirmPassword;
                            });
                          },
                        ),
                      ),
                      obscureText: _obscureConfirmPassword,
                      validator: (value) {
                        if (value == null || value.isEmpty) return 'Please confirm your password';
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    DropdownButtonFormField<String>(
                      value: _selectedRole,
                      decoration: const InputDecoration(
                        labelText: 'I am joining as',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: customerRole,
                          child: Text('Customer (need a boost)'),
                        ),
                        DropdownMenuItem(
                          value: driverRole,
                          child: Text('Driver (provide boosts)'),
                        ),
                      ],
                      onChanged: _isLoading
                          ? null
                          : (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() => _selectedRole = value);
                            },
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        children: [
                          CheckboxListTile(
                            value: _agreedToTerms,
                            onChanged: _isLoading
                                ? null
                                : (value) {
                                    setState(() => _agreedToTerms = value ?? false);
                                  },
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: const Text(
                              'I have read and agree to the User Agreement & Privacy Policy.',
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _isLoading
                                  ? null
                                  : () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => const TermsPolicyScreen(),
                                        ),
                                      );
                                    },
                              icon: const Icon(Icons.description_outlined),
                              label: const Text('Read full agreement and privacy policy'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    _isLoading
                        ? const SizedBox(height: 50, child: Center(child: CircularProgressIndicator()))
                        : ElevatedButton(
                            onPressed: _agreedToTerms ? _signup : null,
                            style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
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
          );
        }),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }
}
