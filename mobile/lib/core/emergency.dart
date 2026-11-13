/// The world's emergency lines and the country behind a phone number. The app is
/// global now (v40): a number typed anywhere should land in the right country, and
/// the Police tab should offer the lines that actually answer there.
///
/// Honest note on the numbers: official lines get reorganised, and coverage varies
/// inside large countries. 112 reaches emergency services across most of Europe and
/// on GSM networks in many other places. The table carries the best-known public
/// line per service; the Police tab says so next to the numbers.
class SentriCountry {
  const SentriCountry(this.iso, this.dial, this.name, this.flag, this.police, this.fire, this.ambulance);
  final String iso; // ISO 3166-1 alpha-2, lowercase ('ng')
  final String dial; // international dial code without the plus ('234')
  final String name; // English name ('Nigeria')
  final String flag; // the flag, as a regional-indicator emoji ('🇳🇬')
  final String police;
  final String fire;
  final String ambulance;
}

const sentriCountries = <SentriCountry>[
  // Africa
  SentriCountry('ng', '234', 'Nigeria', '🇳🇬', '112', '199', '112'),
  SentriCountry('gh', '233', 'Ghana', '🇬🇭', '191', '192', '193'),
  SentriCountry('ke', '254', 'Kenya', '🇰🇪', '999', '999', '999'),
  SentriCountry('tz', '255', 'Tanzania', '🇹🇿', '112', '112', '112'),
  SentriCountry('ug', '256', 'Uganda', '🇺🇬', '999', '999', '999'),
  SentriCountry('za', '27', 'South Africa', '🇿🇦', '10111', '10177', '10177'),
  SentriCountry('zw', '263', 'Zimbabwe', '🇿🇼', '999', '993', '994'),
  SentriCountry('zm', '260', 'Zambia', '🇿🇲', '999', '993', '991'),
  SentriCountry('mw', '265', 'Malawi', '🇲🇼', '997', '999', '998'),
  SentriCountry('et', '251', 'Ethiopia', '🇪🇹', '991', '939', '907'),
  SentriCountry('eg', '20', 'Egypt', '🇪🇬', '122', '180', '123'),
  SentriCountry('ma', '212', 'Morocco', '🇲🇦', '19', '15', '15'),
  SentriCountry('dz', '213', 'Algeria', '🇩🇿', '17', '14', '14'),
  SentriCountry('tn', '216', 'Tunisia', '🇹🇳', '197', '198', '190'),
  SentriCountry('sn', '221', 'Senegal', '🇸🇳', '17', '18', '15'),
  SentriCountry('ci', '225', "Côte d'Ivoire", '🇨🇮', '170', '180', '185'),
  SentriCountry('cm', '237', 'Cameroon', '🇨🇲', '117', '118', '119'),
  SentriCountry('cd', '243', 'DR Congo', '🇨🇩', '112', '112', '112'),
  SentriCountry('ao', '244', 'Angola', '🇦🇴', '112', '112', '112'),
  SentriCountry('mz', '258', 'Mozambique', '🇲🇿', '112', '112', '112'),
  SentriCountry('rw', '250', 'Rwanda', '🇷🇼', '112', '112', '112'),
  // Europe
  SentriCountry('gb', '44', 'United Kingdom', '🇬🇧', '999', '999', '999'),
  SentriCountry('ie', '353', 'Ireland', '🇮🇪', '112', '112', '112'),
  SentriCountry('fr', '33', 'France', '🇫🇷', '17', '18', '15'),
  SentriCountry('de', '49', 'Germany', '🇩🇪', '110', '112', '112'),
  SentriCountry('es', '34', 'Spain', '🇪🇸', '091', '080', '061'),
  SentriCountry('it', '39', 'Italy', '🇮🇹', '113', '115', '118'),
  SentriCountry('pt', '351', 'Portugal', '🇵🇹', '112', '112', '112'),
  SentriCountry('nl', '31', 'Netherlands', '🇳🇱', '112', '112', '112'),
  SentriCountry('be', '32', 'Belgium', '🇧🇪', '101', '100', '100'),
  SentriCountry('ch', '41', 'Switzerland', '🇨🇭', '117', '118', '144'),
  SentriCountry('at', '43', 'Austria', '🇦🇹', '133', '122', '144'),
  SentriCountry('pl', '48', 'Poland', '🇵🇱', '112', '112', '112'),
  SentriCountry('se', '46', 'Sweden', '🇸🇪', '112', '112', '112'),
  SentriCountry('no', '47', 'Norway', '🇳🇴', '112', '110', '113'),
  SentriCountry('dk', '45', 'Denmark', '🇩🇰', '112', '112', '112'),
  SentriCountry('fi', '358', 'Finland', '🇫🇮', '112', '112', '112'),
  SentriCountry('gr', '30', 'Greece', '🇬🇷', '100', '199', '166'),
  SentriCountry('ru', '7', 'Russia', '🇷🇺', '102', '101', '103'),
  SentriCountry('ua', '380', 'Ukraine', '🇺🇦', '102', '101', '103'),
  SentriCountry('tr', '90', 'Türkiye', '🇹🇷', '155', '110', '112'),
  SentriCountry('ro', '40', 'Romania', '🇷🇴', '112', '112', '112'),
  SentriCountry('hu', '36', 'Hungary', '🇭🇺', '112', '112', '112'),
  SentriCountry('cz', '420', 'Czechia', '🇨🇿', '158', '150', '155'),
  // Americas
  SentriCountry('us', '1', 'United States', '🇺🇸', '911', '911', '911'),
  SentriCountry('ca', '1', 'Canada', '🇨🇦', '911', '911', '911'),
  SentriCountry('mx', '52', 'Mexico', '🇲🇽', '911', '911', '911'),
  SentriCountry('br', '55', 'Brazil', '🇧🇷', '190', '193', '192'),
  SentriCountry('ar', '54', 'Argentina', '🇦🇷', '911', '911', '911'),
  SentriCountry('cl', '56', 'Chile', '🇨🇱', '133', '132', '131'),
  SentriCountry('co', '57', 'Colombia', '🇨🇴', '123', '123', '123'),
  SentriCountry('pe', '51', 'Peru', '🇵🇪', '105', '116', '106'),
  // Middle East & Asia
  SentriCountry('ae', '971', 'United Arab Emirates', '🇦🇪', '999', '997', '998'),
  SentriCountry('sa', '966', 'Saudi Arabia', '🇸🇦', '999', '998', '997'),
  SentriCountry('il', '972', 'Israel', '🇮🇱', '100', '102', '101'),
  SentriCountry('in', '91', 'India', '🇮🇳', '112', '112', '112'),
  SentriCountry('pk', '92', 'Pakistan', '🇵🇰', '15', '16', '115'),
  SentriCountry('bd', '880', 'Bangladesh', '🇧🇩', '999', '999', '999'),
  SentriCountry('lk', '94', 'Sri Lanka', '🇱🇰', '119', '110', '1990'),
  SentriCountry('np', '977', 'Nepal', '🇳🇵', '100', '101', '102'),
  SentriCountry('cn', '86', 'China', '🇨🇳', '110', '119', '120'),
  SentriCountry('jp', '81', 'Japan', '🇯🇵', '110', '119', '119'),
  SentriCountry('kr', '82', 'South Korea', '🇰🇷', '112', '119', '119'),
  SentriCountry('id', '62', 'Indonesia', '🇮🇩', '110', '113', '119'),
  SentriCountry('my', '60', 'Malaysia', '🇲🇾', '999', '999', '999'),
  SentriCountry('sg', '65', 'Singapore', '🇸🇬', '999', '995', '995'),
  SentriCountry('th', '66', 'Thailand', '🇹🇭', '191', '199', '1669'),
  SentriCountry('vn', '84', 'Vietnam', '🇻🇳', '113', '114', '115'),
  SentriCountry('ph', '63', 'Philippines', '🇵🇭', '911', '911', '911'),
  // Oceania
  SentriCountry('au', '61', 'Australia', '🇦🇺', '000', '000', '000'),
  SentriCountry('nz', '64', 'New Zealand', '🇳🇿', '111', '111', '111'),
];

SentriCountry? countryByIso(String iso) {
  for (final c in sentriCountries) {
    if (c.iso == iso.toLowerCase()) return c;
  }
  return null;
}

/// Longest-prefix dial lookup: '234' hits Nigeria before '23' could hit anything.
SentriCountry? countryByDial(String dial) {
  final d = dial.replaceAll('+', '');
  if (d.isEmpty) return null;
  for (final n in const [4, 3, 2, 1]) {
    if (d.length < n) continue;
    final cand = d.substring(0, n);
    for (final c in sentriCountries) {
      if (c.dial == cand) return c;
    }
  }
  return null;
}

/// The dial code behind an E.164 number: '+234803…' → '234'. Null when nothing matches.
String? dialCodeFromE164(String e164) {
  final c = countryByDial(e164);
  return c?.dial;
}

/// The country behind a platform locale like 'en_NG' or 'fr_FR'. Null when unknown.
SentriCountry? countryForLocale(String localeName) {
  final cc = localeName.split('.').first.split('_').last.toLowerCase();
  if (cc.length != 2) return null;
  return countryByIso(cc);
}

/// The dial code a person's phone implies, from their platform locale ('en_NG' → '234').
String? dialCodeForLocale(String localeName) => countryForLocale(localeName)?.dial;
