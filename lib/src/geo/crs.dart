import 'dart:math' as math hide Point;
import 'dart:math' show Point;

import 'package:flutter_map/src/misc/bounds.dart';
import 'package:latlong2/latlong.dart';
import 'package:meta/meta.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;

/// An abstract representation of a
/// [Coordinate Reference System](https://bit.ly/3iVKpja).
///
/// The main objective of a CRS is to handle the conversion between surface
/// points of objects of different dimensions. In our case 3D and 2D objects.
@immutable
abstract class Crs {
  const Crs();

  String get code;

  Projection get projection;

  Transformation get transformation;

  /// Converts a point on the sphere surface (with a certain zoom) in a
  /// map point.
  Point<double> latLngToPoint(LatLng latlng, double zoom) {
    final projectedPoint = projection.project(latlng);
    return transformation.transform(projectedPoint, scale(zoom));
  }

  /// Converts a map point to the sphere coordinate (at a certain zoom).
  LatLng pointToLatLng(Point point, double zoom) =>
      projection.unproject(transformation.untransform(point, scale(zoom)));

  /// Zoom to Scale function.
  double scale(double zoom) => 256.0 * math.pow(2, zoom);

  /// Scale to Zoom function.
  double zoom(double scale) => math.log(scale / 256) / math.ln2;

  /// Rescales the bounds to a given zoom value.
  Bounds? getProjectedBounds(double zoom) {
    if (infinite) return null;

    final b = projection.bounds!;
    final s = scale(zoom);
    final min = transformation.transform(b.min, s);
    final max = transformation.transform(b.max, s);
    return Bounds(min, max);
  }

  bool get infinite;

  (double, double)? get wrapLng;

  (double, double)? get wrapLat;
}

// Custom CRS for non geographical maps
@immutable
class CrsSimple extends Crs {
  @override
  final String code = 'CRS.SIMPLE';

  @override
  final Projection projection;

  @override
  final Transformation transformation;

  const CrsSimple()
      : projection = const _LonLat(),
        transformation = const Transformation(1, 0, -1, 0),
        super();

  @override
  bool get infinite => false;

  @override
  (double, double)? get wrapLat => null;

  @override
  (double, double)? get wrapLng => null;
}

@immutable
abstract class Earth extends Crs {
  @override
  bool get infinite => false;

  @override
  final (double, double) wrapLng = const (-180, 180);

  @override
  final (double, double)? wrapLat = null;

  const Earth() : super();
}

/// The most common CRS used for rendering maps.
@immutable
class Epsg3857 extends Earth {
  @override
  final String code = 'EPSG:3857';

  @override
  final Projection projection;

  @override
  final Transformation transformation;

  static const double _scale = 0.5 / (math.pi * SphericalMercator.r);

  const Epsg3857()
      : projection = const SphericalMercator(),
        transformation = const Transformation(_scale, 0.5, -_scale, 0.5),
        super();

// Epsg3857 seems to have latitude limits. https://epsg.io/3857
//@override
//(double, double) get wrapLat => const (-85.06, 85.06);
}

/// A common CRS among GIS enthusiasts. Uses simple Equirectangular projection.
@immutable
class Epsg4326 extends Earth {
  @override
  final String code = 'EPSG:4326';

  @override
  final Projection projection;

  @override
  final Transformation transformation;

  const Epsg4326()
      : projection = const _LonLat(),
        transformation = const Transformation(1 / 180, 1, -1 / 180, 0.5),
        super();
}

/// Custom CRS
@immutable
class Proj4Crs extends Crs {
  @override
  final String code;

  @override
  final Projection projection;

  @override
  final Transformation transformation;

  @override
  final bool infinite;

  @override
  final (double, double)? wrapLat = null;

  @override
  final (double, double)? wrapLng = null;

  final List<Transformation>? _transformations;

  final List<double> _scales;

  const Proj4Crs._({
    required this.code,
    required this.projection,
    required this.transformation,
    required this.infinite,
    List<Transformation>? transformations,
    required List<double> scales,
  })  : _transformations = transformations,
        _scales = scales;

  factory Proj4Crs.fromFactory({
    required String code,
    required proj4.Projection proj4Projection,
    Transformation? transformation,
    List<Point<double>>? origins,
    Bounds<double>? bounds,
    List<double>? scales,
    List<double>? resolutions,
  }) {
    final projection =
        _Proj4Projection(proj4Projection: proj4Projection, bounds: bounds);
    List<Transformation>? transformations;
    final infinite = null == bounds;
    List<double> finalScales;

    if (null != scales && scales.isNotEmpty) {
      finalScales = scales;
    } else if (null != resolutions && resolutions.isNotEmpty) {
      finalScales = resolutions.map((r) => 1 / r).toList(growable: false);
    } else {
      throw Exception(
          'Please provide scales or resolutions to determine scales');
    }

    if (null == origins || origins.isEmpty) {
      transformation ??= const Transformation(1, 0, -1, 0);
    } else {
      if (origins.length == 1) {
        final origin = origins[0];
        transformation = Transformation(1, -origin.x, -1, origin.y);
      } else {
        transformations =
            origins.map((p) => Transformation(1, -p.x, -1, p.y)).toList();
        transformation = null;
      }
    }

    return Proj4Crs._(
      code: code,
      projection: projection,
      transformation: transformation!,
      infinite: infinite,
      transformations: transformations,
      scales: finalScales,
    );
  }

  /// Converts a point on the sphere surface (with a certain zoom) in a
  /// map point.
  @override
  Point<double> latLngToPoint(LatLng latlng, double zoom) {
    final projectedPoint = projection.project(latlng);
    final scale = this.scale(zoom);
    final transformation = _getTransformationByZoom(zoom);

    return transformation.transform(projectedPoint, scale);
  }

  /// Converts a map point to the sphere coordinate (at a certain zoom).
  @override
  LatLng pointToLatLng(Point point, double zoom) => projection.unproject(
      _getTransformationByZoom(zoom).untransform(point, scale(zoom)));

  /// Rescales the bounds to a given zoom value.
  @override
  Bounds? getProjectedBounds(double zoom) {
    if (infinite) return null;

    final b = projection.bounds!;
    final s = scale(zoom);

    final transformation = _getTransformationByZoom(zoom);

    final min = transformation.transform(b.min, s);
    final max = transformation.transform(b.max, s);
    return Bounds(min, max);
  }

  /// Zoom to Scale function.
  @override
  double scale(double zoom) {
    final iZoom = zoom.floor();
    if (zoom == iZoom) {
      return _scales[iZoom];
    } else {
      // Non-integer zoom, interpolate
      final baseScale = _scales[iZoom];
      final nextScale = _scales[iZoom + 1];
      final scaleDiff = nextScale - baseScale;
      final zDiff = zoom - iZoom;
      return baseScale + scaleDiff * zDiff;
    }
  }

  /// Scale to Zoom function.
  @override
  double zoom(double scale) {
    // Find closest number in _scales, down
    final downScale = _closestElement(_scales, scale);
    if (downScale == null) {
      return double.negativeInfinity;
    }
    final downZoom = _scales.indexOf(downScale);
    // Check if scale is downScale => return array index
    if (scale == downScale) {
      return downZoom.toDouble();
    }
    // Interpolate
    final nextZoom = downZoom + 1;
    final nextScale = _scales[nextZoom];

    final scaleDiff = nextScale - downScale;
    return (scale - downScale) / scaleDiff + downZoom;
  }

  /// Get the closest lowest element in an array
  double? _closestElement(List<double> array, double element) {
    double? low;
    for (var i = array.length - 1; i >= 0; i--) {
      final curr = array[i];

      if (curr <= element && (null == low || low < curr)) {
        low = curr;
      }
    }
    return low;
  }

  /// returns Transformation object based on zoom
  Transformation _getTransformationByZoom(double zoom) {
    final transformations = _transformations;
    if (transformations == null || transformations.isEmpty) {
      return transformation;
    }

    final iZoom = zoom.round();
    final lastIdx = transformations.length - 1;

    return transformations[iZoom > lastIdx ? lastIdx : iZoom];
  }
}

@immutable
abstract class Projection {
  const Projection();

  Bounds<double>? get bounds;

  Point<double> project(LatLng latlng);

  LatLng unproject(Point point);

  double _inclusive(double start, double end, double value) {
    if (value < start) return start;
    if (value > end) return end;

    return value;
  }

  @protected
  double inclusiveLat(double value) {
    return _inclusive(-90, 90, value);
  }

  @protected
  double inclusiveLng(double value) {
    return _inclusive(-180, 180, value);
  }
}

class _LonLat extends Projection {
  static final Bounds<double> _bounds = Bounds<double>(
      const Point<double>(-180, -90), const Point<double>(180, 90));

  const _LonLat() : super();

  @override
  Bounds<double> get bounds => _bounds;

  @override
  Point<double> project(LatLng latlng) {
    return Point(latlng.longitude, latlng.latitude);
  }

  @override
  LatLng unproject(Point point) {
    return LatLng(
        inclusiveLat(point.y.toDouble()), inclusiveLng(point.x.toDouble()));
  }
}

@immutable
class SphericalMercator extends Projection {
  static const int r = 6378137;
  static const double maxLatitude = 85.0511287798;
  static const double _boundsD = r * math.pi;
  static final Bounds<double> _bounds = Bounds<double>(
    const Point<double>(-_boundsD, -_boundsD),
    const Point<double>(_boundsD, _boundsD),
  );

  const SphericalMercator() : super();

  @override
  Bounds<double> get bounds => _bounds;

  @override
  Point<double> project(LatLng latlng) {
    const d = math.pi / 180;
    final lat = latlng.latitude.clamp(-maxLatitude, maxLatitude);
    final sin = math.sin(lat * d);

    return Point(
      r * d * latlng.longitude,
      r / 2 * math.log((1 + sin) / (1 - sin)),
    );
  }

  @override
  LatLng unproject(Point point) {
    const d = 180 / math.pi;
    return LatLng(
        inclusiveLat(
            (2 * math.atan(math.exp(point.y / r)) - (math.pi / 2)) * d),
        inclusiveLng(point.x * d / r));
  }
}

@immutable
class _Proj4Projection extends Projection {
  final proj4.Projection epsg4326;

  final proj4.Projection proj4Projection;

  @override
  final Bounds<double>? bounds;

  _Proj4Projection({
    required this.proj4Projection,
    this.bounds,
  }) : epsg4326 = proj4.Projection.WGS84;

  @override
  Point<double> project(LatLng latlng) {
    final point = epsg4326.transform(
        proj4Projection, proj4.Point(x: latlng.longitude, y: latlng.latitude));

    return Point(point.x, point.y);
  }

  @override
  LatLng unproject(Point point) {
    final point2 = proj4Projection.transform(
        epsg4326, proj4.Point(x: point.x.toDouble(), y: point.y.toDouble()));

    return LatLng(inclusiveLat(point2.y), inclusiveLng(point2.x));
  }
}

@immutable
class Transformation {
  final double a;
  final double b;
  final double c;
  final double d;

  const Transformation(this.a, this.b, this.c, this.d);

  Point<double> transform(Point point, double? scale) {
    scale ??= 1.0;
    final x = scale * (a * point.x + b);
    final y = scale * (c * point.y + d);
    return Point(x, y);
  }

  Point<double> untransform(Point point, double? scale) {
    scale ??= 1.0;
    final x = (point.x / scale - b) / a;
    final y = (point.y / scale - d) / c;
    return Point(x, y);
  }
}
