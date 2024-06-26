// ignore_for_file: lines_longer_than_80_chars, inference_failure_on_function_invocation

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_video_info/flutter_video_info.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:rxdart/subjects.dart';
import 'package:share/share.dart';
import 'package:spot/data_profiders/location_provider.dart';
import 'package:spot/models/comment.dart';
import 'package:spot/models/notification.dart';
import 'package:spot/models/profile.dart';
import 'package:spot/models/video.dart';
import 'package:supabase/supabase.dart';
import 'package:video_player/video_player.dart';

/// Class that communicates with external APIs.
class Repository {
  /// Class that communicates with external APIs.
  Repository({
    required SupabaseClient supabaseClient,
    required FirebaseAnalytics analytics,
    required FlutterSecureStorage localStorage,
    required LocationProvider locationProvider,
  })  : _supabaseClient = supabaseClient,
        _analytics = analytics,
        _localStorage = localStorage,
        _locationProvider = locationProvider {
    _setAuthListenner();
  }

  final SupabaseClient _supabaseClient;
  final FirebaseAnalytics _analytics;
  final FlutterSecureStorage _localStorage;
  final LocationProvider _locationProvider;
  // static const _localStorage = FlutterSecureStorage();
  static const _persistantSessionKey = 'supabase_session';
  static const _termsOfServiceAgreementKey = 'agreed';
  static const _timestampOfLastSeenNotification = 'timestampOfLastSeenNotification';

  /// Used as a placeholder for myUserId when loading data
  /// that requires myUserID but not signed in
  static const _anonymousUUID = '00000000-0000-0000-0000-000000000000';

  // Local Cache
  final List<Video> _mapVideos = [];
  final _mapVideosStreamConntroller = BehaviorSubject<List<Video>>();

  /// Emits videos displayed on the map.
  Stream<List<Video>> get mapVideosStream => _mapVideosStreamConntroller.stream;

  final Map<String, VideoDetail> _videoDetails = {};
  final _videoDetailStreamController = BehaviorSubject<VideoDetail?>();

  /// Stream that emits video details.
  /// Mainly used when the user watches a video.
  Stream<VideoDetail?> get videoDetailStream => _videoDetailStreamController.stream;

  /// In memory cache of profileDetails.
  @visibleForTesting
  final Map<String, ProfileDetail> profileDetailsCache = {};
  final _profileStreamController = BehaviorSubject<Map<String, ProfileDetail>>();

  /// Emits map of all profiles that are stored in memory.
  Stream<Map<String, ProfileDetail>> get profileStream => _profileStreamController.stream;

  /// List of comments that are loaded about a particular video.
  @visibleForTesting
  List<Comment> comments = [];
  final _commentsStreamController = BehaviorSubject<List<Comment>>();

  /// Emits list of comments about a particular video.
  Stream<List<Comment>> get commentsStream => _commentsStreamController.stream;

  List<AppNotification> _notifications = [];
  final _notificationsStreamController = BehaviorSubject<List<AppNotification>>();

  /// Emits list of in app notification.
  Stream<List<AppNotification>> get notificationsStream => _notificationsStreamController.stream;

  final _mentionSuggestionCache = <String, List<Profile>>{};

  /// Return userId or null
  String? get userId => _supabaseClient.auth.currentUser?.id;

  /// Completes when auth state is known
  Completer<void> statusKnown = Completer<void>();

  /// Completer that completes once the logged in user's profile has been loaded
  Completer<void> myProfileHasLoaded = Completer<void>();

  /// The user's profile
  Profile? get myProfile => profileDetailsCache[userId ?? ''];

  /// Whether the user has agreed to terms of service or not
  Future<bool> get hasAgreedToTermsOfService =>
      _localStorage.containsKey(key: _termsOfServiceAgreementKey);

  /// Returns whether the user has agreeed to the terms of service or not.
  Future<void> agreedToTermsOfService() =>
      _localStorage.write(key: _termsOfServiceAgreementKey, value: 'true');

  /// Returns session string that can be used to restore session.
  Future<void> setSessionString(String sessionString) =>
      _localStorage.write(key: _persistantSessionKey, value: sessionString);

  /// Deletes session. Used when user logs out or recovering session failed.
  Future<void> deleteSession() => _localStorage.delete(key: _persistantSessionKey);

  bool _hasRefreshedSession = false;

  /// Resets all cache upon identifying the user
  Future<void> _resetCache() async {
    if (userId != null && !_hasRefreshedSession) {
      _hasRefreshedSession = true;
      profileDetailsCache.clear();
      _mapVideos.clear();
      await getMyProfile();
      // ignore: unawaited_futures
      getNotifications();
      _mapVideosStreamConntroller.add(_mapVideos);
      final searchLocation = await _locationProvider.determinePosition();
      await getVideosFromLocation(searchLocation);
    }
  }

  void _setAuthListenner() {
    _supabaseClient.auth.onAuthStateChange.listen((data) {
      _resetCache();
    });
  }

  /// Recovers session stored inn device's storage.
  Future<void> recoverSession() async {
    final jsonStr = await _localStorage.read(key: _persistantSessionKey);
    if (jsonStr == null || jsonStr == 'null') {
      await deleteSession();
      if (!statusKnown.isCompleted) {
        statusKnown.complete();
      }
      return;
    }

    try {
      final res = await _supabaseClient.auth.recoverSession(jsonStr);
      await setSessionString(json.encode(res.session!.toJson()));
      await _resetCache();
    } on PostgrestException catch (error) {
      await deleteSession();
      if (!statusKnown.isCompleted) {
        statusKnown.complete();
      }
      throw PlatformException(code: 'login error', message: error.message);
    } catch (error) {
      await deleteSession();
      throw PlatformException(code: 'login error', message: error.toString());
    }
  }

  /// Returns Persist Session String
  Future<String> signUp({
    required String email,
    required String password,
  }) async {
    try {
      final res = await _supabaseClient.auth.signUp(email: email, password: password);
      await _analytics.logSignUp(signUpMethod: 'email');
      return json.encode(res.session!.toJson());
    } on PostgrestException catch (error) {
      throw PlatformException(code: 'signup error', message: error.toString());
    }
  }

  /// Returns Persist Session String
  Future<String> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final res = await _supabaseClient.auth.signInWithPassword(email: email, password: password);
      await _analytics.logLogin(loginMethod: 'email');
      return json.encode(res.session!.toJson());
    } on PostgrestException catch (error) {
      throw PlatformException(code: 'login error', message: error.message);
    }
  }

  /// Get the logged in user's profile.
  Future<Profile?> getMyProfile() async {
    final userId = this.userId;
    if (userId == null) {
      throw PlatformException(code: 'not signed in ', message: 'Not signed in');
    }
    try {
      await getProfileDetail(userId);
      if (!myProfileHasLoaded.isCompleted) {
        myProfileHasLoaded.complete();
      }
    } on PostgrestException catch (error) {
      throw PlatformException(code: 'login error', message: error.message);
    }
    if (!statusKnown.isCompleted) {
      statusKnown.complete();
    }
    return null;
  }

  /// Get 5 closest videos from the current user's location.
  Future<void> getVideosFromLocation(LatLng location) async {
    try {
      final data = await _supabaseClient.rpc(
        'nearby_videos',
        params: {
          'location': 'POINT(${location.longitude} ${location.latitude})',
          'user_id': userId ?? _anonymousUUID,
        },
      ).limit(5);

      final videoIds = _mapVideos.map((video) => video.id);
      final newVideos = Video.videosFromData(data: data as List, userId: userId)
          .where((video) => !videoIds.contains(video.id));
      _mapVideos.addAll(newVideos);
      _mapVideosStreamConntroller.sink.add(_mapVideos);
    } on PostgrestException catch (error) {
      throw PlatformException(code: 'getVideosFromLocation error', message: error.message);
    }
  }

  /// Loads all videos inside a bounding box.
  Future<void> getVideosInBoundingBox(LatLngBounds bounds) async {
    try {
      final data = await _supabaseClient.rpc(
        'videos_in_bouding_box',
        params: {
          'min_lng': '${bounds.southwest.longitude}',
          'min_lat': '${bounds.southwest.latitude}',
          'max_lng': '${bounds.northeast.longitude}',
          'max_lat': '${bounds.northeast.latitude}',
          'user_id': userId ?? _anonymousUUID,
        },
      );

      final videoIds = _mapVideos.map((video) => video.id);
      final newVideos = Video.videosFromData(data: data as List, userId: userId)
          .where((video) => !videoIds.contains(video.id));
      _mapVideos.addAll(newVideos);
      _mapVideosStreamConntroller.sink.add(_mapVideos);
    } on PostgrestException catch (error) {
      throw PlatformException(code: 'getVideosFromLocation error', message: error.message);
    }
  }

  /// Get videos created by a certain user.
  Future<List<Video>> getVideosFromUid(String uid) async {
    try {
      final data = await _supabaseClient
          .from('videos')
          .select('id, user_id, created_at, url, image_url,'
              ' thumbnail_url, gif_url, description')
          .eq('user_id', uid)
          .order('created_at');
      return Video.videosFromData(data: data, userId: userId);
    } on PostgrestException catch (error) {
      throw PlatformException(code: 'getVideosFromUid error', message: error.message);
    }
  }

  /// Get list of videos that a certain user has liked.
  Future<List<Video>> getLikedPostsFromUid(String uid) async {
    try {
      final data =
          await _supabaseClient.from('liked_videos').select().eq('liked_by', uid).order('liked_at');
      return Video.videosFromData(data: data, userId: userId);
    } on PostgrestException catch (error) {
      throw PlatformException(code: 'getLikedPostsFromUid error', message: error.message);
    }
  }

  /// Get profile detail of a certain user.
  Future<void> getProfileDetail(String targetUid) async {
    if (profileDetailsCache[targetUid] != null) {
      return;
    }
    try {
      final data = await _supabaseClient.rpc(
        'profile_detail',
        params: {
          'my_user_id': userId ?? _anonymousUUID,
          'target_user_id': targetUid,
        },
      );

      if ((data as List).isEmpty) {
        _profileStreamController.sink.add(profileDetailsCache);
        return;
      }

      final profile = ProfileDetail.fromData(data[0] as Map<String, dynamic>);
      profileDetailsCache[targetUid] = profile;
      _profileStreamController.sink.add(profileDetailsCache);
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Database_Error',
        message: error.message,
      );
    } catch (error) {
      throw PlatformException(
        code: 'Unknown error',
      );
    }
  }

  /// Updates a profile of logged in user.
  Future<void> saveProfile({required Profile profile}) async {
    try {
      await _supabaseClient.from('users').upsert(profile.toMap());
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Database_Error',
        message: error.message,
      );
    }

    late final ProfileDetail newProfile;
    if (profileDetailsCache[userId!] != null) {
      newProfile = profileDetailsCache[userId!]!.copyWith(
        name: profile.name,
        description: profile.description,
        imageUrl: profile.imageUrl,
      );
    } else {
      // When the user initially registered
      _hasRefreshedSession = false;
      // ignore: unawaited_futures
      _resetCache();
      newProfile = ProfileDetail(
        id: userId!,
        name: profile.name,
        description: profile.description,
        imageUrl: profile.imageUrl,
        followerCount: 0,
        followingCount: 0,
        likeCount: 0,
        isFollowing: true,
      );
    }
    profileDetailsCache[userId!] = newProfile;
    _profileStreamController.add(profileDetailsCache);
  }

  /// Uploads the video and returns the download URL
  Future<String> uploadFile({
    required String bucket,
    required File file,
    required String path,
  }) async {
    try {
      await _supabaseClient.storage.from(bucket).upload(path, file);
      final urlRes = _supabaseClient.storage.from(bucket).getPublicUrl(path);
      return urlRes;
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'uploadFile',
        message: error.message,
      );
    }
  }

  /// Inserts a new row in `videos` table on Supabase.
  Future<void> saveVideo(Video creatingVideo) async {
    try {
      final data = await _supabaseClient.from('videos').insert([creatingVideo.toMap()]).select();
      final createdVideo = creatingVideo.updateId(id: data[0]['id'] as String);
      _mapVideos.add(createdVideo);
      _mapVideosStreamConntroller.sink.add(_mapVideos);
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'saveVideo',
        message: error.message,
      );
    }
    await _analytics.logEvent(name: 'post_video');
  }

  /// Loads a single video data and emits it on `videoDetailStream`
  Future<void> getVideoDetailStream(String videoId) async {
    _videoDetailStreamController.sink.add(null);
    final userId = _supabaseClient.auth.currentUser?.id;
    try {
      List<dynamic> data;
      if (userId != null) {
        data = await _supabaseClient
            .rpc('get_video_detail', params: {'video_id': videoId, 'user_id': userId});
      } else {
        data =
            await _supabaseClient.rpc('anonymous_get_video_detail', params: {'video_id': videoId});
      }

      var videoDetail = VideoDetail.fromData(
        data: Map.from(data[0] as Map<dynamic, dynamic>),
        userId: userId,
      );
      if (videoDetail.position != null) {
        final locationString = await _locationToString(videoDetail.position!);
        videoDetail = videoDetail.copyWith(locationString: locationString);
      }
      _videoDetails[videoId] = videoDetail;
      _videoDetailStreamController.sink.add(_videoDetails[videoId]);
      await _analytics.logEvent(
        name: 'view_video',
        parameters: {
          'video_id': videoId,
        },
      );
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Get Video Detail',
        message: error.message,
      );
    }
  }

  /// Inserts a new row in `likes` table
  /// and increments the like count of a video.
  Future<void> like(Video video) async {
    final videoId = video.id;
    final currentVideoDetail = _videoDetails[videoId]!;
    _videoDetails[videoId] =
        currentVideoDetail.copyWith(likeCount: currentVideoDetail.likeCount + 1, haveLiked: true);
    _videoDetailStreamController.sink.add(_videoDetails[videoId]);

    if (profileDetailsCache[video.userId] != null) {
      // Increment the like count of liked user by 1
      profileDetailsCache[video.userId] = profileDetailsCache[video.userId]!
          .copyWith(likeCount: profileDetailsCache[video.userId]!.likeCount + 1);
      _profileStreamController.add(profileDetailsCache);
    }

    final uid = _supabaseClient.auth.currentUser!.id;
    try {
      await _supabaseClient.from('likes').insert([
        VideoDetail.like(videoId: videoId, uid: uid),
      ]);
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Like Video',
        message: error.message,
      );
    }
    await _analytics.logEvent(
      name: 'like_video',
      parameters: {
        'video_id': videoId,
      },
    );
  }

  /// Deletes a row in `likes` table and decrements the like count of a video.
  Future<void> unlike(Video video) async {
    final videoId = video.id;
    final currentVideoDetail = _videoDetails[videoId]!;
    _videoDetails[videoId] = currentVideoDetail.copyWith(
      likeCount: currentVideoDetail.likeCount - 1,
      haveLiked: false,
    );
    _videoDetailStreamController.sink.add(_videoDetails[videoId]);

    if (profileDetailsCache[video.userId] != null) {
      // Decrement the like count of liked user by 1
      profileDetailsCache[video.userId] = profileDetailsCache[video.userId]!
          .copyWith(likeCount: profileDetailsCache[video.userId]!.likeCount - 1);
      _profileStreamController.add(profileDetailsCache);
    }

    final uid = _supabaseClient.auth.currentUser!.id;
    try {
      await _supabaseClient.from('likes').delete().eq('video_id', videoId).eq('user_id', uid);
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Unlike Video',
        message: error.message,
      );
    }

    await _analytics.logEvent(name: 'unlike_video', parameters: {
      'video_id': videoId,
    });
  }

  /// Loads comments of a video and emits it on a stream.
  Future<void> getComments(String videoId) async {
    try {
      final data = await _supabaseClient
          .from('video_comments')
          .select()
          .eq('video_id', videoId)
          .order('created_at');

      comments = Comment.commentsFromData(List.from(data));
      _commentsStreamController.sink.add(comments);
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Unlike Video',
        message: error.message,
      );
    }
    Future<Comment> replaceCommentText(Comment comment) async {
      final commentText = await replaceMentionsWithUserNames(comment.text);
      return comment.copyWith(text: commentText);
    }

    comments = await Future.wait(comments.map(replaceCommentText));
    _commentsStreamController.sink.add(comments);
    await _analytics.logEvent(name: 'view_comments', parameters: {
      'video_id': videoId,
    });
  }

  /// Inserts a new row in `comments` table.
  Future<void> postComment({
    required String text,
    required String videoId,
    required List<Profile> mentions,
  }) async {
    String commentId;
    try {
      final userId = _supabaseClient.auth.currentUser!.id;
      final res = await _supabaseClient
          .from('comments')
          .insert(Comment.create(text: text, userId: userId, videoId: videoId))
          .select();

      if (mentions.isEmpty) {
        return;
      }
      final data = List<Map<String, String>>.from(res);
      commentId = data[0]['id']!;
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'commet Video',
        message: error.message,
      );
    }
    try {
      await _supabaseClient.from('mentions').insert(
            mentions
                .where((mentionedProfile) => mentionedProfile.id != _videoDetails[videoId]?.userId)
                .map(
                  (profile) => {
                    'comment_id': commentId,
                    'user_id': profile.id,
                  },
                )
                .toList(),
          );
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'commet Video',
        message: error.message,
      );
    }
    await _analytics.logEvent(name: 'post_comment', parameters: {
      'video_id': videoId,
    });
  }

  /// Loads the 50 most recent notifications.
  Future<void> getNotifications() async {
    if (userId == null) {
      // If the user is not signed in, do not emit anything
      return;
    }
    try {
      final data = await _supabaseClient
          .from('notifications')
          .select()
          .eq('receiver_user_id', userId!)
          .not('action_user_id', 'eq', userId)
          .order('created_at')
          .limit(50);

      final timestampOfLastSeenNotification =
          await _localStorage.read(key: _timestampOfLastSeenNotification);
      DateTime? createdAtOfLastSeenNotification;
      if (timestampOfLastSeenNotification != null) {
        createdAtOfLastSeenNotification = DateTime.parse(timestampOfLastSeenNotification);
      }
      _notifications = AppNotification.fromData(data,
          createdAtOfLastSeenNotification: createdAtOfLastSeenNotification);
      _notificationsStreamController.sink.add(_notifications);
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'getNotifications',
        message: error.message,
      );
    }
    Future<AppNotification> _replaceCommentTextWithMentionedUserName(
      AppNotification notification,
    ) async {
      if (notification.commentText == null) {
        return notification;
      }
      final commentText = await replaceMentionsWithUserNames(notification.commentText!);
      return notification.copyWith(commentText: commentText);
    }

    _notifications =
        await Future.wait(_notifications.map(_replaceCommentTextWithMentionedUserName));
    _notificationsStreamController.sink.add(_notifications);
  }

  /// Blocks a certain user.
  Future<void> block(String blockedUserId) async {
    try {
      final uid = _supabaseClient.auth.currentUser!.id;
      await _supabaseClient.from('blocks').insert([
        {
          'user_id': uid,
          'blocked_user_id': blockedUserId,
        }
      ]);
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Unlike Video',
        message: error.message,
      );
    }
    _mapVideos.removeWhere((value) => value.userId == blockedUserId);
    _mapVideosStreamConntroller.sink.add(_mapVideos);
    await _analytics.logEvent(
      name: 'block_user',
      parameters: {
        'user_id': blockedUserId,
      },
    );
  }

  /// Reports a certain video.
  Future<void> report({
    required String videoId,
    required String reason,
  }) async {
    try {
      final uid = _supabaseClient.auth.currentUser!.id;
      await _supabaseClient.from('reports').insert({
        'user_id': uid,
        'video_id': videoId,
        'reason': reason,
      });
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Report Video Error',
        message: error.message,
      );
    }
    await _analytics.logEvent(
      name: 'report_video',
      parameters: {
        'video_id': videoId,
      },
    );
  }

  /// Deletes a certain video.
  Future<void> deleteVideo({required String videoId}) async {
    try {
      await _supabaseClient.from('videos').delete().eq('id', videoId);
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Delete Video',
        message: error.message,
      );
    }
    _mapVideos.removeWhere((video) => video.id == videoId);
    _mapVideosStreamConntroller.sink.add(_mapVideos);
    await _analytics.logEvent(
      name: 'delete_video',
      parameters: {
        'video_id': videoId,
      },
    );
  }

  /// Performs a keyword search of videos.
  Future<List<Video>> searchVideo(String queryString) async {
    final query = queryString.split(' ').map((word) => "'$word'").join(' & ');

    try {
      final res = await _supabaseClient
          .from('videos')
          .select('id, url, image_url, thumbnail_url, gif_url, '
              'description, user_id, created_at')
          .textSearch('description', query, config: 'english')
          .order('created_at')
          .limit(50);

      final data = res as List;
      await _analytics.logSearch(searchTerm: queryString);
      return Video.videosFromData(data: data, userId: userId);
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'Unlike Video',
        message: error.message,
      );
    }
  }

  /// Loads `VideoPlayerController` of a video.
  Future<VideoPlayerController> getVideoPlayerController(String url) async {
    return VideoPlayerController.network(url);
  }

  /// Returns whether the user has turned on location permission or not.
  Future<bool> hasLocationPermission() async {
    final result = await Geolocator.requestPermission();
    return result != LocationPermission.denied && result != LocationPermission.deniedForever;
  }

  /// Updates the timestamp of when the user has last seen notifications.
  ///
  /// Timestamp of when the user has last seen notifications is used to
  /// determine which notification is unread.
  Future<void> updateTimestampOfLastSeenNotification(DateTime time) async {
    await _localStorage.write(key: _timestampOfLastSeenNotification, value: time.toIso8601String());
  }

  /// Performs a keyword search of location within a map.
  Future<LatLng?> searchLocation(String searchQuery) async {
    try {
      final locations = await locationFromAddress(searchQuery);
      if (locations.isEmpty) {
        return null;
      }
      final location = locations.first;
      await _analytics.logEvent(name: 'search_location', parameters: {'search_term': searchQuery});
      return LatLng(location.latitude, location.longitude);
    } catch (e) {
      return null;
    }
  }

  /// Opens a share dialog to share the video on other social media or apps.
  Future<void> shareVideo(VideoDetail videoDetail) async {
    await Share.share('Check out this video on Spot http://spotvideo.app/post/${videoDetail.id}');
    await _analytics.logEvent(name: 'share_video', parameters: {'video_id': videoDetail.id});
  }

  /// Loads cached image file.
  ///
  /// Mainly used to get cached video thumbnail.
  Future<File> getCachedFile(String url) {
    return DefaultCacheManager().getSingleFile(url);
  }

  /// Loads suggested mentions from a given search query.
  Future<List<Profile>> getMentionSuggestions(String queryString) async {
    if (_mentionSuggestionCache[queryString] != null) {
      return _mentionSuggestionCache[queryString]!;
    }
    try {
      final res =
          await _supabaseClient.from('users').select().ilike('name', '%$queryString%').limit(2);

      final data = res as List<Map<dynamic, dynamic>>;
      final profiles =
          data.map<Profile>((row) => Profile.fromData(Map<String, dynamic>.from(row))).toList();
      _mentionSuggestionCache[queryString] = profiles;
      return profiles;
    } on PostgrestException catch (error) {
      throw PlatformException(code: 'Error finding mentionend users', message: error.message);
    }
  }

  /// Get all of the mentioned profiles in a comment
  List<Profile> getMentionedProfiles({
    required String commentText,
    required List<Profile> profilesInComments,
  }) {
    final userNames = commentText
        .split(' ')
        .where((word) => word.isNotEmpty && word[0] == '@')
        .map((word) => RegExp(r'^\w*').firstMatch(word.substring(1))!.group(0)!)
        .toList();

    /// Map where user name is the key and profile is the value
    final userNameMap = <String, Profile>{}
      ..addEntries(profilesInComments.map((profile) => MapEntry(profile.name, profile)))
      ..addEntries(profileDetailsCache.values
          .map<MapEntry<String, Profile>>((profile) => MapEntry(profile.name, profile)))
      ..addEntries(_mentionSuggestionCache.values
          .expand((i) => i)
          .toList()
          .map<MapEntry<String, Profile>>((profile) => MapEntry(profile.name, profile)));
    final mentionedProfiles = userNames
        .map<Profile?>((userName) => userNameMap[userName])
        .where((profile) => profile != null)
        .map<Profile>((profile) => profile!)
        .toList();
    return mentionedProfiles;
  }

  /// Replaces mentioned user names with users' id in comment text
  /// Called right before saving a new comment to the database
  String replaceMentionsInAComment({required String comment, required List<Profile> mentions}) {
    var mentionReplacedText = comment;
    for (final mention in mentions) {
      mentionReplacedText = mentionReplacedText.replaceAll('@${mention.name}', '@${mention.id}');
    }
    return mentionReplacedText;
  }

  /// Extracts the username to be searched within the database
  /// Called when a user is typing up a comment
  String? getMentionedUserName(String comment) {
    final mention = comment.split(' ').last;
    if (mention.isEmpty || mention[0] != '@') {
      return null;
    }
    final mentionedUserName = mention.substring(1);
    if (mentionedUserName.isEmpty) {
      return '@';
    }
    return mentionedUserName;
  }

  /// Returns list of userIds that are present in a comment
  List<String> getUserIdsInComment(String comment) {
    final regExp = RegExp(r'@[0-9a-f]{8}\b-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-\b[0-9a-f]{12}\b');
    final matches = regExp.allMatches(comment);
    return matches.map((match) => match.group(0)!.substring(1)).toList();
  }

  /// Replaces user ids found in comments with user names
  Future<String> replaceMentionsWithUserNames(
    String comment,
  ) async {
    await Future.wait(getUserIdsInComment(comment).map(getProfileDetail).toList());
    final regExp = RegExp(r'@[0-9a-f]{8}\b-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-\b[0-9a-f]{12}\b');
    final replacedComment = comment.replaceAllMapped(regExp, (match) {
      final key = match.group(0)!.substring(1);
      final name = profileDetailsCache[key]?.name;

      /// Return the original id if no profile was found with the id
      return '@${name ?? match.group(0)!.substring(1)}';
    });
    return replacedComment;
  }

  /// Calculate the z-index of a marker on a map.
  /// Newer videos have high z-index.
  /// It has a wierd formula so that it does not go
  /// over iOS's max z-index value.
  double getZIndex(DateTime createdAt) {
    return max(createdAt.millisecondsSinceEpoch ~/ 1000000 - 1600000, 0).toDouble();
  }

  /// Opens device's camera roll to find videos taken in the past.
  Future<File?> getVideoFile() async {
    try {
      final pickedVideo = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (pickedVideo != null) {
        return File(pickedVideo.path);
      }
    } catch (err) {
      debugPrint(err.toString());
    }
    return null;
  }

  /// Find the location attached to a video file from a video path.
  Future<LatLng?> getVideoLocation(String videoPath) async {
    final videoInfo = await FlutterVideoInfo().getVideoInfo(videoPath);
    final locationString = videoInfo?.location;
    if (locationString != null) {
      debugPrint(locationString);
      final matches = RegExp(r'(\+|\-)(\d*\.?\d*)').allMatches(locationString);
      final lat = double.parse(matches.elementAt(0).group(0)!);
      final lng = double.parse(matches.elementAt(1).group(0)!);
      return LatLng(lat, lng);
    }

    return null;
  }

  /// Loads list of 24 videos in desc createdAt order.
  Future<List<Video>> getNewVideos() async {
    try {
      final data = await _supabaseClient
          .from('videos')
          .select('id, url, image_url, thumbnail_url, gif_url,'
              ' description, user_id, created_at')
          .order('created_at')
          .limit(24);
      final videos = Video.videosFromData(data: data, userId: userId);
      return videos;
    } catch (error) {
      throw PlatformException(code: 'NewVideos', message: 'Error loading new videos');
    }
  }

  /// Follows a user.
  Future<void> follow(String followedUid) async {
    if (userId == null) {
      return;
    }
    if (profileDetailsCache[followedUid] != null) {
      profileDetailsCache[followedUid] =
          profileDetailsCache[followedUid]!.copyWith(isFollowing: true);
    }
    if (profileDetailsCache[userId!] != null) {
      // Update your own follow count
      profileDetailsCache[userId!] = profileDetailsCache[userId!]!
          .copyWith(followingCount: profileDetailsCache[userId!]!.followingCount + 1);
    }
    if (profileDetailsCache[followedUid] != null) {
      // Update the follow count of the user who have been followed
      profileDetailsCache[followedUid] = profileDetailsCache[followedUid]!
          .copyWith(followerCount: profileDetailsCache[followedUid]!.followerCount + 1);
    }
    _profileStreamController.add(profileDetailsCache);
    await _supabaseClient.from('follow').insert({
      'following_user_id': userId,
      'followed_user_id': followedUid,
    });
    await _analytics.logEvent(
      name: 'follow',
      parameters: {
        'following_user_id': userId,
        'followed_user_id': followedUid,
      },
    );
  }

  /// Unfollows a user.
  Future<void> unfollow(String followedUid) async {
    if (userId == null) {
      return;
    }
    if (profileDetailsCache[followedUid] != null) {
      profileDetailsCache[followedUid] =
          profileDetailsCache[followedUid]!.copyWith(isFollowing: false);
    }
    if (profileDetailsCache[userId!] != null) {
      // Update the user's follow count
      profileDetailsCache[userId!] = profileDetailsCache[userId!]!
          .copyWith(followingCount: profileDetailsCache[userId!]!.followingCount - 1);
    }
    if (profileDetailsCache[followedUid] != null) {
      // update the follow count of the user who have been followed
      profileDetailsCache[followedUid] = profileDetailsCache[followedUid]!
          .copyWith(followerCount: profileDetailsCache[followedUid]!.followerCount - 1);
    }
    _profileStreamController.add(profileDetailsCache);
    await _supabaseClient
        .from('follow')
        .delete()
        .eq('following_user_id', userId!)
        .eq('followed_user_id', followedUid);
    await _analytics.logEvent(
      name: 'unfollow',
      parameters: {
        'following_user_id': userId,
        'followed_user_id': followedUid,
      },
    );
  }

  Future<String> _locationToString(LatLng location) async {
    try {
      final placemarks = await placemarkFromCoordinates(location.latitude, location.longitude);
      if (placemarks.isEmpty) {
        return 'Unknown';
      }
      if (placemarks.first.administrativeArea == null) {
        return '${placemarks.first.name}';
      }
      return '${placemarks.first.administrativeArea}, '
          '${placemarks.first.country}';
    } catch (e) {
      return 'Unknown';
    }
  }

  /// Loads list of followers.
  Future<List<Profile>> getFollowers(String uid) async {
    try {
      // get followers of uid with is_following
      final data = await _supabaseClient.rpc(
        'followers',
        params: {
          'my_user_id': userId ?? _anonymousUUID,
          'target_user_id': uid,
        },
      );
      if ((data as List).isEmpty) {
        return [];
      }
      final profiles = Profile.fromList(List<Map<String, dynamic>>.from(data));
      return profiles;
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'getFollowers',
        message: error.message,
      );
    }
  }

  /// Loads list of followings.
  Future<List<Profile>> getFollowings(String uid) async {
    try {
      // get followers of uid with is_following
      final data = await _supabaseClient.rpc(
        'followings',
        params: {
          'my_user_id': userId ?? _anonymousUUID,
          'target_user_id': uid,
        },
      );
      if ((data as List).isEmpty) {
        return [];
      }
      final profiles = Profile.fromList(List<Map<String, dynamic>>.from(data));
      return profiles;
    } on PostgrestException catch (error) {
      throw PlatformException(
        code: error.code ?? 'getFollowings',
        message: error.message,
      );
    }
  }

  /// Get the current user's location.
  Future<LatLng> determinePosition() {
    return _locationProvider.determinePosition();
  }

  /// Open location settings page on the device.
  Future<bool> openLocationSettingsPage() {
    return _locationProvider.openLocationSettingsPage();
  }
}
