import 'dart:async';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:meta/meta.dart';
import 'package:spot/models/profile.dart';
import 'package:spot/repositories/repository.dart';

part 'profile_state.dart';

/// Cubit that manages user profile
class ProfileCubit extends Cubit<ProfileState> {
  /// Cubit that manages user profile
  ProfileCubit({
    required Repository repository,
  })  : _repository = repository,
        super(ProfileLoading());

  final Repository _repository;
  ProfileDetail? _profile;

  StreamSubscription<Map<String, Profile>>? _subscription;

  List<Profile> _followerOrFollowingList = [];

  @override
  Future<void> close() {
    _subscription?.cancel();
    return super.close();
  }

  /// Get the logged in user's profile
  Future<void> loadMyProfile() async {
    await _repository.myProfileHasLoaded.future;
    final uid = _repository.userId!;
    await loadProfile(uid);
  }

  /// Used in EditProfilePage to get profile if it's available
  Future<void> loadMyProfileIfExists() async {
    final uid = _repository.userId!;
    await loadProfile(uid);
  }

  /// Get a profile of user where the user ID is `targetUid`
  Future<void> loadProfile(String targetUid) async {
    try {
      await _repository.getProfileDetail(targetUid);
      _subscription = _repository.profileStream.listen((profiles) {
        _profile = profiles[targetUid];
        if (_profile == null) {
          emit(ProfileNotFound());
        } else {
          emit(ProfileLoaded(_profile!));
        }
      });
    } catch (err) {
      emit(ProfileError());
    }
  }

  /// update profile of the logged in user
  Future<void> saveProfile({
    required String name,
    required String description,
    required File? imageFile,
  }) async {
    try {
      final userId = _repository.userId;
      if (userId == null) {
        throw PlatformException(
          code: 'Auth_Error',
          message: 'Session has expired',
        );
      }
      emit(ProfileLoading());
      String? imageUrl;
      if (imageFile != null) {
        final imagePath =
            '$userId/profile${DateTime.now().millisecondsSinceEpoch}.${imageFile.path.split('.').last}';
        imageUrl = await _repository.uploadFile(
          bucket: 'profiles',
          file: imageFile,
          path: imagePath,
        );
      }

      return _repository.saveProfile(
        profile: Profile(
          id: userId,
          name: name,
          description: description,
          imageUrl: imageUrl,
        ),
      );
    } catch (err) {
      emit(ProfileError());
      rethrow;
    }
  }

  /// Follow the user where user ID is `followedUid`
  Future<void> follow(String followedUid) {
    if (_followerOrFollowingList.isNotEmpty) {
      // Update the follow state within _followerOrFollowingList
      final index = _followerOrFollowingList.indexWhere((profile) => profile.id == followedUid);
      _followerOrFollowingList[index] = _followerOrFollowingList[index].copyWith(isFollowing: true);
      emit(FollowerOrFollowingLoaded(_followerOrFollowingList));
    }
    return _repository.follow(followedUid);
  }

  /// Unfollow the user where user ID is `followedUid`
  Future<void> unfollow(String followedUid) {
    if (_followerOrFollowingList.isNotEmpty) {
      // Update the follow state within _followerOrFollowingList
      final index = _followerOrFollowingList.indexWhere((profile) => profile.id == followedUid);
      _followerOrFollowingList[index] =
          _followerOrFollowingList[index].copyWith(isFollowing: false);
      emit(FollowerOrFollowingLoaded(_followerOrFollowingList));
    }
    return _repository.unfollow(followedUid);
  }

  /// Load list of followers or following
  Future<void> loadFollowersOrFllowings({
    required String uid,
    required bool isLoadingFollowers,
  }) async {
    try {
      if (isLoadingFollowers) {
        _followerOrFollowingList = await _repository.getFollowers(uid);
      } else {
        _followerOrFollowingList = await _repository.getFollowings(uid);
      }
      emit(FollowerOrFollowingLoaded(_followerOrFollowingList));
    } catch (e) {
      emit(ProfileError());
    }
  }
}
