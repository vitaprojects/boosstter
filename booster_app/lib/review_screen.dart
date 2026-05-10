import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.requestId,
    required this.providerName,
    required this.isCustomerReviewing,
  });

  final String requestId;
  final String providerName;

  /// true = customer reviewing provider, false = provider reviewing customer
  final bool isCustomerReviewing;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  int _rating = 0;
  final TextEditingController _commentController = TextEditingController();
  bool _isSubmitting = false;

  Future<void> _submit() async {
    if (_rating == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a star rating')),
      );
      return;
    }
    setState(() => _isSubmitting = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      await FirebaseFirestore.instance
          .collection('requests')
          .doc(widget.requestId)
          .collection('reviews')
          .add({
        'reviewerId': uid,
        'rating': _rating,
        'comment': _commentController.text.trim(),
        'isCustomerReview': widget.isCustomerReviewing,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Mark review submitted on the request
      final field = widget.isCustomerReviewing
          ? 'customerReviewSubmitted'
          : 'providerReviewSubmitted';
      await FirebaseFirestore.instance
          .collection('requests')
          .doc(widget.requestId)
          .update({field: true});

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit review: $e'),
            backgroundColor: Colors.red[700],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F3F7),
      appBar: AppBar(
        title: const Text('Leave a Review'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Illustration
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF5500FF).withValues(alpha: 0.07),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.star_rounded,
              size: 64,
              color: Color(0xFF5500FF),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            widget.isCustomerReviewing
                ? 'How was your experience with\n${widget.providerName}?'
                : 'How was your experience with this customer?',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Your feedback helps improve the Booster community.',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: Colors.grey[500]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // Star rating
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              final starValue = i + 1;
              return GestureDetector(
                onTap: () => setState(() => _rating = starValue),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(
                    starValue <= _rating
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    size: 48,
                    color: starValue <= _rating
                        ? const Color(0xFFF59E0B)
                        : Colors.grey[300],
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 10),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _rating > 0
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Center(
              child: Text(
                _rating == 5
                    ? '⭐ Excellent!'
                    : _rating == 4
                        ? '👍 Good'
                        : _rating == 3
                            ? '😐 Okay'
                            : _rating == 2
                                ? '😕 Poor'
                                : '😞 Very Poor',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: _rating >= 4
                          ? const Color(0xFF22C55E)
                          : _rating == 3
                              ? Colors.orange
                              : Colors.red,
                    ),
              ),
            ),
            secondChild: const SizedBox.shrink(),
          ),
          const SizedBox(height: 24),

          // Comment box
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE1E2EA)),
            ),
            child: TextField(
              controller: _commentController,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Write a comment (optional)...',
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(16),
              ),
            ),
          ),
          const SizedBox(height: 28),

          // Submit
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5500FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Submit Review',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text(
                'Skip for now',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
