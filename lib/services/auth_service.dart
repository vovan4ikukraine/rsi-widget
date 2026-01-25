import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_service.dart';
import 'firebase_service.dart';
import 'data_sync_service.dart';
import 'alert_sync_service.dart';

/// Service for user authentication
class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn();

  /// Get current user
  static User? get currentUser => _auth.currentUser;

  /// Check if user is signed in
  static bool get isSignedIn => _auth.currentUser != null;

  /// Get user ID (Firebase UID or generated)
  static String? get userId => _auth.currentUser?.uid;

  /// Sign in with Google
  static Future<UserCredential?> signInWithGoogle() async {
    try {
      // Trigger the authentication flow
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

      if (googleUser == null) {
        // User canceled the sign-in
        return null;
      }

      // Obtain the auth details from the request
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      // Create a new credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // Sign in to Firebase with the Google credential
      final userCredential = await _auth.signInWithCredential(credential);

      // Update UserService with Firebase UID
      await UserService.setFirebaseUserId(userCredential.user!.uid);

      // Register device with server
      await FirebaseService.registerDeviceWithServer();

      // Clear auth_skipped flag since user signed in
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('auth_skipped');

      if (kDebugMode) {
        debugPrint('AuthService: Signed in as ${userCredential.user?.email}');
        debugPrint('AuthService: User ID: ${userCredential.user?.uid}');
      }

      return userCredential;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AuthService: Error signing in with Google: $e');
      }
      rethrow;
    }
  }

  /// Sign out
  static Future<void> signOut() async {
    try {
      // Before signing out, save current preferences and watchlist to cache
      final prefs = await SharedPreferences.getInstance();
      final symbol = prefs.getString('home_selected_symbol');
      final timeframe = prefs.getString('home_selected_timeframe');
      final rsiPeriod = prefs.getInt('home_rsi_period');
      final lowerLevel = prefs.getDouble('home_lower_level');
      final upperLevel = prefs.getDouble('home_upper_level');

      if (symbol != null ||
          timeframe != null ||
          rsiPeriod != null ||
          lowerLevel != null ||
          upperLevel != null) {
        await DataSyncService.savePreferencesToCache(
          symbol: symbol,
          timeframe: timeframe,
          rsiPeriod: rsiPeriod,
          lowerLevel: lowerLevel,
          upperLevel: upperLevel,
        );
      }

      // Sync watchlist and alerts to server before signing out (if authenticated)
      await DataSyncService.syncWatchlist();
      await AlertSyncService.syncPendingAlerts();

      await _googleSignIn.signOut();
      await _auth.signOut();
      await UserService.clearFirebaseUserId();

      // Restore anonymous watchlist and alerts from cache
      await DataSyncService.restoreWatchlistFromCache();
      await DataSyncService.restoreAlertsFromCache();

      // Clear auth_skipped flag so user can sign in again if they want
      await prefs.setBool('auth_skipped', true);

      if (kDebugMode) {
        debugPrint(
            'AuthService: User signed out, preferences and watchlist saved to cache');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AuthService: Error signing out: $e');
      }
      rethrow;
    }
  }

  /// Listen to auth state changes
  static Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Get user display name
  static String? get displayName => _auth.currentUser?.displayName;

  /// Get user email
  static String? get email => _auth.currentUser?.email;

  /// Get user photo URL
  static String? get photoUrl => _auth.currentUser?.photoURL;
}
