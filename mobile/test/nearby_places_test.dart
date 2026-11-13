import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:sentri/features/map/nearby_places.dart';

void main() {
  test('parseOverpass keeps named businesses and drops street furniture', () {
    const body = '''
{"elements":[
 {"type":"node","id":1,"lat":6.45,"lon":3.39,"tags":{"name":"Mega Plaza","shop":"electronics"}},
 {"type":"way","id":2,"lat":0,"lon":0,"center":{"lat":6.46,"lon":3.40},"tags":{"name":" Ikeja City Mall ","shop":"mall"}},
 {"type":"node","id":3,"lat":6.47,"lon":3.41,"tags":{"name":"Bodyline Gym","leisure":"fitness_centre"}},
 {"type":"node","id":4,"lat":6.48,"lon":3.42,"tags":{"name":"Guest Lodge","tourism":"hotel"}},
 {"type":"node","id":5,"lat":6.49,"lon":3.43,"tags":{"amenity":"bench"}},
 {"type":"node","id":6,"lat":6.50,"lon":3.44,"tags":{"amenity":"fuel"}},
 {"type":"node","id":7,"lat":6.51,"lon":3.45}
]}
''';
    final places = NearbyPlaces.parseOverpass(body);
    final names = [for (final p in places) p.name];
    expect(names, contains('Mega Plaza'));
    expect(names, contains('Ikeja City Mall')); // trimmed
    expect(names, contains('Bodyline Gym'));
    expect(names, contains('Guest Lodge'));
    expect(names, isNot(contains('fuel')),
        reason: 'an amenity with no name is not a destination - the list shows named places only');
    expect(names, isNot(contains('bench')),
        reason: 'benches, bins, parking and the like are not what a person is navigating to');
    final mall = places.firstWhere((p) => p.name == 'Ikeja City Mall');
    expect(mall.lat, 6.46);
    expect(mall.lon, 3.40);
    // kindLabel passes shop values it does not have a friendlier word for straight
    // through ('mall'), which is by design - the UI words it, not the parser.
    expect(mall.kind, 'mall');
    final gym = places.firstWhere((p) => p.name == 'Bodyline Gym');
    expect(gym.kind, 'gym');
    final hotel = places.firstWhere((p) => p.name == 'Guest Lodge');
    expect(hotel.kind, 'hotel');
  });

  test('parseOverpass survives broken input and dedupes the same shop', () {
    expect(NearbyPlaces.parseOverpass('not json'), isEmpty);
    expect(NearbyPlaces.parseOverpass('{"elements": []}'), isEmpty);
    const dup = '''
{"elements":[
 {"type":"node","id":1,"lat":6.45,"lon":3.39,"tags":{"name":"X Bar","amenity":"bar"}},
 {"type":"way","id":2,"center":{"lat":6.4500001,"lon":3.3900001},"tags":{"name":"X Bar","amenity":"bar"}}
]}
''';
    expect(NearbyPlaces.parseOverpass(dup).length, 1);
  });

  test('kindLabel maps everyday kinds', () {
    expect(NearbyPlaces.kindLabel({'leisure': 'fitness_centre'}), 'gym');
    expect(NearbyPlaces.kindLabel({'shop': 'marketplace'}), 'market');
    expect(NearbyPlaces.kindLabel({'tourism': 'guest_house'}), 'hotel');
    expect(NearbyPlaces.kindLabel({'amenity': 'fuel'}), 'petrol');
  });
}
