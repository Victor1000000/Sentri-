import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:sentri/features/location/place_lookup.dart';

void main() {
  group('names from the phone\'s place lookup', () {
    test('builds street, area, LGA, state and a nearby landmark', () {
      final p = placeFromPlacemarks([
        Placemark(
          name: 'Sango Motor Park',
          thoroughfare: 'Old Abeokuta Road',
          subLocality: 'Sango',
          locality: 'Ota',
          subAdministrativeArea: 'Ado-Odo/Ota',
          administrativeArea: 'Ogun State',
        ),
      ])!;
      expect(p.street, 'Old Abeokuta Road');
      expect(p.area, 'Sango');
      expect(p.lga, 'Ado-Odo/Ota');
      expect(p.state, 'Ogun');
      expect(p.landmark, 'Sango Motor Park');
      expect(p.label, 'Old Abeokuta Road, Sango, Ogun');
    });

    test('adds a house number to the street', () {
      final p = placeFromPlacemarks([Placemark(thoroughfare: 'Allen Avenue', subThoroughfare: '14', locality: 'Ikeja', administrativeArea: 'Lagos')])!;
      expect(p.street, '14 Allen Avenue');
      expect(p.label, '14 Allen Avenue, Ikeja, Lagos');
    });

    test('does not add a number that is already there, or a non-number', () {
      expect(placeFromPlacemarks([Placemark(thoroughfare: '14 Allen Avenue', subThoroughfare: '14', locality: 'Ikeja')])!.street, '14 Allen Avenue');
      expect(placeFromPlacemarks([Placemark(thoroughfare: 'Allen Avenue', subThoroughfare: 'Plot A', locality: 'Ikeja')])!.street, 'Allen Avenue');
    });

    test('falls back to the street line, and to the town when there is no district', () {
      final p = placeFromPlacemarks([Placemark(street: 'Ahmadu Bello Way', locality: 'Abuja', administrativeArea: 'Federal Capital Territory')])!;
      expect(p.street, 'Ahmadu Bello Way');
      expect(p.area, 'Abuja');
      expect(p.state, 'Federal Capital Territory');
    });

    test('tidies the LGA and state names', () {
      final p = placeFromPlacemarks([Placemark(thoroughfare: 'X Street', subAdministrativeArea: 'Ikeja Local Government Area', administrativeArea: 'Lagos State')])!;
      expect(p.lga, 'Ikeja');
      expect(p.state, 'Lagos');
      expect(placeFromPlacemarks([Placemark(thoroughfare: 'X Street', subAdministrativeArea: 'Eti-Osa LGA')])!.lga, 'Eti-Osa');
    });

    test('ignores a plus code used as a street or a name', () {
      final p = placeFromPlacemarks([Placemark(name: 'FHGM+X7', street: 'FHGM+X7', locality: 'Ota', administrativeArea: 'Ogun')])!;
      expect(p.street, isNull);
      expect(p.landmark, isNull);
      expect(p.label, 'Ota, Ogun');
    });

    test('does not call a house number, or a repeat of another part, a landmark', () {
      expect(placeFromPlacemarks([Placemark(name: '14', thoroughfare: 'Allen Avenue', locality: 'Ikeja')])!.landmark, isNull);
      expect(placeFromPlacemarks([Placemark(name: 'Allen Avenue', thoroughfare: '14 Allen Avenue', locality: 'Ikeja')])!.landmark, isNull);
      expect(placeFromPlacemarks([Placemark(name: 'Ikeja', thoroughfare: 'Allen Avenue', locality: 'Ikeja')])!.landmark, isNull);
    });

    test('takes the first non-empty value for each part across several results', () {
      final p = placeFromPlacemarks([
        Placemark(thoroughfare: '  ', locality: ''),
        Placemark(thoroughfare: 'Adeniran Ogunsanya Street', subLocality: 'Surulere', administrativeArea: 'Lagos'),
      ])!;
      expect(p.street, 'Adeniran Ogunsanya Street');
      expect(p.area, 'Surulere');
    });

    test('says nothing when there is nothing to say', () {
      expect(placeFromPlacemarks([]), isNull);
      expect(placeFromPlacemarks([Placemark()]), isNull);
      expect(placeFromPlacemarks([Placemark(name: 'Somewhere')]), isNull);
    });
  });
}
