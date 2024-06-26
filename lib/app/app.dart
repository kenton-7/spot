// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spot/cubits/notification/notification_cubit.dart';
import 'package:spot/data_profiders/location_provider.dart';
import 'package:spot/pages/tab_page.dart';
import 'package:spot/repositories/repository.dart';
import 'package:supabase/supabase.dart';

class SharedPreferencesGotrueAsyncStorage extends GotrueAsyncStorage {
  SharedPreferencesGotrueAsyncStorage() {
    _initialize();
  }

  final Completer<void> _initializationCompleter = Completer();

  late final SharedPreferences _prefs;

  Future<void> _initialize() async {
    WidgetsFlutterBinding.ensureInitialized();
    _prefs = await SharedPreferences.getInstance();
    _initializationCompleter.complete();
  }

  @override
  Future<String?> getItem({required String key}) async {
    await _initializationCompleter.future;
    return _prefs.getString(key);
  }

  @override
  Future<void> removeItem({required String key}) async {
    await _initializationCompleter.future;
    await _prefs.remove(key);
  }

  @override
  Future<void> setItem({required String key, required String value}) async {
    await _initializationCompleter.future;
    await _prefs.setString(key, value);
  }
}

class App extends StatelessWidget {
  App({Key? key}) : super(key: key);

  static const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const _supabaseannonKey = String.fromEnvironment('SUPABASE_ANNON_KEY');
  final _supabaseClient = SupabaseClient(_supabaseUrl, _supabaseannonKey,
      authOptions: AuthClientOptions(pkceAsyncStorage: SharedPreferencesGotrueAsyncStorage()));

  final _analytics = FirebaseAnalytics.instance;
  final _localStorage = const FlutterSecureStorage();
  final _locationProvider = LocationProvider();

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<Repository>(
          create: (context) => Repository(
            supabaseClient: _supabaseClient,
            analytics: _analytics,
            localStorage: _localStorage,
            locationProvider: _locationProvider,
          ),
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<NotificationCubit>(
            create: (context) => NotificationCubit(
              repository: RepositoryProvider.of<Repository>(context),
            )..loadNotifications(),
          )
        ],
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            textSelectionTheme: const TextSelectionThemeData(cursorColor: Color(0xFFFFFFFF)),
            primaryColor: const Color(0xFFFFFFFF),
            appBarTheme: const AppBarTheme(
              centerTitle: true,
              color: Colors.transparent,
              shadowColor: Colors.transparent,
              titleTextStyle: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w300,
              ),
            ),
            inputDecorationTheme: const InputDecorationTheme(
              labelStyle: TextStyle(color: Color(0xFFFFFFFF)),
              border: OutlineInputBorder(
                borderSide: BorderSide(width: 1, color: Color(0xFFFFFFFF)),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(width: 1, color: Color(0xFFFFFFFF)),
              ),
              focusColor: Color(0xFFFFFFFF),
              isDense: true,
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(backgroundColor: const Color(0xFFFFFFFF)),
            ),
            snackBarTheme: SnackBarThemeData(
              backgroundColor: const Color(0xFFFFFFFF).withOpacity(0.7),
              elevation: 10,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(50),
              ),
            ),
          ),
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
          ],
          navigatorObservers: [
            FirebaseAnalyticsObserver(analytics: _analytics),
          ],
          home: TabPage(),
        ),
      ),
    );
  }
}
