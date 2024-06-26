import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_feather_icons/flutter_feather_icons.dart';
import 'package:google_maps_cluster_manager/google_maps_cluster_manager.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:spot/components/gradient_border.dart';
import 'package:spot/cubits/videos/videos_cubit.dart';
import 'package:spot/models/video.dart';
import 'package:spot/pages/view_video_page.dart';
import 'package:spot/repositories/repository.dart';
import 'package:spot/utils/constants.dart';

/// Map with video thumbnails.
class MapTab extends StatelessWidget {
  /// Map with video thumbnails.
  const MapTab({Key? key}) : super(key: key);

  /// Method ot create this page with necessary `BlocProvider`
  static Widget create() {
    return BlocProvider<VideosCubit>(
      create: (context) => VideosCubit(
        repository: RepositoryProvider.of<Repository>(context),
      )..loadInitialVideos(),
      child: const MapTab(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<VideosCubit, VideosState>(
      builder: (context, state) {
        if (state is VideosInitial) {
          return preloader;
        } else if (state is VideosLoading) {
          return Map(
            location: state.location,
            isLoading: true,
          );
        } else if (state is VideosLoaded) {
          return Map(videos: state.videos);
        } else if (state is VideosLoadingMore) {
          final videos = state.videos;
          return Map(
            videos: videos,
            isLoading: true,
          );
        } else if (state is VideosError) {
          return const Center(child: Text('Something went wrong'));
        }
        throw UnimplementedError();
      },
    );
  }
}

/// Main view of MapTab.
@visibleForTesting
class Map extends StatefulWidget {
  /// Main view of MapTab.
  Map({
    Key? key,
    List<Video>? videos,
    LatLng? location,
    bool? isLoading,
  })  : _videos = videos ?? [],
        _location = location ?? const LatLng(0, 0),
        _isLoading = isLoading ?? false,
        super(key: key);

  final List<Video> _videos;
  final LatLng _location;
  final bool _isLoading;

  @override
  MapState createState() => MapState();
}

/// State of Map widget. Made public for testing purposes.
@visibleForTesting
class MapState extends State<Map> {
  final Completer<GoogleMapController> _mapController = Completer<GoogleMapController>();

  /// Holds all the markers for the map
  Set<Marker> _markers = <Marker>{};

  late final ClusterManager<Video> _clusterManager;

  /// false if there hasn't been marker being loaded yet
  var _hasLoadedMarkers = false;

  var _loading = false;

  final TextEditingController _citySearchQueryController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        GoogleMap(
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          markers: _markers,
          mapType: MapType.normal,
          zoomControlsEnabled: false,
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          initialCameraPosition: CameraPosition(
            target: widget._location,
            zoom: 16,
          ),
          onCameraIdle: () async {
            _clusterManager.updateMap();
            if (_loading) {
              return;
            }

            _loading = true;
            // Finds the center of the map and load videos around that location
            final mapController = await _mapController.future;
            final bounds = await mapController.getVisibleRegion();
            await BlocProvider.of<VideosCubit>(context).loadVideosWithinBoundingBox(bounds);
            _loading = false;
          },
          onMapCreated: (GoogleMapController mapController) {
            try {
              _mapController.complete(mapController);
              mapController.setMapStyle(mapTheme);
              _clusterManager.setMapId(mapController.mapId);
            } catch (e) {
              context.showErrorSnackbar('Error setting map style');
            }
          },
          onCameraMove: _clusterManager.onCameraMove,
        ),
        Positioned(
          top: 10 + MediaQuery.of(context).padding.top,
          left: 36,
          right: 36 + (Theme.of(context).platform == TargetPlatform.android ? 36 : 0),
          child: _searchBar(context),
        ),
        if (widget._isLoading)
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12, right: 12),
              child: const SizedBox(
                width: 30,
                height: 30,
                child: preloader,
              ),
            ),
          ),
      ],
    );
  }

  Widget _searchBar(BuildContext context) {
    return GradientBorder(
      borderRadius: 50,
      strokeWidth: 1,
      gradient: redOrangeGradient,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF000000)
              .withOpacity(_citySearchQueryController.text.isEmpty ? 0.15 : 0.5),
          borderRadius: const BorderRadius.all(Radius.circular(50)),
        ),
        child: Row(
          children: [
            const Icon(FeatherIcons.search),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _citySearchQueryController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Search by city',
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                textInputAction: TextInputAction.search,
                onEditingComplete: () async {
                  final currentFocus = FocusScope.of(context);
                  if (!currentFocus.hasPrimaryFocus) {
                    currentFocus.unfocus();
                  }
                  final location = await RepositoryProvider.of<Repository>(context)
                      .searchLocation(_citySearchQueryController.text);
                  if (location == null) {
                    context.showSnackbar('Could not find the location');
                    return;
                  }
                  final mapController = await _mapController.future;
                  await mapController.moveCamera(CameraUpdate.newLatLng(location));
                },
              ),
            ),
            if (_citySearchQueryController.text.isNotEmpty)
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    setState(_citySearchQueryController.clear);
                  },
                  icon: const Icon(Icons.close),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant Map oldWidget) {
    _createMarkers(videos: widget._videos, context: context)
        .then((_) => _initiallyMoveCameraToShowAllMarkers());
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    _clusterManager = ClusterManager<Video>(
      widget._videos,
      (markers) {
        setState(() {
          _markers = markers;
        });
      },
      levels: const [
        1,
        4.25,
        6.75,
        8.25,
        11.5,
        12.8,
        14.5,
        15.3,
        16.0,
        16.5,
        17.0,
        17.5,
        18.0,
        19.0,
        20.0,
      ],
      markerBuilder: _markerBuilder,
      stopClusteringZoom: 20,
    );

    _citySearchQueryController.addListener(_updateUI);
    super.initState();
  }

  Future<Marker> Function(Cluster<Video>) get _markerBuilder => (cluster) async {
        final items = cluster.items.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final target = items.first.copyWith(position: cluster.location);
        return _createMarkerFromVideo(
          video: target,
          factor: _getMapFactor(),
          clusterCount: cluster.items.length,
        );
      };
  @override
  void dispose() {
    _citySearchQueryController
      ..removeListener(_updateUI)
      ..dispose();
    super.dispose();
  }

  void _updateUI() {
    setState(() {});
  }

  Future<void> _initiallyMoveCameraToShowAllMarkers() async {
    final videos = widget._videos;
    if (videos.isEmpty) {
      return;
    }
    if (_hasLoadedMarkers) {
      return;
    }
    _hasLoadedMarkers = true;
    final mapController = await _mapController.future;
    if (videos.length == 1) {
      // If there is only 1 marker, move camera to centre that marker
      return mapController.moveCamera(CameraUpdate.newLatLng(videos.first.position!));
    }
    final cordinatesList = List<LatLng>.from(videos.map((video) => video.position))
      ..sort((a, b) => b.latitude.compareTo(a.latitude));
    final northernLatitude = cordinatesList.first.latitude;
    cordinatesList.sort((a, b) => a.latitude.compareTo(b.latitude));
    final southernLatitude = cordinatesList.first.latitude;
    cordinatesList.sort((a, b) => b.longitude.compareTo(a.longitude));
    final easternLongitude = cordinatesList.first.longitude;
    cordinatesList.sort((a, b) => a.longitude.compareTo(b.longitude));
    final westernLongitude = cordinatesList.first.longitude;
    final bounds = LatLngBounds(
      northeast: LatLng(northernLatitude, easternLongitude),
      southwest: LatLng(southernLatitude, westernLongitude),
    );
    return mapController.animateCamera(CameraUpdate.newLatLngBounds(bounds, 40));
  }

  Future<void> _createMarkers({
    required List<Video> videos,
    required BuildContext context,
  }) async {
    _clusterManager.setItems(videos);
  }

  /// Get factor of marker size depending on device's pixel ratio
  int _getMapFactor() {
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    var factor = 1;
    if (devicePixelRatio >= 3.5) {
      factor = 4;
    } else if (devicePixelRatio >= 2.5) {
      factor = 3;
    } else if (devicePixelRatio >= 1.5) {
      factor = 2;
    }
    return factor;
  }

  /// Get markers' actual size
  double _getMarkerSize(int factor) => factor * defaultMarkerSize;

  Future<Marker> _createMarkerFromVideo({
    required Video video,
    required int factor,
    required int clusterCount,
  }) async {
    final onTap = () {
      Navigator.of(context).push(ViewVideoPage.route(videoId: video.id));
    };
    final markerSize = _getMarkerSize(_getMapFactor());

    final imagePadding = borderWidth * factor;
    final imageSize = markerSize - imagePadding * 2;

    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);
    final boundingRect = Rect.fromLTWH(0.0, 0.0, markerSize, markerSize);
    final centerOffset = Offset(markerSize / 2, markerSize / 2);

    /// Adding gradient to the background of the marker
    final paint = Paint();
    if (video.isFollowing) {
      paint.shader = redOrangeGradient.createShader(boundingRect);
    } else {
      paint.shader = blueGradient.createShader(boundingRect);
    }

    // start adding images
    final imageFile =
        await RepositoryProvider.of<Repository>(context).getCachedFile(video.thumbnailUrl);

    final imageBytes = await imageFile.readAsBytes();
    final imageCodec = await ui.instantiateImageCodec(
      imageBytes,
      targetWidth: imageSize.toInt(),
      targetHeight: imageSize.toInt(),
    );
    final frameInfo = await imageCodec.getNextFrame();
    final byteData = await frameInfo.image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (byteData == null) {
      throw PlatformException(code: 'byteData null', message: 'byteData is null');
    }
    final resizedMarkerImageBytes = byteData.buffer.asUint8List();
    final image = await _loadImage(Uint8List.view(resizedMarkerImageBytes.buffer));

    canvas
      ..drawCircle(centerOffset, markerSize / 2, paint)
      ..saveLayer(boundingRect, paint)
      ..drawCircle(centerOffset, imageSize / 2, paint)
      ..drawImage(image, Offset(imagePadding, imagePadding), paint..blendMode = BlendMode.srcIn)
      ..restore();

    if (clusterCount > 1) {
      final counterOffset = Offset(markerSize * 7 / 8, markerSize / 8);
      final boundingRect =
          Rect.fromCenter(center: counterOffset, width: markerSize / 4, height: markerSize / 4);
      final clusterCountBackgroundPaint = Paint()
        ..shader = redOrangeGradient.createShader(boundingRect);
      final span = TextSpan(
        style: TextStyle(
          color: const Color(0xFFFFFFFF),
          fontSize: 12.0 * factor,
          letterSpacing: -1.0 * factor,
        ),
        text: '$clusterCount',
      );
      final textPainter = TextPainter(
        text: span,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.drawCircle(counterOffset, markerSize / 8, clusterCountBackgroundPaint);
      textPainter.paint(
          canvas, counterOffset.translate(-textPainter.width / 2, -textPainter.height / 2));
    }

    final img =
        await pictureRecorder.endRecording().toImage(markerSize.toInt(), markerSize.toInt());

    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw PlatformException(
        code: 'marker error',
        message: 'Error while creating byteData',
      );
    }
    final markerIcon = data.buffer.asUint8List();

    final marker = Marker(
      anchor: const Offset(0.5, 0.5),
      onTap: onTap,
      consumeTapEvents: true,
      markerId: MarkerId(video.id),
      position: video.position!,
      icon: BitmapDescriptor.fromBytes(markerIcon),
      zIndex: RepositoryProvider.of<Repository>(context).getZIndex(video.createdAt),
    );

    return marker;
  }

  Future<ui.Image> _loadImage(Uint8List img) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(img, completer.complete);
    return completer.future;
  }
}
