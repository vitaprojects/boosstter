import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:in_app_review/in_app_review.dart';

class AppReviewPrompt {
  const AppReviewPrompt._();

  static Future<void> requestAfterSuccessfulTransaction(String requestId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final requestRef = FirebaseFirestore.instance.collection('requests').doc(requestId);

    try {
      final userSnap = await userRef.get();
      final userData = userSnap.data() ?? <String, dynamic>{};
      if (userData['appStoreReviewPrompted'] == true) {
        return;
      }

      final inAppReview = InAppReview.instance;
      if (await inAppReview.isAvailable()) {
        await inAppReview.requestReview();
      }

      await userRef.set({
        'appStoreReviewPrompted': true,
        'appStoreReviewPromptedAt': FieldValue.serverTimestamp(),
        'appStoreReviewPromptedForRequestId': requestId,
      }, SetOptions(merge: true));
      await requestRef.set({
        'appStoreReviewPrompted': true,
        'appStoreReviewPromptedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // Store-review prompts should never block the completed transaction flow.
    }
  }
}
