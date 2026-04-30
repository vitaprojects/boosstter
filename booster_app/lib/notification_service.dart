import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

/// Notification Service
/// Handles FCM message listening and in-app notification display
/// Plays alert sound on new boost orders
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() {
    return _instance;
  }

  NotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  
  // Callback to handle new orders
  void Function(Map<String, dynamic> orderData)? _onNewOrderCallback;

  /// Initialize notification service
  /// Should be called once during app startup
  Future<void> initialize(
    BuildContext context, {
    required void Function(Map<String, dynamic> orderData) onNewOrder,
  }) async {
    _onNewOrderCallback = onNewOrder;
    
    // Request notification permissions
    await _requestPermission();

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      _handleForegroundMessage(context, message);
    });

    // Handle background message taps
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _handleMessageOpenedApp(context, message);
    });

    // Get initial message if app was terminated
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      _handleMessageOpenedApp(context, initialMessage);
    }
  }

  /// Request notification permissions from user
  Future<void> _requestPermission() async {
    try {
      NotificationSettings settings = await _messaging.requestPermission(
        alert: true,
        announcement: true,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      debugPrint('User notification permissions: ${settings.authorizationStatus}');
    } catch (e) {
      debugPrint('Error requesting permissions: $e');
    }
  }

  /// Handle messages received while app is in foreground
  void _handleForegroundMessage(BuildContext context, RemoteMessage message) {
    debugPrint('Handling foreground message: ${message.messageId}');

    // Play sound and vibration
    _playNotificationAlert();

    // Extract order data
    final data = message.data;
    if (data['type'] == 'new_boost_order') {
      _onNewOrderCallback?.call(data);
    }

    // Show top notification
    _showInAppNotification(context, message);
  }

  /// Handle messages when app is opened from notification
  void _handleMessageOpenedApp(BuildContext context, RemoteMessage message) {
    debugPrint('App opened from notification: ${message.messageId}');
    final data = message.data;
    if (data['type'] == 'new_boost_order') {
      _onNewOrderCallback?.call(data);
    }
  }

  /// Play notification alert sound and vibration
  void _playNotificationAlert() {
    // In production, you would:
    // 1. Use a package like 'just_audio' or 'audioplayers' to play sound
    // 2. Use 'vibration' package for haptic feedback
    // For now, we're using Firebase messaging sound
    
    debugPrint('Playing notification alert sound');
    // TODO: Implement actual sound playback
    // Example using just_audio:
    // final player = AudioPlayer();
    // await player.setAsset('assets/notification.mp3');
    // await player.play();
  }

  /// Show in-app notification banner
  void _showInAppNotification(BuildContext context, RemoteMessage message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message.notification?.body ?? 'New notification'),
        duration: const Duration(seconds: 4),
        backgroundColor: const Color(0xFF14B8A6),
      ),
    );
  }

  /// Send test notification to current user (for development)
  static Future<void> sendTestNotification({
    required String requestId,
    required String pickupAddress,
    required double compensationAmount,
  }) async {
    // This would typically be called from a Cloud Function
    // For testing, you can call this from the driver screen
    debugPrint('Test notification for order: $requestId');
  }
}
