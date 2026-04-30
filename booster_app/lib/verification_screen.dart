import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'app_shell.dart';
import 'booster_logo.dart';
import 'home_screen.dart';

class VerificationScreen extends StatefulWidget {
  final String verificationCode;
  final String verificationType;
  final String email;
  final String phone;
  final String userId;
  final String fullName;

  const VerificationScreen({
    required this.verificationCode,
    required this.verificationType,
    required this.email,
    required this.phone,
    required this.userId,
    required this.fullName,
    super.key,
  });

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  static const double _kPrimaryButtonHeight = 52;
  static const double _kPrimaryButtonRadius = 12;
  static const double _kLogoToHeadingSpacing = 20;
  static const double _kHeadingToSubtitleSpacing = 8;

  final _otpController = TextEditingController();
  bool _isLoading = false;
  bool _codeResent = false;

  @override
  void initState() {
    super.initState();
    _showVerificationCode();
  }

  void _showVerificationCode() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            title: const Text('Verification Code'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Your verification code is:',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    widget.verificationCode,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'This code has been sent to your ${widget.verificationType}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
    );
  }

  Future<void> _verifyCode() async {
    if (_otpController.text.isEmpty) {
      _showErrorSnackBar(
        'Please enter the verification code',
        Icons.error_outline,
      );
      return;
    }

    if (_otpController.text != widget.verificationCode) {
      _showErrorSnackBar('Invalid verification code', Icons.cancel);
      return;
    }

    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .update({
            'isVerified': true,
            'verifiedAt': FieldValue.serverTimestamp(),
          });

      if (mounted) {
        _showSuccessSnackBar('Account verified! Completing setup...');
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const HomeScreen()),
              (route) => false,
            );
          }
        });
      }
    } catch (e) {
      if (mounted) {
        _showErrorSnackBar(
          'Verification failed. Please try again.',
          Icons.cloud_off,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _resendCode() async {
    setState(() => _codeResent = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Verification code resent!'),
        backgroundColor: Colors.green[700],
        duration: const Duration(seconds: 2),
      ),
    );
    Future.delayed(const Duration(seconds: 60), () {
      if (mounted) setState(() => _codeResent = false);
    });
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
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
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
        backgroundColor: Colors.green[700],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify Account')),
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
                        BoosterSurfaceCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Verify Your Account',
                                style:
                                    Theme.of(context).textTheme.headlineMedium,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(
                                height: _kHeadingToSubtitleSpacing,
                              ),
                              Text(
                                'Enter the code sent via SMS to ${widget.phone}',
                                style: Theme.of(
                                  context,
                                ).textTheme.bodyLarge?.copyWith(
                                  color: Colors.grey[100],
                                  fontWeight: FontWeight.w600,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 26),
                              TextField(
                                controller: _otpController,
                                decoration: const InputDecoration(
                                  labelText: 'Verification Code',
                                  prefixIcon: Icon(Icons.verified_user),
                                  hintText: 'Enter 6-digit code',
                                ),
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 18,
                                  letterSpacing: 2,
                                ),
                                maxLength: 6,
                              ),
                              const SizedBox(height: 16),
                              _isLoading
                                  ? const SizedBox(
                                    height: 50,
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  )
                                  : ElevatedButton(
                                    onPressed: _verifyCode,
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
                                    child: const Text('Verify'),
                                  ),
                              const SizedBox(height: 10),
                              TextButton(
                                onPressed: _codeResent ? null : _resendCode,
                                child: Text(
                                  _codeResent
                                      ? 'Resend in 60 seconds'
                                      : 'Resend Code',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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
    _otpController.dispose();
    super.dispose();
  }
}

class BoostTypeSelectionScreen extends StatefulWidget {
  const BoostTypeSelectionScreen({super.key});

  @override
  State<BoostTypeSelectionScreen> createState() =>
      _BoostTypeSelectionScreenState();
}

class _BoostTypeSelectionScreenState extends State<BoostTypeSelectionScreen> {
  static const double _kPrimaryButtonHeight = 52;
  static const double _kPrimaryButtonRadius = 12;
  static const double _kLogoToHeadingSpacing = 20;
  static const double _kHeadingToSubtitleSpacing = 8;

  final List<String> boostTypes = [
    'Email Marketing',
    'Social Media',
    'Content Creation',
    'Community Building',
    'SEO Optimization',
    'Paid Advertising',
    'Analytics Review',
    'Other',
  ];

  List<String> selectedBoostTypes = [];
  bool _isLoading = false;

  Future<void> _completeSignup() async {
    if (selectedBoostTypes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one boost type')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      // For customers, this is optional. For drivers, save boost types.
      // This will be handled in the next screen after they choose their role visibility.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => HomeScreen(selectedBoostTypes: selectedBoostTypes),
        ),
        (route) => false,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Boost Types')),
      body: BoosterPageBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Center(
                child: BoosterLogo(size: 98, compact: true, showWordmark: true),
              ),
              const SizedBox(height: _kLogoToHeadingSpacing),
              BoosterSurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'What boosts can you provide?',
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: _kHeadingToSubtitleSpacing),
                    Text(
                      'Select the types of boosts you can provide to other users',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.grey[100],
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1,
                          ),
                      itemCount: boostTypes.length,
                      itemBuilder: (context, index) {
                        final boostType = boostTypes[index];
                        final isSelected = selectedBoostTypes.contains(
                          boostType,
                        );
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              if (isSelected) {
                                selectedBoostTypes.remove(boostType);
                              } else {
                                selectedBoostTypes.add(boostType);
                              }
                            });
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color:
                                  isSelected
                                      ? const Color(0x1A2EC4B6)
                                      : const Color(0x14FFFFFF),
                              border: Border.all(
                                color:
                                    isSelected
                                        ? const Color(0xFF2EC4B6)
                                        : const Color(0xFFE8E8EE),
                                width: 2,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                if (isSelected)
                                  const Icon(
                                    Icons.check_circle,
                                    color: Color(0xFF2EC4B6),
                                    size: 32,
                                  )
                                else
                                  Icon(
                                    Icons.add_circle_outline,
                                    color: Colors.grey[500],
                                    size: 32,
                                  ),
                                const SizedBox(height: 12),
                                Text(
                                  boostType,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color:
                                        isSelected
                                            ? const Color(0xFF8FE8DF)
                                            : Colors.grey[200],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                    _isLoading
                        ? const SizedBox(
                          height: 50,
                          child: Center(child: CircularProgressIndicator()),
                        )
                        : ElevatedButton(
                          onPressed: _completeSignup,
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
                          child: const Text('Complete Setup'),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
