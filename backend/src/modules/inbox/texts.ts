import type { Locale } from '../../domain/types.js';
import type { InboxKind } from './types.js';

/**
 * Alert wording, shown inside the app and as the notification text. Not SMS, so accents are fine.
 * ha / yo / ig / pcm are working drafts: have native speakers review them before launch, especially
 * "do not call" in the duress text. fr / es (v40) are working drafts too - machine-translated,
 * to be reviewed by native speakers before launch.
 * {n} is the sender's name, or a neutral word when they did not give one.
 */
const T: Record<Locale, Record<InboxKind, string>> & Record<Locale, { someone: string }> = {
  en: {
    someone: 'Someone',
    sos: '{n} needs urgent help. Open Sentri to see where they are and call the police near them.',
    duress: '{n} may be in danger and under pressure. Do NOT call them. Open Sentri to call the police near them.',
    offline: "{n}'s phone went offline during an alert. Open Sentri for the last place.",
    low_battery: "{n}'s phone battery is nearly dead. Open Sentri for the last place.",
    test: '{n} sent a test alert. Nothing to do. A real alert looks like this.',
    share_start: '{n} is sharing their location with you. Open Sentri to follow along.',
    share_stop: '{n} stopped sharing their location with you.',
    health_alert: "{n}'s heart rate climbed unusually high, more than once. Open Sentri to check on them and see the hospitals near them.",
  },
  pcm: {
    someone: 'Person',
    sos: '{n} dey need help sharp sharp. Open Sentri see where e dey and call police wey dey near am.',
    duress: '{n} fit dey danger, dem dey force am. No call am. Open Sentri to call police wey dey near am.',
    offline: "{n} phone don go offline for alert. Open Sentri see last place.",
    low_battery: "{n} phone battery don almost finish. Open Sentri see last place.",
    test: '{n} send test alert. Nothing to do. Real alert go look like this.',
    share_start: '{n} dey share where e dey with you. Open Sentri to follow am.',
    share_stop: '{n} don stop to share where e dey.',
    health_alert: "{n} heartbeat don jump up high plenty times. Open Sentri check am and see hospital wey dey near am.",
  },
  ha: {
    someone: 'Wani',
    sos: '{n} na bukatar taimako gaggawa. Buɗe Sentri ka ga inda yake ka kira ’yan sanda mafi kusa da shi.',
    duress: '{n} na iya kasancewa cikin hatsari ana tilasta shi. Kar ka kira shi. Buɗe Sentri ka kira ’yan sanda mafi kusa da shi.',
    offline: 'Wayar {n} ta kashe yayin gargaɗi. Buɗe Sentri ka ga wurin ƙarshe.',
    low_battery: 'Cajin wayar {n} ya kusa ƙarewa. Buɗe Sentri ka ga wurin ƙarshe.',
    test: '{n} ya aiko gwajin gargaɗi. Babu abin yi. Gargaɗin gaske zai yi kama da wannan.',
    share_start: '{n} na raba maka wurin da yake. Buɗe Sentri ka bi sawunsa.',
    share_stop: '{n} ya daina raba maka wurin da yake.',
    health_alert: 'Bugun zuciyar {n} ya yi gagarumin hawa fiye da sau ɗaya. Buɗe Sentri ka tabbata da lafiyarsa ka ga asibitoci mafi kusa da shi.',
  },
  yo: {
    someone: 'Ẹnìkan',
    sos: '{n} nílò ìrànlọ́wọ́ kíákíá. Ṣí Sentri láti rí ibi tí ó wà kí o sì pe ọlọ́pàá tó sún mọ́ ọn.',
    duress: '{n} lè wà nínú ewu, wọ́n ń fipá mú un. Má pè é. Ṣí Sentri kí o pe ọlọ́pàá tó sún mọ́ ọn.',
    offline: 'Fóònù {n} ti pa nígbà ìkìlọ̀. Ṣí Sentri fún ibi ìgbẹ̀yìn.',
    low_battery: 'Bátìrì fóònù {n} ti fẹ́rẹ̀ parí. Ṣí Sentri fún ibi ìgbẹ̀yìn.',
    test: '{n} fi ìdánwò ìkìlọ̀ ránṣẹ́. Kò sí ohun tí o máa ṣe. Ìkìlọ̀ gidi á rí báyìí.',
    share_start: '{n} ń pín ibi tí ó wà pẹ̀lú rẹ. Ṣí Sentri láti tẹ̀lé e.',
    share_stop: '{n} ti dáwọ́ pípín ibi tí ó wà dúró.',
    health_alert: 'Ìbú ọkàn {n} ti ga tó éwu léèméjì. Ṣí Sentri láti bò tó ọ kí o sì rí wọ́nì tí ó sún mọ́ ọn.',
  },
  ig: {
    someone: 'Mmadụ',
    sos: '{n} chọrọ enyemaka ozugbo. Meghee Sentri ka i hụ ebe ọ nọ ma kpọọ ndị uwe ojii dị ya nso.',
    duress: '{n} nwere ike ịnọ n’ihe ize ndụ, a na-amanye ya. Akpọla ya. Meghee Sentri ka i kpọọ ndị uwe ojii dị ya nso.',
    offline: 'Ekwentị {n} gbanyụrụ n’oge ọkwa. Meghee Sentri maka ebe ikpeazụ.',
    low_battery: 'Batrị ekwentị {n} dị nso n’ọgwụgwụ. Meghee Sentri maka ebe ikpeazụ.',
    test: '{n} zitere ọkwa nnwale. Ọ nweghị ihe ị ga-eme. Ọkwa n’ezie ga-adị otu a.',
    share_start: '{n} na-ekekọrịta ebe ọ nọ gị. Meghee Sentri iji soro ya.',
    share_stop: '{n} akwụsịla ịkekọrịta ebe ọ nọ.',
    health_alert: 'Aka obi {n} elielo nke ọma maka nke ọzọ. Meghee Sentri lelee ya ma hụ ụlọ ọgwụ dị ya nso.',
  },
  // v40, global: French and Spanish, machine-drafted like the others. Every string
  // keeps the {n} name placeholder; the duress line keeps its "do NOT call" warning.
  fr: {
    someone: 'Quelqu’un',
    sos: '{n} a besoin d’aide tout de suite. Ouvre Sentri pour voir où la personne est et appeler la police près d’elle.',
    duress: '{n} est peut-être en danger et sous la contrainte. NE l’appelle PAS. Ouvre Sentri pour appeler la police près d’elle.',
    offline: 'Le téléphone de {n} s’est éteint pendant une alerte. Ouvre Sentri pour le dernier endroit.',
    low_battery: 'La batterie du téléphone de {n} est presque vide. Ouvre Sentri pour le dernier endroit.',
    test: '{n} a envoyé une alerte test. Rien à faire. Une vraie alerte ressemble à ceci.',
    share_start: '{n} partage sa position avec toi. Ouvre Sentri pour suivre en direct.',
    share_stop: '{n} a arrêté de partager sa position avec toi.',
    health_alert: 'La fréquence cardiaque de {n} a monté de façon inhabituelle, plus d’une fois. Ouvre Sentri pour prendre des nouvelles et voir les hôpitaux près d’elle.',
  },
  es: {
    someone: 'Alguien',
    sos: '{n} necesita ayuda urgente. Abre Sentri para ver dónde está y llamar a la policía más cercana.',
    duress: '{n} puede estar en peligro y bajo presión. NO la llames. Abre Sentri para llamar a la policía cercana.',
    offline: 'El teléfono de {n} se quedó sin conexión durante una alerta. Abre Sentri para ver el último lugar.',
    low_battery: 'La batería del teléfono de {n} está casi muerta. Abre Sentri para ver el último lugar.',
    test: '{n} envió una alerta de prueba. Nada que hacer. Una alerta real se ve así.',
    share_start: '{n} está compartiendo su ubicación contigo. Abre Sentri para seguirla.',
    share_stop: '{n} dejó de compartir su ubicación contigo.',
    health_alert: 'La frecuencia cardíaca de {n} subió de forma inusual, más de una vez. Abre Sentri para comprobar cómo está y ver los hospitales cercanos.',
  },
};

export function alertText(kind: InboxKind, locale: Locale, name?: string | null): string {
  const t = T[locale] ?? T.en;
  return t[kind].replace('{n}', name?.trim() || t.someone);
}

export const ALL_ALERT_TEXTS = T;
